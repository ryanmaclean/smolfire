#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bin/vm-execute.nu — execute commands inside a smolfire VM, return reply
#
# This is the bridge between the coordinator and a real running VM.
# Boots the qcow2 via QEMU, runs commands via SSH, captures output,
# shuts down cleanly, and returns a structured reply record.
#
# Usage from another module:
#   use vm-execute.nu [run-vm-task]
#   let reply = run-vm-task "task-0042" "build/FreeBSD-15-aarch64-smolfire.qcow2" ["uname -a"]

# Run a list of commands inside a smolfire VM and return structured output.
# Returns: {verdict: "pass"|"fail", boot_sec: int, outputs: list<{cmd, stdout, stderr, exit_code}>, error?: string}
export def run-vm-task [
    task_id:    string          # unique task identifier (used for temp file names)
    image_path: string          # path to qcow2 image
    commands:   list<string>    # commands to run inside the VM
    --arch:     string = "arm64"       # arm64 | amd64
    --port:     int    = 2234          # SSH hostfwd port (avoid collisions)
    --timeout:  int    = 90            # boot timeout in seconds
    --user:     string = "root"        # VM SSH user
    --password: string = "smolfire"    # VM root password
    --use-overlay                      # mount thin overlay (keeps base image clean)
] {
    # Locate QEMU binary
    let qemu = if $arch == "arm64" {
        "/opt/homebrew/bin/qemu-system-aarch64"
    } else {
        "/opt/homebrew/bin/qemu-system-x86_64"
    }
    if not ($qemu | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: $"qemu not found: ($qemu)"}
    }

    # Locate sshpass binary
    let sshpass_bin = "/opt/homebrew/bin/sshpass"
    if not ($sshpass_bin | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: "sshpass not found at /opt/homebrew/bin/sshpass — run: brew install hudochenkov/sshpass/sshpass"}
    }

    let abs_image = $image_path | path expand
    if not ($abs_image | path exists) {
        return {verdict: "fail", boot_sec: 0, outputs: [], error: $"image not found: ($abs_image)"}
    }

    # BIOS args (aarch64 needs EDK2 firmware)
    let bios_args = if $arch == "arm64" {
        let bios = "/opt/homebrew/share/qemu/edk2-aarch64-code.fd"
        if ($bios | path exists) { ["-bios" $bios] } else { [] }
    } else { [] }

    # Machine/CPU args
    let machine_args = if $arch == "arm64" {
        ["-machine" "virt,accel=hvf" "-cpu" "host"]
    } else {
        ["-machine" "q35" "-cpu" "qemu64"]
    }

    # Create overlay if requested (protects the base image from writes)
    let actual_image = if $use_overlay {
        let overlay = $"/tmp/smolfire-($task_id)-overlay.qcow2"
        let r = (^/opt/homebrew/bin/qemu-img create -f qcow2 -F qcow2 -b $abs_image $overlay) | complete
        if $r.exit_code != 0 {
            return {verdict: "fail", boot_sec: 0, outputs: [], error: $"qemu-img overlay failed: ($r.stderr)"}
        }
        $overlay
    } else {
        $abs_image
    }

    let log_path = $"/tmp/vm-execute-($task_id).log"

    # Spawn QEMU as a Nushell background job.
    # -display none: suppress graphical output (compatible with -serial file:)
    # -serial file:  captures boot console to log_path for debugging
    # Note: -daemonize conflicts with -nographic on macOS QEMU; use job spawn instead.
    let err_path   = $"/tmp/vm-execute-($task_id).err"
    let serial_arg = $"file:($log_path)"
    let drive_arg  = $"file=($actual_image),format=qcow2,if=virtio"
    let nic_arg    = $"user,model=virtio-net-pci,hostfwd=tcp::($port)-:22"
    let qemu_job_id = job spawn {
        ^$qemu ...$machine_args ...$bios_args -m 256M -smp 2 -drive $drive_arg -nic $nic_arg -display none -serial $serial_arg e> $err_path
    }

    # Poll SSH port until it responds (VM boot)
    let t0 = (date now | into int) // 1_000_000_000
    mut ssh_ready = false
    mut elapsed = 0
    while $elapsed < $timeout {
        sleep 2sec
        let probe = (^nc -z -w 1 localhost $port) | complete
        if $probe.exit_code == 0 {
            $ssh_ready = true
            break
        }
        $elapsed = ((date now | into int) // 1_000_000_000) - $t0
    }
    let boot_sec = ((date now | into int) // 1_000_000_000) - $t0

    if not $ssh_ready {
        try { job kill $qemu_job_id } catch { }
        if $use_overlay { rm -f $actual_image }
        return {verdict: "fail", boot_sec: $boot_sec, outputs: [], error: $"SSH not reachable within ($timeout)s"}
    }

    # Run each command via SSH
    mut outputs = []
    mut all_ok = true
    for cmd in $commands {
        let ssh_result = (^$sshpass_bin -p $password ssh
            -o StrictHostKeyChecking=no
            -o UserKnownHostsFile=/dev/null
            -o LogLevel=ERROR
            -p $port
            $"($user)@localhost"
            $cmd
        ) | complete
        $outputs = $outputs | append {
            cmd:       $cmd
            stdout:    ($ssh_result.stdout | str trim)
            stderr:    ($ssh_result.stderr | str trim)
            exit_code: $ssh_result.exit_code
        }
        if $ssh_result.exit_code != 0 { $all_ok = false }
    }

    # Graceful shutdown: ask the VM to halt, then force-kill the job
    let _ = (^$sshpass_bin -p $password ssh
        -o StrictHostKeyChecking=no
        -o UserKnownHostsFile=/dev/null
        -o LogLevel=ERROR
        -p $port
        $"($user)@localhost"
        "shutdown -p now"
    ) | complete
    sleep 3sec
    try { job kill $qemu_job_id } catch { }

    # Cleanup temp files
    if $use_overlay { rm -f $actual_image }
    rm -f $"/tmp/vm-execute-($task_id).err"

    {
        verdict:  (if $all_ok { "pass" } else { "fail" })
        boot_sec: $boot_sec
        outputs:  $outputs
    }
}
