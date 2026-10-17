#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Read-only exact-config process scan shared by teardown and final verdict.
def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }

export def read_decision [pid_present: bool, cmdline_read_ok: bool, argv_nonempty: bool] {
    if not $pid_present { return 'GONE' }
    if not $cmdline_read_ok or not $argv_nonempty { return 'HOLD' }
    'INSPECT'
}

export def matching_config_pids [configs: list<string>] {
    let ps = (^pgrep -x firecracker | complete)
    if $ps.exit_code == 1 { return [] }
    require ($ps.exit_code == 0) 'cannot enumerate Firecracker PIDs'
    mut matches = []
    for pid in ($ps.stdout | lines | where $it =~ '^[0-9]+$') {
        let proc = $"/proc/($pid)"
        let cmd_path = ($proc | path join 'cmdline')
        let read = (try { {ok: true, value: (open --raw $cmd_path | decode utf-8)} } catch { {ok: false, value: ''} })
        let decision = (read_decision ($proc | path exists) $read.ok (($read.value | str length) > 0))
        if $decision == 'GONE' { continue }
        require ($decision == 'INSPECT') $"Firecracker PID ($pid) remains but cmdline is unreadable or empty; no no-owner verdict"
        let args = ($read.value | split row (char nul) | where $it != '')
        require (($args | length) > 0) $"Firecracker PID ($pid) has no readable argv"
        if ($configs | any {|config| $config in $args}) { $matches = ($matches | append $pid) }
    }
    $matches | uniq | sort
}
