#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/boot-time-cuts-test.nu — fixture assertions for the full-image boot-time
# cuts (docs/BOOT-TIME-ROADMAP.md section 2.9): the cuts are present, and
# nothing the boot gates need was removed. Static checks on the kernconf +
# release confs, plus a real execution of vm_extra_pre_umount (bash, stubbed
# like ci.yml's conf-hook-test) to prove the generated rc.conf/loader.conf.
# No VM is started; run from the repo root.

def fail [msg: string] { print $"boot-time-cuts-test: FAIL — ($msg)"; exit 1 }

# Active (non-comment) lines of a kernconf/conf, trailing comments stripped.
def active [path: string]: nothing -> list<string> {
    open --raw $path | lines
        | each {|l| $l | str replace -r '\s*#.*$' '' | str trim }
        | where {|l| $l != "" }
}

def has-line [lines: list<string>, want: string]: nothing -> bool {
    $lines | any {|l| ($l | str replace -a -r '\s+' ' ') == $want }
}

# ---- 1. amd64 kernconf: legacy probes cut, load-bearing devices kept ----
let k = active sys/amd64/conf/SMOLFIRE-VM
for d in [atkbdc atkbd psm ppi] {
    if not (has-line $k $"nodevice ($d)") { fail $"SMOLFIRE-VM must `nodevice ($d)`" }
}
# Must never be removed (boot gates: virtio blk/net, vtnet DHCP, serial
# console, entropy, ACPI shutdown, root mount, TPM tests).
let keep = [virtio virtio_pci virtio_blk vtnet uart kbdmux vt vt_vga acpi pci
            kvm_clock rdrand_rng random loop ether bpf scbus da cd tpm ahci nvme]
for d in $keep {
    if (has-line $k $"nodevice ($d)") { fail $"SMOLFIRE-VM must NOT remove load-bearing device ($d)" }
}
for o in [FFS GEOM_PART_GPT MSDOSFS] {
    if not (has-line $k $"options ($o)") { fail $"SMOLFIRE-VM lost `options ($o)` (UR-BSD-VERIFY Finding 2)" }
    if (has-line $k $"nooptions ($o)") { fail $"SMOLFIRE-VM must not nooptions ($o)" }
}
if not (has-line $k "device tpm") { fail "SMOLFIRE-VM lost `device tpm`" }
if not (has-line $k 'makeoptions MODULES_OVERRIDE="tmpfs nullfs fdescfs procfs"') { fail "MODULES_OVERRIDE changed" }
# Entropy/serial: the kernconf must not strip anything matching these.
let removed = $k | where {|l| $l | str starts-with "nodevice " } | each {|l| $l | split row " " | get 1 }
for bad in [random entropy uart virtio_random] {
    if $bad in $removed { fail $"nodevice ($bad) breaks the boot gate" }
}

# arm64 kernconf is deliberately untouched by this item (no evidence-backed
# cut; the guest is already mostly virtio): keep it booting on uart + virtio.
let a = active sys/arm64/conf/SMOLFIRE-VM
if not (has-line $a "device uart") { fail "arm64 SMOLFIRE-VM lost device uart" }
for d in [virtio virtio_pci virtio_blk vtnet uart kbdmux] {
    if (has-line $a $"nodevice ($d)") { fail $"arm64 SMOLFIRE-VM must NOT remove ($d)" }
}

# ---- 2. amd64 TSLOG twin for the kernel-only validation run ----
let t = active sys/amd64/conf/SMOLFIRE-VM-TSLOG
for want in ["include SMOLFIRE-VM" "ident SMOLFIRE-VM-TSLOG" "options TSLOG" "options TSLOGSIZE=262144"] {
    if not (has-line $t $want) { fail $"SMOLFIRE-VM-TSLOG missing `($want)`" }
}

# ---- 3. conf heredocs: cuts present, boot-gate lines intact ----
# Extract a heredoc body (the lines between `cat >> .../<file> <<EOF` and EOF).
def heredoc [path: string, target: string]: nothing -> list<string> {
    let ls = open --raw $path | lines
    let start = $ls | enumerate | where {|r| $r.item =~ ('cat >> .*' + $target + '.? <<EOF') } | get 0?.index
    if $start == null { fail $"($path): no heredoc for ($target)" }
    $ls | skip ($start + 1) | take while {|l| $l != "EOF" }
}

for c in [
    {path: release/tools/smolfire-qemu.conf, console: 'console="comconsole,vidconsole"', serial: 'boot_serial="YES"'}
    {path: release/tools/smolfire-qemu-aarch64.conf, console: 'console="uart0"', serial: null}
] {
    let rc = heredoc $c.path "etc/rc.conf"
    let lo = heredoc $c.path "boot/loader.conf"
    # the cut
    if 'devfs_load_rulesets="NO"' not-in $rc { fail $"($c.path): rc.conf missing devfs_load_rulesets=NO" }
    if 'hw.bus.devctl_nomatch_enabled="0"' not-in $lo { fail $"($c.path): loader.conf missing devctl_nomatch tunable" }
    # load-bearing: sshd, DHCP on vtnet0, serial console, no devd/entropy disable
    for must in ['sshd_enable="YES"' 'ifconfig_vtnet0="DHCP"' 'dumpdev="NO"'] {
        if $must not-in $rc { fail $"($c.path): rc.conf lost ($must)" }
    }
    if $c.console not-in $lo { fail $"($c.path): loader.conf lost ($c.console)" }
    if $c.serial != null and $c.serial not-in $lo { fail $"($c.path): loader.conf lost ($c.serial)" }
    if ($rc | any {|l| $l =~ '^(entropy|harvest_mask)' }) { fail $"($c.path): rc.conf must not touch entropy" }
    if ($rc | any {|l| $l =~ '^(devd|sshd|syslogd|cron)_enable="?NO' }) { fail $"($c.path): rc.conf disables a boot-gate service" }
    if ($rc | any {|l| $l =~ '^(rc_startmsgs|rc_debug|background_dhclient|ifconfig_vtnet0)=' and $l !~ 'ifconfig_vtnet0="DHCP"' }) {
        fail $"($c.path): rc.conf changes DHCP/start-message behavior the gates parse"
    }
}

# ---- 4. SHARED-TRIM regions still byte-identical (CI diffs them) ----
def trim-region [path: string]: nothing -> string {
    let ls = open --raw $path | lines
    let s = $ls | enumerate | where {|r| $r.item =~ '>>> SHARED-TRIM >>>' } | get 0.index
    let e = $ls | enumerate | where {|r| $r.item =~ '<<< SHARED-TRIM <<<' } | get 0.index
    $ls | skip $s | take ($e - $s + 1) | str join "\n"
}
if (trim-region release/tools/smolfire-qemu.conf) != (trim-region release/tools/smolfire-qemu-aarch64.conf) {
    fail "SHARED-TRIM regions diverged between the two confs"
}

# ---- 5. execute the hook for real (bash, stubs like ci.yml conf-hook-test) ----
if (which bash | is-empty) { print "boot-time-cuts-test: SKIP — bash not on PATH"; exit 0 }
let repo = pwd
for conf in [smolfire-qemu.conf smolfire-qemu-aarch64.conf] {
    let dest = (^mktemp -d | str trim)
    for d in [etc/ssh etc/pam.d boot/kernel lib usr/lib/compat usr/lib/private usr/bin usr/sbin var/empty] {
        mkdir $"($dest)/($d)"
    }
    "" | save -f $"($dest)/usr/lib/private/libprivatessh.so.5"
    let script = '
        set -eu
        pw() { :; }
        ssh-keygen() { f=""; while [ $# -gt 0 ]; do [ "$1" = "-f" ] && { f="$2"; shift 2; } || shift; done; [ -n "$f" ] && touch "$f" "$f.pub"; }
        chown() { :; }
        chmod() { :; }
        chflags() { :; }
        . "$CONF_PATH"
        vm_extra_pre_umount >/dev/null 2>&1
    '
    let r = (with-env {DESTDIR: $dest, CONF_PATH: $"($repo)/release/tools/($conf)"} {
        do { ^bash -c $script } | complete
    })
    if $r.exit_code != 0 { fail $"($conf): vm_extra_pre_umount failed under stubs: ($r.stderr)" }
    let rc = open --raw $"($dest)/etc/rc.conf"
    let lo = open --raw $"($dest)/boot/loader.conf"
    for want in ['devfs_load_rulesets="NO"' 'sshd_enable="YES"' 'ifconfig_vtnet0="DHCP"'] {
        if not ($rc | str contains $want) { fail $"($conf): generated rc.conf lacks ($want)" }
    }
    if not ($lo | str contains 'hw.bus.devctl_nomatch_enabled="0"') { fail $"($conf): generated loader.conf lacks nomatch tunable" }
    ^rm -rf $dest
}

print "boot-time-cuts-test: ok"
