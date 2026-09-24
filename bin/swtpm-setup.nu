#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# swtpm-setup.nu — host-side swtpm lifecycle management for smolfire bhyve guests.
#
# Manages a software TPM 2.0 daemon (security/swtpm FreeBSD port) that exposes a
# Unix socket consumed by the bhyve launch script (bin/bhyve-smolfire-vm.nu).
#
# Actions:
#   start   — create state dir, launch swtpm daemon, verify socket appears within 3s
#   stop    — send SIGTERM to daemon, wait up to 5s, remove socket + pid file
#   status  — report running state as a TOML record
#   reset   — stop + wipe state dir + start fresh (destroys all PCR state)
#
# swtpm exposes two distinct unix sockets (see swtpm(8)):
#   --server  the TPM command/response *data* channel — this is the socket
#             bhyve dials via `-l tpm,swtpm,<path>` (or QEMU via -chardev).
#   --ctrl    an out-of-band *control* channel (reset, terminate, etc.) that
#             bhyve/QEMU do not use for TPM traffic.
# `--socket` below resolves the data (--server) socket that callers should
# hand to bhyve/QEMU; `--ctrl-socket` resolves the separate control socket.
#
# Usage:
#   nu bin/swtpm-setup.nu --action start
#   nu bin/swtpm-setup.nu --action stop
#   nu bin/swtpm-setup.nu --action status
#   nu bin/swtpm-setup.nu --action reset  # CAUTION: wipes all PCR state

# Emit a structured TOML log-step line to stdout.
# Each action is observable by piping stdout to `tee`.
def log-step [step: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, step: $step} | merge $payload
    $row | to toml | print
    print "---"
}

# Resolve default paths from state_dir when optional flags are empty strings.
#
# `socket` is the swtpm *data* socket (--server) — the one bhyve/QEMU dial
# for TPM traffic. `ctrl_socket` is the separate out-of-band control channel.
def resolve-paths [
    state_dir:   string
    socket:      string
    ctrl_socket: string
    pid_file:    string
] {
    let sock = if ($socket | str length) > 0 {
        $socket
    } else {
        [$state_dir, "swtpm.sock"] | path join
    }
    let ctrl = if ($ctrl_socket | str length) > 0 {
        $ctrl_socket
    } else {
        [$state_dir, "swtpm-ctrl.sock"] | path join
    }
    let pid = if ($pid_file | str length) > 0 {
        $pid_file
    } else {
        [$state_dir, "swtpm.pid"] | path join
    }
    {state_dir: $state_dir, socket: $sock, ctrl_socket: $ctrl, pid_file: $pid}
}

# Build the swtpm(8) argv for `swtpm socket ... --daemon` given a resolved
# `paths` record (as returned by resolve-paths) and the swtpm binary path.
# Pure function — no I/O — so it can be unit-tested without a running swtpm.
def build-start-args [swtpm_bin: string, paths: record]: nothing -> list<string> {
    let tpmstate_arg = $"dir=($paths.state_dir)"
    let server_arg   = $"type=unixio,path=($paths.socket)"
    let ctrl_arg     = $"type=unixio,path=($paths.ctrl_socket)"
    # Note: FreeBSD swtpm uses --pid-file <path>; Ubuntu/Linux swtpm uses --pid file=<path>
    # Use the Linux-compatible form ("--pid file=") which also works on FreeBSD >= 0.7.x
    let pid_arg = $"file=($paths.pid_file)"
    [
        $swtpm_bin
        "socket"
        "--tpmstate" $tpmstate_arg
        "--tpm2"
        "--server" $server_arg
        "--ctrl" $ctrl_arg
        "--pid" $pid_arg
        "--daemon"
    ]
}

# Read pid from pid file; return null if file absent or not a valid integer.
def read-pid [pid_file: string] {
    if not ($pid_file | path exists) {
        return null
    }
    let raw = try { open --raw $pid_file | str trim } catch { return null }
    if ($raw | str length) == 0 {
        return null
    }
    try { $raw | into int } catch { null }
}

# Return true if a process with the given pid is alive (POSIX signal 0 check).
def pid-alive [pid: int] {
    let result = try { ^kill -0 $pid o> /dev/null e> /dev/null; true } catch { false }
    $result
}

# ── action: start ─────────────────────────────────────────────────────────────

def action-start [paths: record] {
    log-step "swtpm_start_begin" {
        state_dir:   $paths.state_dir
        socket:      $paths.socket
        ctrl_socket: $paths.ctrl_socket
        pid_file:    $paths.pid_file
    }

    # Refuse to start if an existing daemon is alive.
    let existing_pid = read-pid $paths.pid_file
    if $existing_pid != null and (pid-alive $existing_pid) {
        log-step "swtpm_start_already_running" {pid: $existing_pid}
        error make {msg: $"swtpm already running with pid ($existing_pid); stop it first or use --action reset"}
    }

    # Create state directory.
    if not ($paths.state_dir | path exists) {
        ^mkdir -p $paths.state_dir
        log-step "swtpm_state_dir_created" {path: $paths.state_dir}
    } else {
        log-step "swtpm_state_dir_exists" {path: $paths.state_dir}
    }

    # Launch swtpm in daemon mode.
    # FreeBSD security/swtpm port installs to /usr/local/bin/swtpm (most versions)
    # or /usr/local/sbin/swtpm (some port revisions).  Probe both.
    let swtpm_candidates = ["/usr/local/bin/swtpm", "/usr/local/sbin/swtpm", "/usr/bin/swtpm"]
    let swtpm_bin = $swtpm_candidates | where {|p| $p | path exists} | first 1
    if ($swtpm_bin | length) == 0 {
        error make {msg: $"swtpm binary not found in ($swtpm_candidates | str join ' or '); install security/swtpm"}
    }
    let swtpm_bin = $swtpm_bin | first

    log-step "swtpm_launching" {
        cmd:         $swtpm_bin
        tpmstate:    $paths.state_dir
        socket:      $paths.socket
        ctrl_socket: $paths.ctrl_socket
        pid_file:    $paths.pid_file
    }

    # --server is the data socket bhyve/QEMU dial for TPM traffic; --ctrl is
    # a separate out-of-band control channel. Both are needed: bhyve's
    # `-l tpm,swtpm,<path>` connects to --server only. See swtpm(8).
    let args = build-start-args $swtpm_bin $paths
    ^$args.0 ...($args | skip 1)

    # Verify socket appears within 3 seconds (poll every 0.3s, 10 attempts).
    let max_polls = 10
    mut poll = 0
    mut socket_appeared = false
    while $poll < $max_polls {
        if ($paths.socket | path exists) {
            $socket_appeared = true
            break
        }
        ^sleep 0.3
        $poll = $poll + 1
    }

    if not $socket_appeared {
        log-step "swtpm_start_socket_timeout" {
            socket:  $paths.socket
            waited:  "3s"
            verdict: "fail"
        }
        error make {msg: $"swtpm socket did not appear at ($paths.socket) within 3s"}
    }

    let pid = read-pid $paths.pid_file
    log-step "swtpm_start_ok" {
        socket:  $paths.socket
        pid:     ($pid | default 0)
        verdict: "pass"
    }
}

# ── action: stop ──────────────────────────────────────────────────────────────

def action-stop [paths: record] {
    log-step "swtpm_stop_begin" {pid_file: $paths.pid_file, socket: $paths.socket, ctrl_socket: $paths.ctrl_socket}

    let pid = read-pid $paths.pid_file
    if $pid == null {
        log-step "swtpm_stop_no_pid" {note: "pid file absent or unreadable; nothing to stop"}
        # Still clean up sockets if they linger.
        if ($paths.socket | path exists) {
            ^rm -f $paths.socket
            log-step "swtpm_stop_stale_socket_removed" {socket: $paths.socket}
        }
        if ($paths.ctrl_socket | path exists) {
            ^rm -f $paths.ctrl_socket
            log-step "swtpm_stop_stale_ctrl_socket_removed" {ctrl_socket: $paths.ctrl_socket}
        }
        return
    }

    if not (pid-alive $pid) {
        log-step "swtpm_stop_not_running" {pid: $pid, note: "process not alive; cleaning up files"}
        if ($paths.socket      | path exists) { ^rm -f $paths.socket }
        if ($paths.ctrl_socket | path exists) { ^rm -f $paths.ctrl_socket }
        if ($paths.pid_file    | path exists) { ^rm -f $paths.pid_file }
        return
    }

    # Send SIGTERM.
    ^kill -TERM $pid
    log-step "swtpm_stop_sigterm_sent" {pid: $pid}

    # Wait up to 5s for the process to exit (poll every 0.5s, 10 attempts).
    let max_polls = 10
    mut poll = 0
    mut exited = false
    while $poll < $max_polls {
        if not (pid-alive $pid) {
            $exited = true
            break
        }
        ^sleep 0.5
        $poll = $poll + 1
    }

    if not $exited {
        log-step "swtpm_stop_timeout" {pid: $pid, waited: "5s", note: "process still alive after SIGTERM"}
        error make {msg: $"swtpm pid ($pid) did not exit within 5s after SIGTERM"}
    }

    # Remove sockets and pid file.
    if ($paths.socket      | path exists) { ^rm -f $paths.socket }
    if ($paths.ctrl_socket | path exists) { ^rm -f $paths.ctrl_socket }
    if ($paths.pid_file    | path exists) { ^rm -f $paths.pid_file }

    log-step "swtpm_stop_ok" {pid: $pid, verdict: "pass"}
}

# ── action: status ────────────────────────────────────────────────────────────

def action-status [paths: record] {
    log-step "swtpm_status_check" {state_dir: $paths.state_dir, socket: $paths.socket, ctrl_socket: $paths.ctrl_socket}

    let pid = read-pid $paths.pid_file
    let running = if $pid != null { pid-alive $pid } else { false }
    let sock_exists = $paths.socket | path exists
    let ctrl_sock_exists = $paths.ctrl_socket | path exists

    let result = {
        running:            $running
        pid:                ($pid | default null)
        socket_exists:      $sock_exists
        ctrl_socket_exists: $ctrl_sock_exists
        state_dir:          $paths.state_dir
        socket:             $paths.socket
        ctrl_socket:        $paths.ctrl_socket
        pid_file:           $paths.pid_file
    }

    log-step "swtpm_status_result" $result
    $result
}

# ── action: reset ─────────────────────────────────────────────────────────────

def action-reset [paths: record] {
    log-step "swtpm_reset_begin" {
        state_dir: $paths.state_dir
        note:      "CAUTION: wipes all PCR state"
    }

    # Stop any running daemon first (non-fatal if already stopped).
    try { action-stop $paths } catch {|err|
        log-step "swtpm_reset_stop_warning" {note: ($err.msg)}
    }

    # Remove state directory entirely.
    if ($paths.state_dir | path exists) {
        ^rm -rf $paths.state_dir
        log-step "swtpm_reset_state_dir_removed" {path: $paths.state_dir}
    }

    # Start fresh.
    action-start $paths
    log-step "swtpm_reset_ok" {verdict: "pass"}
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Manage the smolfire swtpm (software TPM 2.0) daemon for bhyve guests.
#
# --action       start | stop | status | reset
# --state-dir    directory for TPM state files and pid  (default: /var/run/smolfire-tpm)
# --socket       swtpm *data* socket (--server) — pass this to bhyve/QEMU
#                (default: <state-dir>/swtpm.sock)
# --ctrl-socket  swtpm *control* socket (--ctrl) — out-of-band only, not used
#                by bhyve/QEMU for TPM traffic (default: <state-dir>/swtpm-ctrl.sock)
# --pid-file     pid file path     (default: <state-dir>/swtpm.pid)
export def main [
    --action:      string = "status"               # start | stop | status | reset
    --state-dir:   string = "/var/run/smolfire-tpm" # directory for TPM state + pid
    --socket:      string = ""                      # data socket; defaults to <state-dir>/swtpm.sock
    --ctrl-socket: string = ""                      # control socket; defaults to <state-dir>/swtpm-ctrl.sock
    --pid-file:    string = ""                      # defaults to <state-dir>/swtpm.pid
] {
    let paths = resolve-paths $state_dir $socket $ctrl_socket $pid_file

    match $action {
        "start"  => { action-start  $paths }
        "stop"   => { action-stop   $paths }
        "status" => {
            let s = action-status $paths
            $s | to toml | print
        }
        "reset"  => { action-reset  $paths }
        _        => {
            error make {msg: $"unknown action '($action)'; use start | stop | status | reset"}
        }
    }
}
