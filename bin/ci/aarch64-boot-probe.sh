# SPDX-License-Identifier: Apache-2.0
# bin/ci/aarch64-boot-probe.sh — boot an aarch64 qcow2 under same-ISA TCG
# and emit a staged-marker verdict. Shared by the temporary measurement
# probe (.github/workflows/aarch64-tcg-probe.yml) and the aarch64 boot
# soft-gate job in build-image-hosted.yml.
#
# Usage: sh bin/ci/aarch64-boot-probe.sh IMG [BUDGET_SECONDS] [CPU_MODEL]
#   IMG            qcow2 to boot (read-only: snapshot=on)
#   BUDGET_SECONDS total wall budget to reach login: (default 900)
#   CPU_MODEL      qemu -cpu value (default max,pauth-impdef=on; falls back
#                  to plain max if the property is rejected — see below)
#
# Requires: qemu-system-aarch64, expect, /usr/share/AAVMF (qemu-efi-aarch64).
# Env: SERIAL_LOG (optional) — path for the captured serial transcript.
#      PROBE_QEMU / AAVMF_DIR (optional) — test seams: substitute binary and
#      firmware dir so the verdict classifier is testable without qemu/ARM
#      hardware (tests/aarch64-boot-probe-test.nu; same pattern as the
#      tpm-attest-verify argv seam).
#      PROBE_KERNEL=1 — IMG is an arm64 Image booted directly with
#      `qemu -kernel` (no AAVMF, no loader, no disk): the SMOLFIRE one-file
#      microVM path (docs/SMOLFIRE-A64-FEASIBILITY.md). Then also:
#        PROBE_APPEND     kernel cmdline; MUST start with "FreeBSD:" or the
#                         kernel ignores it (machdep_boot.c CMDLINE_GUARD)
#        PROBE_PASS       glob that means pass (default SMOLFIRE_READY)
#        PROBE_QEMU_EXTRA extra qemu argv (Tcl list), e.g. a -drive
#      The verdict contract is unchanged; AAVMF is not required here.
#
# Exit codes / VERDICT lines (the gate's contract — see the soft-gate job):
#   0  VERDICT=pass                  login: within budget; TIME_TO_LOGIN printed
#   2  VERDICT=fail-definitive       guest-emitted terminal string (panic,
#                                    mountroot>) — TCG slowness can never
#                                    produce these; speed-independent
#   3  VERDICT=inconclusive-timeout  budget exhausted; LAST_MARKER says how
#                                    far boot got (none = probe-infra suspect)
#   4  VERDICT=inconclusive-eof      qemu exited without a guest terminal
#                                    string (host flake candidate: TCG
#                                    assertion, OOM, runner death) — qemu
#                                    exit status printed; retry-once material
set -eu

IMG=${1:?usage: aarch64-boot-probe.sh IMG [BUDGET_SECONDS] [CPU_MODEL]}
BUDGET=${2:-900}
CPU=${3:-max,pauth-impdef=on}

[ -r "$IMG" ] || { echo "PROBE: image not readable: $IMG" >&2; exit 64; }

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT
SERIAL_LOG=${SERIAL_LOG:-$WORKDIR/serial.log}
PROBE_QEMU=${PROBE_QEMU:-qemu-system-aarch64}
AAVMF_DIR=${AAVMF_DIR:-/usr/share/AAVMF}

AAVMF_CODE=$AAVMF_DIR/AAVMF_CODE.fd
AAVMF_VARS=$AAVMF_DIR/AAVMF_VARS.fd

# Evidence lines (design: verify the consumer side, never assume it)
echo "PROBE: $("$PROBE_QEMU" --version | head -1)"
if [ -z "${PROBE_KERNEL:-}" ]; then
  ls -l "$AAVMF_DIR" || { echo "PROBE: AAVMF firmware missing (install qemu-efi-aarch64)" >&2; exit 64; }
fi

# pauth-impdef preflight: -S pauses at first insn, so a 5s survival means
# the cpu property parsed; a property error exits (non-124) immediately.
if [ "$CPU" != "${CPU%,*}" ]; then
  # -nic none: without it the virt machine creates a default NIC whose PXE
  # ROM (efi-virtio.rom, ipxe-qemu package) may be absent, and the preflight
  # would misattribute that to the cpu property (probe run 35940101688).
  if timeout 5 "$PROBE_QEMU" -machine virt -cpu "$CPU" -display none -nic none \
       -serial none -monitor none -S >/dev/null 2>"$WORKDIR/cpuchk.err"; then
    : # exited 0 within 5s — unexpected but property parsed
  elif [ $? -ne 124 ]; then
    echo "PROBE: cpu property rejected ($(head -1 "$WORKDIR/cpuchk.err" 2>/dev/null)) — falling back to -cpu ${CPU%%,*}"
    CPU=${CPU%%,*}
  fi
fi
echo "PROBE: cpu=$CPU budget=${BUDGET}s img=$IMG"

if [ -z "${PROBE_KERNEL:-}" ]; then
  cp "$AAVMF_VARS" "$WORKDIR/vars.fd"   # fresh NVRAM per boot
fi

# Staged markers, each printed once with its elapsed time:
#   uefi   — EDK2/AAVMF produced output (firmware alive)
#   loader — FreeBSD EFI loader banner
#   kernel — kernel copyright banner
#   rc     — "Setting hostname" (verified string, ledger run 35834636637)
# Terminal: login: / mountroot> / panic / timeout / eof.
export PROBE_IMG="$IMG" PROBE_CPU="$CPU" PROBE_BUDGET="$BUDGET" PROBE_QEMU
export PROBE_KERNEL="${PROBE_KERNEL:-}" PROBE_APPEND="${PROBE_APPEND:-FreeBSD:}"
export PROBE_PASS="${PROBE_PASS:-SMOLFIRE_READY}" PROBE_QEMU_EXTRA="${PROBE_QEMU_EXTRA:-}"
export PROBE_VARS="$WORKDIR/vars.fd" PROBE_CODE="$AAVMF_CODE" PROBE_SERIAL="$SERIAL_LOG"

rc=0
expect - <<'EXPECT_EOF' || rc=$?
set t0 [clock seconds]
proc elapsed {} { global t0; return [expr {[clock seconds] - $t0}] }
set budget $env(PROBE_BUDGET)
set last none
array set seen {}

log_file -a $env(PROBE_SERIAL)

# romfile= disables the NIC's PXE option ROM (efi-virtio.rom lives in the
# separate ipxe-qemu package on Ubuntu and is never needed for EFI disk boot)
if {$env(PROBE_KERNEL) ne ""} {
  # Direct arm64 Image boot: QEMU passes the DTB in x0 (Linux boot protocol
  # = any non-ELF -kernel); FreeBSD LINUX_BOOT_ABI consumes it. No firmware.
  set pass_pat $env(PROBE_PASS)
  spawn $env(PROBE_QEMU) -machine virt -accel tcg,thread=multi \
    -cpu $env(PROBE_CPU) -smp 4 -m 1024M \
    -kernel $env(PROBE_IMG) -append $env(PROBE_APPEND) \
    -device virtio-rng-pci {*}$env(PROBE_QEMU_EXTRA) \
    -display none -serial mon:stdio
} else {
  set pass_pat "login:"
  spawn $env(PROBE_QEMU) -machine virt -accel tcg,thread=multi \
    -cpu $env(PROBE_CPU) -smp 4 -m 1024M \
    -drive if=pflash,format=raw,unit=0,file=$env(PROBE_CODE),readonly=on \
    -drive if=pflash,format=raw,unit=1,file=$env(PROBE_VARS) \
    -drive file=$env(PROBE_IMG),format=qcow2,if=virtio,snapshot=on \
    -device virtio-rng-pci \
    -netdev user,id=n0 -device virtio-net-pci,netdev=n0,romfile= \
    -display none -serial mon:stdio
}

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
        -re {BdsDxe|UEFI Interactive Shell|Press ESCAPE} { mark uefi; continue }
        -re {FreeBSD EFI boot block|FreeBSD/arm64 EFI loader|Consoles: EFI} { mark loader; continue }
        "Copyright (c) 1992" { mark kernel; continue }
        "Setting hostname"   { mark rc; continue }
        $pass_pat {
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

# Entropy evidence (ledger HVF lesson: seeding stalls are ~27s-class, not hangs)
echo "PROBE: random/entropy lines from serial:"
grep -a "random:" "$SERIAL_LOG" 2>/dev/null | head -10 || echo "  (none captured)"

exit $rc
