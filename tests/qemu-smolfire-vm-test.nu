#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/qemu-smolfire-vm-test.nu — --dry-run assertions for bin/qemu-smolfire-vm.nu.
# Checks the EDK2 boot-menu fix (-boot menu=on,splash-time=0) is added on
# aarch64 + HVF only, that --fw-menu-wait removes it, and that amd64 / TCG
# command lines are unaffected. Run from the repo root. No VM is started.

def fail [msg: string] { print $"qemu-smolfire-vm-test: FAIL — ($msg)"; exit 1 }

# preflight in the launcher requires the QEMU binary on PATH.
let missing = ["qemu-system-aarch64" "qemu-system-x86_64"] | where {|b| (which $b | is-empty) }
if ($missing | is-not-empty) {
    print $"qemu-smolfire-vm-test: SKIP — ($missing | str join ', ') not on PATH"
    exit 0
}

let tmp = (^mktemp -d | str trim)
let image = $"($tmp)/dummy.qcow2"
"" | save $image

# Return the QEMU argv (the line after "# QEMU launch command:") as a list.
def qemu-argv [image: string, flags: list<string>]: nothing -> list<string> {
    let r = (do { ^nu --no-config-file bin/qemu-smolfire-vm.nu --image $image --dry-run ...$flags } | complete)
    if $r.exit_code != 0 { fail $"dry-run ($flags | str join ' ') exited ($r.exit_code): ($r.stderr)" }
    let line = $r.stdout | lines | where {|l| $l =~ '^qemu-system-' } | last
    $line | split row " "
}

def has-boot-menu [argv: list<string>]: nothing -> bool {
    let i = $argv | enumerate | where item == "-boot" | get 0?.index
    $i != null and ($argv | get ($i + 1)) == "menu=on,splash-time=0"
}

let cases = [
    [name                  flags                                     want];
    [aarch64-hvf           ["--arch" "aarch64" "--accel" "hvf"]              true]
    [arm64-alias-hvf       ["--arch" "arm64" "--accel" "hvf"]                true]
    [aarch64-hvf-fw-wait   ["--arch" "aarch64" "--accel" "hvf" "--fw-menu-wait"] false]
    [aarch64-tcg           ["--arch" "aarch64" "--accel" "tcg"]              false]
    [aarch64-kvm           ["--arch" "aarch64" "--accel" "kvm"]              false]
    [amd64-hvf             ["--arch" "amd64" "--accel" "hvf"]                false]
    [amd64-tcg             ["--arch" "amd64" "--accel" "tcg"]                false]
]
for c in $cases {
    let argv = qemu-argv $image $c.flags
    if (has-boot-menu $argv) != $c.want { fail $"($c.name): boot-menu args present=(has-boot-menu $argv), want ($c.want): ($argv | str join ' ')" }
    if ($argv | where {|a| $a == "-boot" } | length) > 1 { fail $"($c.name): duplicate -boot" }
}

# The amd64 command line must be byte-identical with and without --fw-menu-wait.
let a = qemu-argv $image ["--arch" "amd64" "--accel" "tcg"]
let b = qemu-argv $image ["--arch" "amd64" "--accel" "tcg" "--fw-menu-wait"]
if $a != $b { fail "amd64 argv changed by --fw-menu-wait" }

# The HVF expect gates carry the same fix, opt-out env, and snapshot=on.
for g in [tests/time-to-ready-aarch64.exp tests/time-to-ready-arm64.exp] {
    let src = open --raw $g
    for needle in ["menu=on,splash-time=0" "SMOLFIRE_FW_MENU_WAIT" "{*}$boot_menu" "snapshot=on"] {
        if not ($src | str contains $needle) { fail $"($g) missing ($needle)" }
    }
}

^rm -rf $tmp
print "qemu-smolfire-vm-test: ok"
