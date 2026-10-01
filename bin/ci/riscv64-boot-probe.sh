# SPDX-License-Identifier: Apache-2.0
# bin/ci/riscv64-boot-probe.sh — boot a riscv64 qcow2 under TCG
# (qemu-system-riscv64 -machine virt, OpenSBI + U-Boot) and emit a
# staged-marker verdict. Sibling of bin/ci/aarch64-boot-probe.sh: the
# VERDICT/exit-code contract is IDENTICAL (0 pass, 2 fail-definitive,
# 3 inconclusive-timeout, 4 inconclusive-eof, 64 usage) so the same
# soft-gate shell wrapper drives either probe. Only the firmware chain
# and the early markers differ.
#
# Usage: sh bin/ci/riscv64-boot-probe.sh IMG [BUDGET_SECONDS]
#   IMG            qcow2 to boot (read-only: snapshot=on)
#   BUDGET_SECONDS total wall budget to reach login: (default 900)
#
# Requires: qemu-system-riscv64 (qemu-system-misc), expect, OpenSBI and
# U-Boot for the virt machine (Ubuntu: opensbi, u-boot-qemu).
# Env (all optional):
#   SERIAL_LOG   path for the captured serial transcript
#   PROBE_QEMU   substitute qemu binary (test seam, as in the aarch64 probe)
#   OPENSBI_FW   -bios value (default: "default" = the OpenSBI bundled
#                with qemu; or a path such as
#                /usr/lib/riscv64-linux-gnu/opensbi/generic/fw_dynamic.bin)
#   UBOOT_BIN    S-mode U-Boot passed as -kernel (default
#                /usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin)
#   PROBE_CPU    qemu -cpu (default rv64)
#
# Markers (each printed once with elapsed time):
#   opensbi — "OpenSBI v" banner (M-mode firmware alive)
#   uboot   — "U-Boot 20" banner (S-mode bootloader alive)
#   loader  — FreeBSD loader banner (via U-Boot distro/EFI boot)
#   kernel  — FreeBSD copyright banner
#   rc      — "Setting hostname"
# Terminal: login: / mountroot> / panic / timeout / eof.
#
# STATUS: firmware chain (opensbi -> uboot) verified locally with qemu
# 8.2.2; the real riscv64 smolfire image has NOT been booted yet (see
# docs/UR-BSD-VERIFY.md / the gates report). The loader/kernel marker
# strings for riscv64 are therefore unverified assumptions; the terminal
# strings (login:, mountroot>, panic) are arch-independent.
set -eu

IMG=${1:?usage: riscv64-boot-probe.sh IMG [BUDGET_SECONDS]}
BUDGET=${2:-900}
CPU=${PROBE_CPU:-rv64}

[ -r "$IMG" ] || { echo "PROBE: image not readable: $IMG" >&2; exit 64; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
SERIAL_LOG=${SERIAL_LOG:-$WORKDIR/serial.log}
PROBE_QEMU=${PROBE_QEMU:-qemu-system-riscv64}
OPENSBI_FW=${OPENSBI_FW:-default}
UBOOT_BIN=${UBOOT_BIN:-/usr/lib/u-boot/qemu-riscv64_smode/u-boot.bin}

echo "PROBE: $("$PROBE_QEMU" --version | head -1)"
[ -r "$UBOOT_BIN" ] || { echo "PROBE: U-Boot missing: $UBOOT_BIN (install u-boot-qemu)" >&2; exit 64; }
if [ "$OPENSBI_FW" != default ] && [ ! -r "$OPENSBI_FW" ]; then
  echo "PROBE: OpenSBI missing: $OPENSBI_FW (install opensbi)" >&2; exit 64
fi
echo "PROBE: cpu=$CPU budget=${BUDGET}s img=$IMG bios=$OPENSBI_FW uboot=$UBOOT_BIN"

export PROBE_IMG="$IMG" PROBE_CPU="$CPU" PROBE_BUDGET="$BUDGET" PROBE_QEMU
export PROBE_BIOS="$OPENSBI_FW" PROBE_UBOOT="$UBOOT_BIN" PROBE_SERIAL="$SERIAL_LOG"

rc=0
expect - <<'EXPECT_EOF' || rc=$?
set t0 [clock seconds]
proc elapsed {} { global t0; return [expr {[clock seconds] - $t0}] }
set budget $env(PROBE_BUDGET)
set last none
array set seen {}

log_file -a $env(PROBE_SERIAL)

# romfile= : no PXE ROM needed (same lesson as the aarch64 probe).
spawn $env(PROBE_QEMU) -machine virt -accel tcg,thread=multi \
  -cpu $env(PROBE_CPU) -smp 4 -m 1024M \
  -bios $env(PROBE_BIOS) -kernel $env(PROBE_UBOOT) \
  -drive file=$env(PROBE_IMG),format=qcow2,if=none,id=hd0,snapshot=on \
  -device virtio-blk-device,drive=hd0 \
  -device virtio-rng-device \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -display none -serial mon:stdio

proc mark {name} {
    global seen last
    if {![info exists seen($name)]} {
        set seen($name) 1
        set last $name
        puts "\nMARKER=$name T=[elapsed]s"
    }
}

while {1} {
    set remain [expr {$budget - [elapsed]}]
    if {$remain <= 0} {
        puts "\nVERDICT=inconclusive-timeout LAST_MARKER=$last (no login within ${budget}s; TCG slowness indistinguishable from hang; image NOT verified broken)"
        exit 3
    }
    set timeout $remain
    expect {
        "OpenSBI v"          { mark opensbi; continue }
        -re {U-Boot 20}      { mark uboot; continue }
        -re {FreeBSD/riscv|Consoles: |FreeBSD EFI boot block} { mark loader; continue }
        "Copyright (c) 1992" { mark kernel; continue }
        "Setting hostname"   { mark rc; continue }
        "login:" {
            puts "\nTIME_TO_LOGIN=[elapsed]s\nVERDICT=pass"
            exit 0
        }
        "mountroot>" {
            puts "\nVERDICT=fail-definitive (mountroot — see UR-BSD-VERIFY Finding 2 / rollback criteria)"
            exit 2
        }
        "panic" {
            puts "\nVERDICT=fail-definitive (kernel panic)"
            exit 2
        }
        timeout {
            puts "\nVERDICT=inconclusive-timeout LAST_MARKER=$last (no login within ${budget}s)"
            exit 3
        }
        eof {
            set rc [wait]
            puts "\nQEMU_EXIT status=[lindex $rc 3] LAST_MARKER=$last"
            puts "VERDICT=inconclusive-eof (qemu exited with no guest terminal string — host flake candidate, retry material)"
            exit 4
        }
    }
}
EXPECT_EOF

echo "PROBE: random/entropy lines from serial:"
grep -a "random:" "$SERIAL_LOG" 2>/dev/null | head -10 || echo "  (none captured)"

exit $rc
