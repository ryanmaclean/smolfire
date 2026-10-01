#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/smolfire-a64-test.nu — locally-testable parts of the experimental
# aarch64 SMOLFIRE one-file microVM (docs/SMOLFIRE-A64-FEASIBILITY.md):
#   1. bin/build-smolfire.sh --arch aarch64 --rootfs-only (+ guards)
#   2. bin/mk-arm64-image.sh replayed with the real releng/15.0
#      arm_kernel_boothdr.awk (fixture) over a tiny synthetic ELF
#   3. bin/ci/aarch64-boot-probe.sh PROBE_KERNEL=1 verdict classifier
#      (fake qemu seam, same pattern as aarch64-boot-probe-test.nu)
#   4. static wiring: kernconf, workflow disabled-by-default
# Nothing here needs FreeBSD, KVM or a real aarch64 kernel; the real-kernel
# boot evidence is in the feasibility doc. Run from the repo root.

def fail [msg: string] {
    print $"smolfire-a64-test: FAIL — ($msg)"
    exit 1
}

def assert-contains [haystack: string, needle: string, ctx: string] {
    if not ($haystack | str contains $needle) {
        fail $"($ctx): missing ($needle)\n---\n($haystack)"
    }
}

def inode [path: string] {
    if $nu.os-info.name in ["macos" "freebsd"] {
        ^stat -f %i $path | str trim
    } else {
        ^stat -c %i $path | str trim
    }
}

let tmp = (^mktemp -d | str trim)

# ── 1. rootfs assembly with --arch aarch64 ───────────────────────────────────
# Fake rescue = a file whose ELF header says EM_AARCH64 (0xb7 at offset 18).
def fake-elf [path: string, machine: binary] {
    # 18 header bytes, e_machine (2), padding
    let hdr = (0x[7f 45 4c 46 02 01 01 00 00 00 00 00 00 00 00 00 02 00] | bytes add --end $machine)
    $hdr | bytes add --end (0x[00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00]) | save --force --raw $path
}
mkdir $"($tmp)/rescue-a64" $"($tmp)/rescue-x86" $"($tmp)/rescue-txt"
fake-elf $"($tmp)/rescue-a64/rescue" 0x[b7 00]
fake-elf $"($tmp)/rescue-x86/rescue" 0x[3e 00]
"fake rescue crunchgen binary\n" | save --force $"($tmp)/rescue-txt/rescue"

let root = $"($tmp)/root-a64"
let ok = (with-env {RESCUE_SRC: $"($tmp)/rescue-a64/rescue", ROOT: $root} {
    ^sh bin/build-smolfire.sh --arch aarch64 --rootfs-only | complete
})
if $ok.exit_code != 0 { fail $"--arch aarch64 --rootfs-only exited ($ok.exit_code): ($ok.stderr)" }
for p in [$"($root)/rescue/rescue" $"($root)/rescue/sh" $"($root)/rescue/init" $"($root)/sbin/init" $"($root)/bin/sh" $"($root)/etc/rc"] {
    if not ($p | path exists) { fail $"aarch64 rootfs missing ($p)" }
}
if (inode $"($root)/bin/sh") != (inode $"($root)/rescue/rescue") {
    fail "aarch64 rootfs: /bin/sh is not a hard link to /rescue/rescue"
}
let rc = (open --raw $"($root)/etc/rc")
for needle in ["SMOLFIRE_READY" "kenv smolfire.ip" "exec /rescue/sh"] {
    assert-contains $rc $needle "aarch64 /etc/rc"
}

# arch spelling aliases and the explicit amd64 default must still work with
# the historic (non-ELF) fake rescue.
let amd = (with-env {RESCUE_SRC: $"($tmp)/rescue-txt/rescue", ROOT: $"($tmp)/root-amd"} {
    ^sh bin/build-smolfire.sh --arch amd64 --rootfs-only | complete
})
if $amd.exit_code != 0 { fail $"--arch amd64 --rootfs-only exited ($amd.exit_code): ($amd.stderr)" }
let alias = (with-env {RESCUE_SRC: $"($tmp)/rescue-a64/rescue", ROOT: $"($tmp)/root-alias"} {
    ^sh bin/build-smolfire.sh --rootfs-only --arch=arm64 | complete
})
if $alias.exit_code != 0 { fail $"--arch=arm64 alias exited ($alias.exit_code): ($alias.stderr)" }

# Guards: foreign-ISA / non-ELF userland must be refused for aarch64.
for bad in ["rescue-x86" "rescue-txt"] {
    let r = (with-env {RESCUE_SRC: $"($tmp)/($bad)/rescue", ROOT: $"($tmp)/root-bad"} {
        ^sh bin/build-smolfire.sh --arch aarch64 --rootfs-only | complete
    })
    if $r.exit_code == 0 { fail $"aarch64 accepted a non-aarch64 rescue \(($bad)\)" }
    assert-contains $r.stderr "not an aarch64 ELF" $"guard message for ($bad)"
}
let badarch = (with-env {RESCUE_SRC: $"($tmp)/rescue-a64/rescue", ROOT: $"($tmp)/root-x"} {
    ^sh bin/build-smolfire.sh --arch riscv64 --rootfs-only | complete
})
if $badarch.exit_code != 64 { fail $"--arch riscv64 should exit 64, got ($badarch.exit_code)" }
let tsl = (with-env {RESCUE_SRC: $"($tmp)/rescue-a64/rescue", ROOT: $"($tmp)/root-x", SMOLFIRE_TSLOG: "1"} {
    ^sh bin/build-smolfire.sh --arch aarch64 --rootfs-only | complete
})
if $tsl.exit_code != 64 { fail $"SMOLFIRE_TSLOG=1 with aarch64 should exit 64, got ($tsl.exit_code)" }

# The amd64-only patch blocks must be gated, and amd64 must stay the default.
let build = (open --raw bin/build-smolfire.sh)
assert-contains $build "ARCH=amd64" "default arch"
assert-contains $build "if [ \"$ARCH\" = amd64 ]; then" "amd64-only patch gate"
let pv = ($build | str index-of "PV=/usr/src/sys/x86/xen/pv.c")
let gate = ($build | str index-of "if [ \"$ARCH\" = amd64 ]; then")
if not ($gate >= 0 and $gate < $pv) { fail "pv.c block is not inside the amd64 gate" }
assert-contains $build "TARGET=arm64 TARGET_ARCH=aarch64" "cross target"
assert-contains $build "arm64.aarch64/sys/SMOLFIRE" "arm64 objdir"

# ── 2. Image wrapper vs the real upstream header generator ───────────────────
let have = (["as" "ld" "objcopy" "nm" "awk" "od"] | all {|t| (which $t | is-not-empty) })
if not $have {
    print "SKIP: image-wrapper test needs as/ld/objcopy/nm/awk/od"
} else {
    let e = $"($tmp)/elf"
    mkdir $e
    "\t.text\n\t.globl _start\n_start:\n\tnop\n\tnop\n\tret\n\t.data\n\t.ascii \"MFS-PAYLOAD\"\n\t.bss\n\t.space 4096\n" | save --force $"($e)/k.s"
    # kernbase/_start/_end as in a FreeBSD arm64 kernel: _start = kernbase + 0x800
    "SECTIONS {\n  kernbase = 0xffff000000000000;\n  . = kernbase + 0x800;\n  .text : { *(.text) }\n  . = ALIGN(0x1000);\n  .data : { *(.data) }\n  .bss : { *(.bss) }\n  . = ALIGN(0x1000);\n  _end = .;\n}\nENTRY(_start)\n" | save --force $"($e)/k.ld"
    let b = (do { cd $e; ^as -o k.o k.s; ^ld -T k.ld -o k.elf k.o } | complete)
    if $b.exit_code != 0 {
        print $"SKIP: host as/ld cannot build the synthetic ELF: ($b.stderr | str trim)"
    } else {
        let img = $"($e)/Image"
        let m = (with-env {ARM_BOOTHDR_AWK: $"($env.PWD)/tests/fixtures/freebsd-releng-15.0/sys/tools/arm_kernel_boothdr.awk"} {
            ^sh bin/mk-arm64-image.sh $"($e)/k.elf" $img | complete
        })
        if $m.exit_code != 0 { fail $"mk-arm64-image.sh failed: ($m.stderr)" }
        let d = (open --raw $img | into binary)
        let le = {|from: int, n: int| $d | bytes at $from..<($from + $n) | into int --endian little }
        # header: b _start (0x14000000 | 0x800/4), text_offset 0, image_size = _end-kernbase, flags 8, magic
        if (do $le 0 4) != (0x14000000 + 0x200) { fail $"first word is not 'b +0x800' (got (do $le 0 4))" }
        if (do $le 8 8) != 0 { fail "text_offset must be 0" }
        if (do $le 16 8) != 0x3000 { fail $"image_size must be _end-kernbase=0x3000, got (do $le 16 8)" }
        if (do $le 24 8) != 8 { fail "flags must be 8 (4K pages)" }
        if (do $le 56 4) != 0x644d5241 { fail "magic must be 'ARM\\x64'" }
        # payload starts at _start's offset (0x800) and keeps the section layout
        if ($d | bytes at 0x800..<0x803) != 0x[90 90 c3] { fail "text payload not at offset 0x800" }
        if ($d | bytes at 0x1000..<0x100b) != ("MFS-PAYLOAD" | into binary) { fail "data payload not at 0x1000 (Image offset == vaddr - kernbase)" }
        if ($d | bytes length) != (0x800 + 2059) { fail $"unexpected Image size ($d | bytes length)" }
        # Fail-loud: a kernel without the symbols must not yield an Image
        let nokern = $"($e)/nosyms.elf"
        ^cp $"($e)/k.elf" $nokern
        ^objcopy --strip-all $nokern
        let n = (with-env {ARM_BOOTHDR_AWK: $"($env.PWD)/tests/fixtures/freebsd-releng-15.0/sys/tools/arm_kernel_boothdr.awk"} {
            ^sh bin/mk-arm64-image.sh $nokern $"($e)/Image-bad" | complete
        })
        if $n.exit_code == 0 { fail "mk-arm64-image.sh accepted a kernel without kernbase/_start/_end" }
    }
}

# ── 3. Probe classifier in PROBE_KERNEL mode (fake qemu seam) ────────────────
if (which expect | is-empty) {
    print "SKIP: expect(1) not installed — probe kernel-mode test not run"
} else {
    "img" | save --force $"($tmp)/Image"
    let fake = $"($tmp)/fake-qemu.sh"
    '#!/bin/sh
case "$1" in --version) echo "QEMU emulator version 0.0-fake"; exit 0 ;; esac
echo "$@" > "$FAKE_ARGV"
case "$FAKE_SCENARIO" in
  ready)
    echo "Copyright (c) 1992-2025 The FreeBSD Project."
    echo "md0: Embedded image 36700160 bytes at 0xffff000001200000"
    echo "SMOLFIRE_READY"; sleep 30 ;;
  mountroot) echo "Copyright (c) 1992-2025 The FreeBSD Project."; echo "mountroot> "; sleep 30 ;;
  panic) echo "Copyright (c) 1992-2025 The FreeBSD Project."; echo "panic: boom"; sleep 30 ;;
  hang) echo "Copyright (c) 1992-2025 The FreeBSD Project."; sleep 30 ;;
esac
' | save --force $fake
    ^chmod +x $fake
    def run-kprobe [scenario: string, budget: int, extra: record] {
        with-env ({
            PROBE_QEMU: $fake, PROBE_KERNEL: "1", AAVMF_DIR: $"($tmp)/no-such-aavmf",
            FAKE_SCENARIO: $scenario, FAKE_ARGV: $"($tmp)/argv-($scenario).txt",
            SERIAL_LOG: $"($tmp)/serial-($scenario).log"
        } | merge $extra) {
            ^sh bin/ci/aarch64-boot-probe.sh $"($tmp)/Image" ($budget | into string) max | complete
        }
    }
    let r = (run-kprobe ready 30 {PROBE_APPEND: "FreeBSD: smolfire.ip=10.0.2.15/24"})
    if $r.exit_code != 0 { fail $"kernel-mode ready: exit ($r.exit_code)\n($r.stdout)\n($r.stderr)" }
    assert-contains $r.stdout "VERDICT=pass" "kernel-mode pass"
    assert-contains $r.stdout "MARKER=kernel" "kernel marker"
    let argv = (open --raw $"($tmp)/argv-ready.txt")
    for needle in ["-kernel" $"($tmp)/Image" "-append" "FreeBSD: smolfire.ip=10.0.2.15/24" "-machine virt"] {
        assert-contains $argv $needle "qemu argv (kernel mode)"
    }
    if ($argv | str contains "pflash") { fail "kernel mode must not use AAVMF pflash" }
    if ($argv | str contains "-drive") { fail "kernel mode must not attach a disk by default" }

    let r = (run-kprobe mountroot 30 {})
    if $r.exit_code != 2 { fail $"kernel-mode mountroot: want exit 2, got ($r.exit_code)" }
    assert-contains $r.stdout "VERDICT=fail-definitive" "mountroot verdict"
    let r = (run-kprobe panic 30 {})
    if $r.exit_code != 2 { fail $"kernel-mode panic: want exit 2, got ($r.exit_code)" }
    let r = (run-kprobe hang 2 {})
    if $r.exit_code != 3 { fail $"kernel-mode hang: want exit 3, got ($r.exit_code)" }
    assert-contains $r.stdout "LAST_MARKER=kernel" "timeout last marker"
    # PROBE_PASS override + PROBE_QEMU_EXTRA are honoured
    let r = (run-kprobe ready 30 {PROBE_PASS: "md0: Embedded image", PROBE_QEMU_EXTRA: "-device virtio-rng-device"})
    if $r.exit_code != 0 { fail $"PROBE_PASS override: exit ($r.exit_code)" }
    assert-contains (open --raw $"($tmp)/argv-ready.txt") "virtio-rng-device" "PROBE_QEMU_EXTRA passthrough"
}

# ── 4. Static wiring ─────────────────────────────────────────────────────────
let kc = (open --raw sys/arm64/conf/SMOLFIRE)
for line in ["include SMOLFIRE-VM" "ident SMOLFIRE" "device\t\tuart_ns8250"] {
    assert-contains $kc $line "sys/arm64/conf/SMOLFIRE"
}
# The base conf must not have grown loader-only dependencies this kernel lacks.
if ($kc | lines | where {|l| $l =~ '^\s*(options|device)\s+(ZFS|GEOM_UZIP)' } | is-not-empty) {
    fail "SMOLFIRE (arm64) must stay minimal: no ZFS/UZIP"
}

let wf = (open .github/workflows/smolfire-a64.yml)
let triggers = ($wf | get on | columns)
if $triggers != ["workflow_dispatch"] { fail $"a64 workflow must be dispatch-only, has: ($triggers)" }
if ($wf.on.workflow_dispatch.inputs.enable.default) != false { fail "a64 enable input must default to false" }
for j in ($wf.jobs | columns) {
    let cond = ($wf.jobs | get $j | get if)
    assert-contains $cond "inputs.enable" $"job ($j) gate"
}

^rm -rf $tmp
print "smolfire-a64-test: ok"
