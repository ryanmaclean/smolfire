#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# qemu-smolfire-vm.nu — launch smolfire inside QEMU with optional swtpm TPM support.
#
# Parallel to bin/bhyve-smolfire-vm.nu but targets QEMU rather than bhyve.
# Works on macOS (HVF acceleration), Linux (KVM), and any host with QEMU (TCG
# fallback).  TPM is supported on both aarch64 and amd64 via QEMU's tpm-tis-device
# and tpm-tis backends respectively.
#
# Key differences from bhyve-smolfire-vm.nu:
#   - Accelerator auto-detected: HVF (macOS) > KVM (Linux) > TCG (fallback)
#   - No bhyvectl / nmdm — console is -serial stdio or a unix/file path
#   - TPM works on both arches: tpm-tis-device (aarch64), tpm-tis (amd64)
#   - swtpm socket uses --ctrl type=unixio (same QEMU syntax as bhyve)
#   - BIOS paths differ by OS: Homebrew (macOS) vs /usr/share/qemu (Linux/FreeBSD)
#
# QEMU TPM wiring (exact flags — do not alter):
#
#   amd64:
#     -chardev socket,id=chrtpm,path=<sock>
#     -tpmdev emulator,id=tpm0,chardev=chrtpm
#     -device tpm-tis,tpmdev=tpm0
#
#   aarch64:
#     -chardev socket,id=chrtpm,path=<sock>
#     -tpmdev emulator,id=tpm0,chardev=chrtpm
#     -device tpm-tis-device,tpmdev=tpm0
#
# swtpm socket for QEMU:
#   swtpm socket --tpmstate dir=<dir> --tpm2 \
#     --ctrl type=unixio,path=<sock> --daemon
#
# Usage:
#   nu bin/qemu-smolfire-vm.nu --image FreeBSD-15-arm64-smolfire.qcow2
#   nu bin/qemu-smolfire-vm.nu --image smolfire-amd64.raw --arch amd64 --tpm
#   nu bin/qemu-smolfire-vm.nu --image smolfire.qcow2 --dry-run
#   nu bin/qemu-smolfire-vm.nu --image smolfire.qcow2 --accel tcg --cpus 4 --mem 512M
#
# See: bin/bhyve-smolfire-vm.nu   — bhyve equivalent
#      bin/swtpm-setup.nu      — swtpm lifecycle helper
#      tests/time-to-ready-aarch64.exp  — QEMU aarch64 boot gate
#      plans/tinyos/PHASE-3-TPM.md      — TPM test plan

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped TOML step log line to stdout.
# Same convention as bhyve-smolfire-vm.nu and the rest of the smolfire toolchain.
def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── swtpm helpers ──────────────────────────────────────────────────────────────

# Locate the swtpm binary.  Probes Homebrew (macOS), /usr/local/bin and
# /usr/local/sbin (FreeBSD/Linux ports), then the system PATH.
def find-swtpm [] {
    let candidates = [
        "/opt/homebrew/bin/swtpm"
        "/usr/local/bin/swtpm"
        "/usr/local/sbin/swtpm"
        "/usr/bin/swtpm"
    ]
    let found = $candidates | where {|p| $p | path exists}
    if ($found | length) > 0 {
        return ($found | first)
    }
    # Fall back to PATH lookup
    let which_r = (^which swtpm | complete)
    if $which_r.exit_code == 0 {
        return ($which_r.stdout | str trim)
    }
    error make {msg: "swtpm binary not found; install security/swtpm (FreeBSD), swtpm (Linux), or brew install swtpm (macOS)"}
}

# Start an swtpm socket daemon for QEMU.
# QEMU requires --ctrl type=unixio (same as bhyve).
# Returns the socket path.
def start-swtpm [state_dir: string]: nothing -> string {
    let sock = $"($state_dir)/swtpm.sock"

    log-step "swtpm-start" "creating swtpm state directory" {dir: $state_dir}
    ^mkdir -p $state_dir

    let swtpm_bin = find-swtpm

    log-step "swtpm-start" "launching swtpm daemon" {
        bin:   $swtpm_bin
        sock:  $sock
        state: $state_dir
    }

    # --ctrl type=unixio  — QEMU reads state via the control socket
    # --tpm2              — TPM 2.0 (required; QEMU tpm-tis / tpm-tis-device expect TPM 2.0)
    # --daemon            — detach from terminal; writes PID to <state_dir>/swtpm.pid
    let tpmstate_arg = $"dir=($state_dir)"
    let ctrl_arg     = $"type=unixio,path=($sock)"
    ^$swtpm_bin socket --tpmstate $tpmstate_arg --tpm2 --ctrl $ctrl_arg --daemon

    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: $"swtpm failed to start (exit ($env.LAST_EXIT_CODE))"}
    }

    # Brief settle: swtpm writes the socket file asynchronously after --daemon.
    # Poll up to 3 s in 100 ms steps rather than a fixed sleep.
    mut waited_ms = 0
    loop {
        if ($sock | path exists) { break }
        if $waited_ms >= 3000 {
            error make {msg: $"swtpm socket did not appear within 3s at ($sock)"}
        }
        ^sleep 0.1
        $waited_ms = $waited_ms + 100
    }

    log-step "swtpm-start" "swtpm socket ready" {sock: $sock, waited_ms: $waited_ms}
    $sock
}

# Stop swtpm: send SIGTERM via the pid file, then remove stale socket.
def stop-swtpm [state_dir: string] {
    let sock     = $"($state_dir)/swtpm.sock"
    let pid_file = $"($state_dir)/swtpm.pid"
    log-step "swtpm-stop" "stopping swtpm" {sock: $sock}

    if ($pid_file | path exists) {
        let pid = open --raw $pid_file | str trim
        ^kill $pid
    } else {
        # Best-effort fallback: pkill on the socket path pattern
        ^pkill -f $"swtpm.*($sock)" o> /dev/null e> /dev/null
    }

    if ($sock | path exists) {
        ^rm -f $sock
    }

    log-step "swtpm-stop" "swtpm stopped" {}
}

# ── Accelerator detection ──────────────────────────────────────────────────────

# Detect the best available QEMU accelerator for the host OS.
# Priority: HVF (macOS, native-ISA aarch64/amd64) > KVM (Linux) > TCG (any).
# Override with --accel on the command line.
def detect-accel [arch: string]: nothing -> string {
    # macOS: check kern.hv_support sysctl
    let hv_r = (^sysctl kern.hv_support | complete)
    if $hv_r.exit_code == 0 {
        let val = $hv_r.stdout | str trim | split row ":" | last | str trim
        if $val == "1" {
            return "hvf"
        }
    }

    # Linux: check for /dev/kvm
    if ("/dev/kvm" | path exists) {
        return "kvm"
    }

    # Fallback: TCG (software emulation — slow but works everywhere)
    "tcg"
}

# ── BIOS / firmware path resolution ───────────────────────────────────────────

# Return the UEFI firmware path for QEMU on this host.
# Checks Homebrew (macOS), then FreeBSD/Linux system paths.
def find-bios [arch: string]: nothing -> string {
    let candidates = if $arch == "aarch64" {
        [
            "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"   # macOS Homebrew
            "/usr/share/qemu/QEMU_EFI.fd"                      # FreeBSD + some Linux
            "/usr/share/qemu/edk2-aarch64-code.fd"             # Fedora/RHEL
            "/usr/share/AAVMF/AAVMF_CODE.fd"                   # Debian/Ubuntu
        ]
    } else {
        [
            "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"    # macOS Homebrew
            "/usr/share/qemu/OVMF.fd"                          # FreeBSD + Fedora
            "/usr/share/qemu/edk2-x86_64-code.fd"             # RHEL
            "/usr/share/OVMF/OVMF_CODE.fd"                    # Debian/Ubuntu
            "/usr/share/ovmf/OVMF.fd"                          # some Debian variants
        ]
    }

    let found = $candidates | where {|p| $p | path exists}
    if ($found | length) > 0 {
        return ($found | first)
    }

    # Return the most likely path with a warning; caller decides whether to error.
    let fallback = if $arch == "aarch64" {
        "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
    } else {
        "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
    }
    log-step "preflight" $"WARNING: UEFI firmware not found for ($arch) — tried ($candidates | str join ', ')" {
        arch:     $arch
        fallback: $fallback
    }
    $fallback
}

# ── Image format detection ─────────────────────────────────────────────────────

# Detect the disk image format from the file extension and magic bytes.
# Returns "qcow2" or "raw".
def detect-image-format [image: string]: nothing -> string {
    if ($image | str ends-with ".qcow2") { return "qcow2" }
    if ($image | str ends-with ".raw")   { return "raw" }

    # Check magic bytes: qcow2 starts with "QFI\xfb" (hex 51 46 49 fb)
    let magic_r = (^file $image | complete)
    if $magic_r.exit_code == 0 {
        let out = $magic_r.stdout | str downcase
        if ($out | str contains "qcow") { return "qcow2" }
    }

    # Ambiguous — assume raw and log a warning
    log-step "image-format" "WARNING: could not determine image format from extension or magic; assuming raw" {
        image: $image
    }
    "raw"
}

# ── CPU model selection ────────────────────────────────────────────────────────

# Return the CPU model string for -cpu.
# "host" requires HVF or KVM; TCG needs an explicit model.
def cpu-model [arch: string, accel: string]: nothing -> string {
    if $accel == "hvf" or $accel == "kvm" {
        "host"
    } else if $arch == "aarch64" {
        "cortex-a72"   # TCG aarch64: Cortex-A72 is well-supported in QEMU
    } else {
        "qemu64"       # TCG amd64: generic 64-bit QEMU CPU
    }
}

# ── Firmware boot-menu wait ───────────────────────────────────────────────────

# QEMU args that remove EDK2's BDS boot-menu timeout on aarch64 + HVF.
#
# edk2-aarch64-code.fd waits ~5.1 s at the boot-menu timeout before loading
# BOOTAA64.EFI on every boot. `-boot menu=on,splash-time=0` sets fw_cfg
# etc/boot-menu-wait = 0, so BDS boots immediately. Measured in
# docs/BOOT-TIME-ROADMAP.md §1 (PR #55): firmware phase 5,587 → 542 ms median,
# time-to-login 17.6 → 8.5 s. Scoped to aarch64 + HVF (the measured path);
# amd64 and TCG command lines are unchanged. `keep_wait` restores the
# firmware default (A/B measurement).
def fw-boot-menu-args [arch: string, accel: string, keep_wait: bool]: nothing -> list<string> {
    if $arch == "aarch64" and $accel == "hvf" and not $keep_wait {
        ["-boot" "menu=on,splash-time=0"]
    } else {
        []
    }
}

# ── Command builders ──────────────────────────────────────────────────────────

# Build the QEMU argument list for an aarch64 guest.
def build-cmd-aarch64 [
    image:      string
    img_fmt:    string
    mem:        string
    cpus:       int
    accel:      string
    bios:       string
    serial:     string
    hostfwd:    int
    tpm:        bool
    sock_path:  string
    keep_wait:  bool
] {
    let cpu = cpu-model "aarch64" $accel

    mut args = [
        "qemu-system-aarch64"
        "-machine" $"virt,accel=($accel)"
        "-cpu"     $cpu
        "-bios"    $bios
        "-m"       $mem
        "-smp"     ($cpus | into string)
        "-drive"   $"file=($image),format=($img_fmt),if=virtio"
        "-nic"     $"user,model=virtio-net-pci,hostfwd=tcp::($hostfwd)-:22"
        "-nographic"
        "-monitor" "none"
    ]
    $args = ($args | append (fw-boot-menu-args "aarch64" $accel $keep_wait))
    # -nographic redirects serial to stdio implicitly; adding -serial stdio
    # would cause "cannot use stdio by multiple character devices" — omit it.
    # For non-stdio serial (file:, unix:), append explicitly.
    if $serial != "stdio" {
        $args = ($args | append ["-serial" $serial])
    }

    # TPM — aarch64 QEMU: tpm-tis-device
    if $tpm {
        $args = ($args | append [
            "-chardev" $"socket,id=chrtpm,path=($sock_path)"
            "-tpmdev"  "emulator,id=tpm0,chardev=chrtpm"
            "-device"  "tpm-tis-device,tpmdev=tpm0"
        ])
    }

    $args
}

# Build the QEMU argument list for an amd64 guest.
def build-cmd-amd64 [
    image:      string
    img_fmt:    string
    mem:        string
    cpus:       int
    accel:      string
    bios:       string
    serial:     string
    hostfwd:    int
    tpm:        bool
    sock_path:  string
] {
    let cpu = cpu-model "amd64" $accel

    mut args = [
        "qemu-system-x86_64"
        "-M"       "q35"
        "-accel"   $accel
        "-cpu"     $cpu
        "-bios"    $bios
        "-m"       $mem
        "-smp"     ($cpus | into string)
        "-drive"   $"file=($image),format=($img_fmt),if=virtio"
        "-nic"     $"user,model=virtio-net-pci,hostfwd=tcp::($hostfwd)-:22"
        "-nographic"
        "-monitor" "none"
    ]
    # -nographic redirects serial to stdio implicitly; adding -serial stdio
    # would cause "cannot use stdio by multiple character devices" — omit it.
    # For non-stdio serial (file:, unix:), append explicitly.
    if $serial != "stdio" {
        $args = ($args | append ["-serial" $serial])
    }

    # TPM — amd64 QEMU: tpm-tis
    if $tpm {
        $args = ($args | append [
            "-chardev" $"socket,id=chrtpm,path=($sock_path)"
            "-tpmdev"  "emulator,id=tpm0,chardev=chrtpm"
            "-device"  "tpm-tis,tpmdev=tpm0"
        ])
    }

    $args
}

# ── Preflight ─────────────────────────────────────────────────────────────────

def preflight [arch: string, accel: string, bios: string, tpm: bool] {
    # Confirm the QEMU binary exists
    let qemu_bin = if $arch == "aarch64" { "qemu-system-aarch64" } else { "qemu-system-x86_64" }
    let which_r  = (^which $qemu_bin | complete)
    if $which_r.exit_code != 0 {
        error make {msg: $"($qemu_bin) not found on PATH; install QEMU (brew install qemu / pkg install qemu)"}
    }
    log-step "preflight" $"($qemu_bin) found" {path: ($which_r.stdout | str trim)}

    # Warn if BIOS does not exist — we already logged in find-bios; just note it.
    if not ($bios | path exists) {
        log-step "preflight" "WARNING: BIOS firmware file missing — VM may fail to boot" {bios: $bios}
    }

    # Accelerator sanity check
    if $accel == "hvf" {
        let hv_r = (^sysctl kern.hv_support | complete)
        let supported = $hv_r.exit_code == 0 and (
            $hv_r.stdout | str trim | split row ":" | last | str trim
        ) == "1"
        if not $supported {
            log-step "preflight" "WARNING: HVF requested but kern.hv_support != 1; falling back may be needed" {}
        }
    } else if $accel == "kvm" {
        if not ("/dev/kvm" | path exists) {
            log-step "preflight" "WARNING: KVM requested but /dev/kvm not found" {}
        }
    }

    # swtpm check (only if --tpm)
    if $tpm {
        let _swtpm = find-swtpm   # errors with clear message if absent
        log-step "preflight" "swtpm found" {}
    }
}

# ── Main ──────────────────────────────────────────────────────────────────────

# Launch smolfire in QEMU with optional swtpm TPM attachment.
#
# --image      Path to smolfire qcow2 or raw disk image (required)
# --arch       Guest architecture: aarch64 (default) or amd64
# --mem        Guest RAM, e.g. 256M, 512M, 1G (default: 256M)
# --cpus       Number of virtual CPUs (default: 2)
# --tpm        Attach an swtpm TPM 2.0 device to the guest
# --tpm-state  swtpm state directory (default: /var/run/smolfire-qemu-tpm)
# --hostfwd-ssh  Host port forwarded to guest :22 (default: 2241)
# --serial     QEMU -serial target: stdio (default), file:/path, unix:/path,server
# --dry-run    Print the QEMU command line without executing
# --name       Label used in log output (default: smolfire-qemu)
# --accel      Override accelerator: hvf | kvm | tcg (default: auto-detect)
# --fw-menu-wait  aarch64+HVF: keep EDK2's ~5 s boot-menu wait (omit -boot menu=on,splash-time=0)
def main [
    --image:        string                                       # path to smolfire qcow2 or raw image
    --arch:         string = "aarch64"                           # aarch64 | amd64
    --mem:          string = "256M"
    --cpus:         int    = 2
    --tpm                                                        # attach swtpm TPM 2.0 device
    --tpm-state:    string = "/var/run/smolfire-qemu-tpm"         # swtpm state directory
    --hostfwd-ssh:  int    = 2241                                # host port -> guest :22
    --serial:       string = "stdio"                             # stdio | file:/path | unix:/path,server
    --dry-run                                                    # print command; do not run
    --name:         string = "smolfire-qemu"                      # label for log output
    --accel:        string = ""                                  # "" = auto-detect
    --fw-menu-wait                                               # aarch64+HVF: keep EDK2 boot-menu wait (A/B)
] {
    # ── Validate ────────────────────────────────────────────────────────────
    if $image == null or ($image | str length) == 0 {
        error make {msg: "--image is required (path to smolfire qcow2 or raw image)"}
    }

    if not ($image | path exists) {
        error make {msg: $"image not found: ($image)"}
    }

    # Normalise arch: accept both "aarch64" and "arm64" / "amd64" and "x86_64"
    let arch = match ($arch | str downcase) {
        "aarch64" | "arm64"       => "aarch64"
        "amd64"   | "x86_64"      => "amd64"
        _ => { error make {msg: $"--arch must be aarch64 or amd64, got: ($arch)"} }
    }

    # Resolve accelerator
    let accel = if ($accel | str length) > 0 {
        $accel | str downcase
    } else {
        detect-accel $arch
    }

    let bios    = find-bios $arch
    let img_fmt = detect-image-format $image

    log-step "preflight" "qemu-smolfire starting" {
        image:       $image
        arch:        $arch
        accel:       $accel
        mem:         $mem
        cpus:        $cpus
        tpm:         $tpm
        serial:      $serial
        hostfwd_ssh: $hostfwd_ssh
        name:        $name
        dry_run:     $dry_run
        bios:        $bios
        img_fmt:     $img_fmt
        fw_menu_wait: $fw_menu_wait
    }

    preflight $arch $accel $bios $tpm

    # ── Start swtpm if requested ─────────────────────────────────────────────
    mut sock_path = ""
    if $tpm {
        if $dry_run {
            let swtpm_cmd = (find-swtpm)
            $sock_path = $"($tpm_state)/swtpm.sock"
            log-step "swtpm-dry" "would start swtpm" {
                bin:       $swtpm_cmd
                state_dir: $tpm_state
                sock:      $sock_path
            }
            print $"($swtpm_cmd) socket --tpmstate dir=($tpm_state) --tpm2 --ctrl type=unixio,path=($sock_path) --daemon"
        } else {
            $sock_path = start-swtpm $tpm_state
        }
    }

    # ── Build QEMU command line ──────────────────────────────────────────────
    let qemu_cmd = if $arch == "aarch64" {
        build-cmd-aarch64 $image $img_fmt $mem $cpus $accel $bios $serial $hostfwd_ssh $tpm $sock_path $fw_menu_wait
    } else {
        build-cmd-amd64   $image $img_fmt $mem $cpus $accel $bios $serial $hostfwd_ssh $tpm $sock_path
    }

    log-step "qemu-cmd" "constructed QEMU command line" {
        arch: $arch
        accel: $accel
        cmd:  ($qemu_cmd | str join " ")
    }

    # ── Dry-run ──────────────────────────────────────────────────────────────
    if $dry_run {
        log-step "dry-run" "dry-run mode — printing command and exiting" {}
        print ""
        print "# QEMU launch command:"
        print ($qemu_cmd | str join " ")
        print ""
        let ssh_hint = $"ssh -p ($hostfwd_ssh) root@127.0.0.1"
        print $"# SSH after boot:  ($ssh_hint)"
        if $tpm {
            print ""
            print "# To read PCR0 after boot (in guest):"
            print "#   tpm2_pcrread sha256:0"
        }
        if $accel == "tcg" {
            print ""
            print "# NOTE: running with TCG (software emulation) — boot may take several minutes"
        }
        return
    }

    # ── Launch QEMU ──────────────────────────────────────────────────────────
    log-step "qemu-run" "launching QEMU" {name: $name, accel: $accel, serial: $serial}
    let ssh_run_hint = $"ssh -p ($hostfwd_ssh) root@127.0.0.1"
    print $"# SSH after boot:  ($ssh_run_hint)"
    if $serial == "stdio" {
        print "# Console output appears here (stdio). Press Ctrl-A X to quit QEMU."
    }
    print ""

    run-external ($qemu_cmd | first) ...($qemu_cmd | skip 1)
    let qemu_exit = $env.LAST_EXIT_CODE

    log-step "qemu-exit" "QEMU exited" {exit_code: $qemu_exit, name: $name}

    # ── Cleanup ──────────────────────────────────────────────────────────────
    if $tpm {
        stop-swtpm $tpm_state
    }

    log-step "done" "qemu-smolfire finished" {exit_code: $qemu_exit}

    if $qemu_exit != 0 {
        exit $qemu_exit
    }
}
