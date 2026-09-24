#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bhyve-smolfire-vm.nu — launch smolfire inside bhyve with optional swtpm
#
# Boots a smolfire qcow2 or raw image in bhyve on a FreeBSD 15 host.
# With --tpm, starts an swtpm socket daemon and passes it to bhyve as an
# LPC/ACPI CRB TPM device (`-l tpm,swtpm,<socket>`); the guest sees /dev/tpm0
# and can read PCR0 via tpm2-tools.
# --tpm requires --arch amd64 (arm64 bhyve has no TPM device backend — see
# bhyve(8): the tpm frontend is only wired up on amd64).
#
# Prerequisites (on FreeBSD bhyve host):
#   - bhyve(8), bhyvectl(8)  (base system)
#   - swtpm                  (security/swtpm port, BSD-3-Clause) — amd64 + --tpm only
#   - amd64: /usr/local/share/uefi-firmware/BHYVE_UEFI.fd  (sysutils/bhyve-firmware)
#   - arm64: /usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin  (u-boot-bhyve-arm64 port)
#   - tap0 already created and bridged (ifconfig tap0 create; ifconfig bridge0 addm tap0)
#
# amd64 usage:
#   nu bin/bhyve-smolfire-vm.nu --image smolfire-amd64.raw
#   nu bin/bhyve-smolfire-vm.nu --image smolfire-amd64.raw --tpm --dry-run
#
# arm64 usage:
#   nu bin/bhyve-smolfire-vm.nu --image smolfire-arm64.raw --arch arm64
#   nu bin/bhyve-smolfire-vm.nu --image smolfire-arm64.raw --arch arm64 --dry-run
#
# CLI differences between architectures (FreeBSD 15 bhyve):
#
#   amd64:
#     bhyve -H -P \
#       -s 0,hostbridge -s 1,lpc \
#       -s 2,virtio-blk,<img> -s 3,virtio-net,tap0 \
#       -l com1,/dev/nmdm0A \
#       -l bootrom,/usr/local/share/uefi-firmware/BHYVE_UEFI.fd \
#       [-l tpm,swtpm,<data-sock>] \
#       -m 512M -c 2 <vmname>
#
#   TPM is an LPC/ACPI CRB device attached with `-l tpm,swtpm,<socket>`
#   (or `-l tpm,passthru,/dev/tpm0` for passthrough) — NOT a PCI slot
#   (`-s N,tpm,...` is not a valid bhyve device). See bhyve(8).
#
#   arm64 (no -H/-P, no lpc slot, no -l com1, no tpm device):
#     bhyve \
#       -o console=stdio \
#       -o bootrom=/usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin \
#       -s 0,hostbridge \
#       -s 2,virtio-blk,<img> -s 3,virtio-net,tap0 \
#       -m 512M -c 2 <vmname>
#
# See: plans/tinyos/PHASE-2-PHYSICAL-BOOT.md, docs/VM-TESTING.md

# ── Logging ────────────────────────────────────────────────────────────────────

# Emit a timestamped step log line to stdout.
# Structured as TOML for pipeline-friendly output (same convention as qcow2-to-physical.nu).
def log-step [step: string, msg: string, extra: record = {}] {
    let ts   = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let base = {ts: $ts, step: $step, msg: $msg}
    let row  = if ($extra | is-empty) { $base } else { $base | merge $extra }
    $row | to toml | print
    print "---"
}

# ── swtpm helpers ──────────────────────────────────────────────────────────────

# Start an swtpm socket daemon.  Returns the *data* socket path — this is
# the socket bhyve connects to via `-l tpm,swtpm,<path>`.
#
# swtpm exposes two distinct unix sockets:
#   --server  the TPM command/response data channel (what bhyve/QEMU talk to)
#   --ctrl    an out-of-band control channel (reset, terminate, etc.)
# bhyve only ever dials the --server socket; passing the --ctrl socket to
# `-l tpm,swtpm,...` leaves bhyve unable to complete the TPM handshake.
# See swtpm(8).
def start-swtpm [state_dir: string]: nothing -> string {
    let sock      = $"($state_dir)/swtpm.sock"
    let ctrl_sock = $"($state_dir)/swtpm-ctrl.sock"

    log-step "swtpm-start" "creating swtpm state directory" {dir: $state_dir}
    ^mkdir -p $state_dir

    # Probe both install locations; FreeBSD port revision determines which is used.
    let candidates = ["/usr/local/bin/swtpm" "/usr/local/sbin/swtpm"]
    let found = $candidates | where {|p| $p | path exists}
    if ($found | length) == 0 {
        error make {msg: $"swtpm binary not found in ($candidates | str join ' or '); install security/swtpm"}
    }
    let swtpm_bin = $found | first

    log-step "swtpm-start" "launching swtpm daemon" {bin: $swtpm_bin, sock: $sock, ctrl_sock: $ctrl_sock, state: $state_dir}
    let tpmstate_arg = $"dir=($state_dir)"
    let server_arg   = $"type=unixio,path=($sock)"
    let ctrl_arg     = $"type=unixio,path=($ctrl_sock)"
    ^$swtpm_bin socket --tpmstate $tpmstate_arg --tpm2 --server $server_arg --ctrl $ctrl_arg --daemon

    if $env.LAST_EXIT_CODE != 0 {
        error make {msg: $"swtpm failed to start (exit ($env.LAST_EXIT_CODE))"}
    }

    log-step "swtpm-start" "swtpm daemon started" {sock: $sock, ctrl_sock: $ctrl_sock}
    $sock
}

# Stop swtpm by sending SIGTERM to the process recorded in the pid file.
def stop-swtpm [state_dir: string] {
    let sock      = $"($state_dir)/swtpm.sock"
    let ctrl_sock = $"($state_dir)/swtpm-ctrl.sock"
    let pid_file  = $"($state_dir)/swtpm.pid"
    log-step "swtpm-stop" "stopping swtpm" {sock: $sock, ctrl_sock: $ctrl_sock}

    # swtpm writes its PID into <state_dir>/swtpm.pid when --daemon is used
    # with recent swtpm versions; fall back to pkill if the file is absent.
    if ($pid_file | path exists) {
        let pid = open --raw $pid_file | str trim
        ^kill $pid
    } else {
        # Best-effort: kill any swtpm owning the unix socket
        ^pkill -f $"swtpm.*($sock)" o> /dev/null e> /dev/null
    }

    # Remove stale sockets so a subsequent run does not see leftover files
    if ($sock | path exists) {
        ^rm -f $sock
    }
    if ($ctrl_sock | path exists) {
        ^rm -f $ctrl_sock
    }

    log-step "swtpm-stop" "swtpm stopped" {}
}

# ── Command-line builders ──────────────────────────────────────────────────────

# Build the bhyve argument list for an amd64 guest.
# Uses the traditional -H -P -s lpc -l com1 -l bootrom style.
def build-cmd-amd64 [
    name:        string
    image:       string
    mem:         string
    cpus:        int
    console:     string
    tpm:         bool
    sock_path:   string
] {
    let uefi_rom = "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"

    let slots = [
        "-s" "0,hostbridge"
        "-s" "1,lpc"
        "-s" $"2,virtio-blk,($image)"
        "-s" "3,virtio-net,tap0"
        "-s" "4,ahci-cd,/dev/null"
    ]

    # TPM is an LPC/ACPI CRB device, not a PCI slot: `-l tpm,swtpm,<path>`
    # (or `-l tpm,passthru,/dev/tpm0` for passthrough). `-s N,tpm,...` is not
    # a valid bhyve device and is silently wrong. See bhyve(8).
    mut lpc_opts = [
        "-l" $"com1,($console)"
        "-l" $"bootrom,($uefi_rom)"
    ]

    if $tpm {
        $lpc_opts = ($lpc_opts | append ["-l" $"tpm,swtpm,($sock_path)"])
    }

    [
        "bhyve"
        "-H" "-P"
        ...$slots
        ...$lpc_opts
        "-m" $mem
        "-c" ($cpus | into string)
        $name
    ]
}

# Build the bhyve argument list for an arm64 guest.
# Uses the -o console=stdio and -o bootrom= style; no -H/-P, no lpc slot.
def build-cmd-arm64 [
    name:  string
    image: string
    mem:   string
    cpus:  int
] {
    let uboot = "/usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin"

    [
        "bhyve"
        "-o" "console=stdio"
        "-o" $"bootrom=($uboot)"
        "-s" "0,hostbridge"
        "-s" $"2,virtio-blk,($image)"
        "-s" "3,virtio-net,tap0"
        "-m" $mem
        "-c" ($cpus | into string)
        $name
    ]
}

# ── Preflight checks ──────────────────────────────────────────────────────────

def preflight-amd64 [console: string, tpm: bool] {
    let uefi_rom = "/usr/local/share/uefi-firmware/BHYVE_UEFI.fd"
    if not ($uefi_rom | path exists) {
        log-step "preflight" "WARNING: UEFI ROM not found — install sysutils/bhyve-firmware" {path: $uefi_rom}
    }

    # nmdm is required for the console on amd64; warn if the module is not loaded.
    let kldstat_r = (^kldstat | complete)
    if $kldstat_r.exit_code == 0 and not ($kldstat_r.stdout | str contains "nmdm") {
        log-step "preflight" "WARNING: nmdm.ko not loaded — run: kldload nmdm" {}
    }

    if $tpm {
        let candidates = ["/usr/local/bin/swtpm" "/usr/local/sbin/swtpm"]
        let found = $candidates | where {|p| $p | path exists}
        if ($found | length) == 0 {
            error make {msg: "swtpm binary not found; install security/swtpm (required for --tpm)"}
        }
    }
}

def preflight-arm64 [] {
    let uboot = "/usr/local/share/u-boot/u-boot-bhyve-arm64/u-boot.bin"
    if not ($uboot | path exists) {
        log-step "preflight" "WARNING: U-Boot firmware not found — install u-boot-bhyve-arm64 port" {path: $uboot}
    }
}

# ── Main ───────────────────────────────────────────────────────────────────────

def main [
    --image:       string                                # path to smolfire qcow2 or raw image
    --arch:        string = "amd64"                      # amd64 | arm64 (aarch64)
    --mem:         string = "512M"
    --cpus:        int    = 2
    --tpm                                                # attach swtpm via -l tpm,swtpm,<sock> (amd64 only)
    --tpm-state:   string = "/var/run/smolfire-tpm"       # swtpm state directory
    --hostfwd-ssh: int    = 2240                         # host port forwarded to guest :22
    --console:     string = "/dev/nmdm0A"                # amd64: bhyve null-modem device (com1)
    --name:        string = "smolfire"
    --dry-run                                            # print commands without running
] {
    # ── Validate inputs ─────────────────────────────────────────────────────
    if $image == null or $image == "" {
        error make {msg: "--image is required (path to smolfire raw or qcow2 image)"}
    }

    # Normalise arch: accept "aarch64" as an alias for "arm64".
    let arch = if $arch == "aarch64" { "arm64" } else { $arch }

    if $arch != "amd64" and $arch != "arm64" {
        error make {msg: $"--arch must be amd64 or arm64, got: ($arch)"}
    }

    # TPM is amd64-only: arm64 bhyve has no `-l tpm` device backend.
    if $tpm and $arch == "arm64" {
        error make {msg: "arm64 bhyve has no -l tpm device backend; TPM testing requires --arch amd64"}
    }

    if not ($image | path exists) {
        error make {msg: $"image not found: ($image)"}
    }

    log-step "preflight" "bhyve-smolfire starting" {
        image:   $image
        arch:    $arch
        mem:     $mem
        cpus:    $cpus
        tpm:     $tpm
        console: (if $arch == "amd64" { $console } else { "stdio" })
        name:    $name
        dry_run: $dry_run
    }

    # Arch-specific preflight (firmware presence, kernel modules).
    if $arch == "amd64" {
        preflight-amd64 $console $tpm
    } else {
        preflight-arm64
    }

    # ── Start swtpm if requested (amd64 only) ────────────────────────────────
    mut sock_path = ""
    if $tpm {
        if $dry_run {
            log-step "swtpm-dry" "would start swtpm" {
                state_dir: $tpm_state
                sock:      $"($tpm_state)/swtpm.sock"
                ctrl_sock: $"($tpm_state)/swtpm-ctrl.sock"
            }
            print $"swtpm socket --tpmstate dir=($tpm_state) --tpm2 --server type=unixio,path=($tpm_state)/swtpm.sock --ctrl type=unixio,path=($tpm_state)/swtpm-ctrl.sock --daemon"
            $sock_path = $"($tpm_state)/swtpm.sock"
        } else {
            $sock_path = start-swtpm $tpm_state
        }
    }

    # ── Build arch-specific bhyve command line ───────────────────────────────
    let bhyve_cmd = if $arch == "amd64" {
        build-cmd-amd64 $name $image $mem $cpus $console $tpm $sock_path
    } else {
        build-cmd-arm64 $name $image $mem $cpus
    }

    log-step "bhyve-cmd" "constructed bhyve command line" {
        arch: $arch
        cmd:  ($bhyve_cmd | str join " ")
    }

    # ── Dry-run: print and exit ──────────────────────────────────────────────
    if $dry_run {
        log-step "dry-run" "dry-run mode — printing commands and exiting" {}
        print ""
        print "# bhyve launch command:"
        print ($bhyve_cmd | str join " ")
        print ""
        if $arch == "amd64" {
            print $"# Attach to console:  cu -l ($console | str replace 'A' 'B')"
            print $"# or: minicom -D ($console | str replace 'A' 'B')"
        } else {
            print "# arm64 console is stdio — output appears on this terminal."
        }
        if $tpm {
            print ""
            print "# To read PCR0 after boot (in guest):"
            print "#   tpm2_pcrread sha256:0"
        }
        return
    }

    # ── Destroy stale VM if it already exists ────────────────────────────────
    log-step "bhyve-pre" "destroying stale VM (if any)" {name: $name}
    ^bhyvectl --destroy $"--vm=($name)" o> /dev/null e> /dev/null

    # ── Launch bhyve ────────────────────────────────────────────────────────
    if $arch == "amd64" {
        log-step "bhyve-run" "launching bhyve (amd64)" {name: $name, console: $console}
        print $"# Attach to console:  cu -l ($console | str replace 'A' 'B')"
        print $"# or: minicom -D ($console | str replace 'A' 'B')"
        print ""
    } else {
        log-step "bhyve-run" "launching bhyve (arm64)" {name: $name, console: "stdio"}
        print "# arm64: console output appears here (stdio)."
        print ""
    }

    ^...$bhyve_cmd
    let bhyve_exit = $env.LAST_EXIT_CODE

    log-step "bhyve-exit" "bhyve exited" {exit_code: $bhyve_exit, name: $name}

    # ── Cleanup ─────────────────────────────────────────────────────────────
    log-step "cleanup" "destroying bhyve VM" {name: $name}
    ^bhyvectl --destroy $"--vm=($name)" o> /dev/null e> /dev/null

    if $tpm {
        stop-swtpm $tpm_state
    }

    log-step "done" "bhyve-smolfire finished" {exit_code: $bhyve_exit}

    if $bhyve_exit != 0 {
        exit $bhyve_exit
    }
}
