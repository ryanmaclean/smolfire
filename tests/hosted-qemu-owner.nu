#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Hosted QEMU ownership witness and no-signal natural-exit reconciliation.

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def digest [path: string] { open --raw $path | hash sha256 }
def names [work: string, mode: string] {
    require ($mode in ['build' 'microvm']) 'unknown QEMU ownership mode'
    if $mode == 'build' {
        {pidfile: ($work | path join 'vm.pid'), owner: ($work | path join 'vm-owner.json'), marker: ($work | path join 'vm.pid'), receipt: ($work | path join 'vm-cleanup.json')}
    } else {
        {pidfile: ($work | path join 'qemu-microvm.pid'), owner: ($work | path join 'qemu-microvm-owner.json'), marker: ($work | path join 'smolfire-kernel'), receipt: ($work | path join 'qemu-microvm-cleanup.json')}
    }
}
def generation_state [pid: string] {
    let path = $"/proc/($pid)/stat"
    require ($path | path exists) 'QEMU PID disappeared during state read'
    let fields = (open --raw $path | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19 and $fields.0 =~ '^[A-Za-z]$' and $fields.19 =~ '^[0-9]+$') 'QEMU state or generation unreadable'
    {state: $fields.0, generation: $fields.19}
}
def snapshot [pid: string] {
    let base = (generation_state $pid)
    let cmd = $"/proc/($pid)/cmdline"
    require ($cmd | path exists) 'QEMU PID disappeared during argv read'
    let argv = (open --raw $cmd | decode utf-8 | split row (char nul) | where $it != '')
    let exe = (^readlink -f $"/proc/($pid)/exe" | complete)
    if not ($base.state in ['Z' 'X' 'x']) {
        require (($argv | length) > 0 and $exe.exit_code == 0 and ($exe.stdout | str trim | str length) > 0) 'live QEMU argv or executable unreadable'
    }
    require ((generation_state $pid).generation == $base.generation) 'QEMU PID generation changed during observation'
    {pid: $pid, generation: $base.generation, state: $base.state, argv: $argv, exe: (if $exe.exit_code == 0 { $exe.stdout | str trim } else { '' })}
}
def exact_owner [owner: record, names: record, mode: string] {
    require ($owner.mode == $mode and $owner.marker == $names.marker) 'QEMU owner mode or unique marker changed'
    require (($owner.pid | into string) =~ '^[0-9]+$' and ($owner.generation | into string) =~ '^[0-9]+$') 'QEMU owner PID or generation malformed'
    require (($owner.exe | path basename) == 'qemu-system-x86_64' and ($owner.argv | length) > 4 and $names.marker in $owner.argv) 'QEMU owner executable or exact marker invalid'
}
export def owner_identity_decision [observed: record, owner: record] {
    if $observed.generation != ($owner.generation | into string) { return 'HOLD' }
    if ($observed.state in ['Z' 'X' 'x']) { return 'EXITED' }
    if $observed.exe != $owner.exe or $observed.argv != $owner.argv { return 'HOLD' }
    'MATCH'
}
export def ssh_target_decision [owner: record, port: string, known: string, public: string] {
    if not ($port =~ '^[0-9]+$') { return 'HOLD' }
    let parts = ($public | str trim | split row ' ' | where $it != '')
    if ($parts | length) < 2 or $parts.0 != 'ssh-ed25519' { return 'HOLD' }
    let expected = $"[127.0.0.1]:($port) ($parts.0) ($parts.1)"
    let nic = $"user,model=virtio-net-pci,hostfwd=tcp::($port)-:22"
    if ($known | str trim) != $expected or not ($nic in $owner.argv) { return 'HOLD' }
    'MATCH'
}
export def ssh_known_hosts_option [path: string] {
    require ($path | str starts-with '/') 'pinned known_hosts path must be absolute'
    $"UserKnownHostsFile=($path)"
}
def exact_live_snapshot [observed: record, owner: record] {
    require ((owner_identity_decision $observed $owner) in ['MATCH' 'EXITED']) 'QEMU PID generation, executable, or exact argv changed during wait'
}
export def matching_marker_pids [marker: string, proc_root: string = '/proc'] {
    mut matching = []
    for row in (ls $proc_root | where type == dir) {
        let pid = ($row.name | path basename)
        if not ($pid =~ '^[0-9]+$') { continue }
        let proc = ($proc_root | path join $pid)
        let comm = (try { {ok: true, value: (open --raw ($proc | path join 'comm') | str trim)} } catch { {ok: false, value: ''} })
        if not ($proc | path exists) { continue }
        require $comm.ok $"present PID ($pid) has unreadable comm during QEMU scan"
        if not ($comm.value | str starts-with 'qemu-system-x86') { continue }
        let cmd = (try { {ok: true, value: (open --raw ($proc | path join 'cmdline') | decode utf-8)} } catch { {ok: false, value: ''} })
        if not ($proc | path exists) { continue }
        require ($cmd.ok and ($cmd.value | str length) > 0) $"QEMU PID ($pid) has unreadable or empty cmdline during scan"
        let argv = ($cmd.value | split row (char nul) | where $it != '')
        if $marker in $argv { $matching = ($matching | append $pid) }
    }
    $matching | uniq | sort
}
export def wait_decision [present: bool, same_generation: bool, readable_state: bool, exhausted: bool] {
    if not $present { return 'EXITED' }
    if not $same_generation or not $readable_state or $exhausted { return 'HOLD' }
    'WAIT'
}
def capture [work: string, mode: string] {
    let n = (names $work $mode)
    require ($n.pidfile | path exists) 'QEMU pidfile absent after launch'
    let pid = (open --raw $n.pidfile | str trim)
    require ($pid =~ '^[0-9]+$') 'QEMU pidfile malformed'
    let observed = (snapshot $pid)
    require (($observed.exe | path basename) == 'qemu-system-x86_64' and $n.marker in $observed.argv) 'spawned QEMU does not match exact unique marker'
    let owner = {mode: $mode, pid: $pid, generation: $observed.generation, marker: $n.marker, exe: $observed.exe, argv: $observed.argv}
    $owner | to json --raw | save --raw --force $n.owner
    $owner
}
def cleanup [work: string, mode: string] {
    let n = (names $work $mode)
    if not ($n.owner | path exists) and not ($n.pidfile | path exists) {
        let matches = (matching_marker_pids $n.marker)
        require (($matches | length) == 0) 'QEMU exact marker active without a pidfile or owner record'
        return {mode: $mode, state: 'no-pidfile', pid: '', forced: false, marker: $n.marker, matching_marker_pids: $matches}
    }
    require (($n.owner | path exists) and ($n.pidfile | path exists)) 'QEMU owner or pidfile missing'
    let owner = (open $n.owner)
    exact_owner $owner $n $mode
    let pid = ($owner.pid | into string)
    let generation = ($owner.generation | into string)
    require ((open --raw $n.pidfile | str trim) == $pid) 'QEMU pidfile differs from spawn-time owner'
    let proc = $"/proc/($pid)"
    mut shutdown_rc = -1
    mut observation = {path: '', sha256: ''}
    if ($proc | path exists) {
        let first = (snapshot $pid)
        require ((owner_identity_decision $first $owner) == 'MATCH') 'build VM changed identity or exited before command'
        let observed_path = ($work | path join $"(if $mode == 'build' { 'vm' } else { 'qemu-microvm' })-observation.json")
        $first | to json --raw | save --raw --force $observed_path
        $observation = {path: $observed_path, sha256: (digest $observed_path)}
        if $mode == 'build' {
            let only_owner = (matching_marker_pids $n.marker)
            require ($only_owner == [$pid]) 'build VM marker is ambiguous before guest command'
            let port = ($env.SSH_PORT? | default '2253')
            let known_path = ($work | path join 'known_hosts')
            let pub_path = ($work | path join 'ci_host_key.pub')
            require (($known_path | path exists) and ($pub_path | path exists)) 'pinned build VM SSH host identity missing'
            let known = (open --raw $known_path)
            let public = (open --raw $pub_path)
            require ((ssh_target_decision $owner $port $known $public) == 'MATCH') 'build VM SSH route or pinned host key mismatched'
            let key_check = (^ssh-keygen -y -f ($work | path join 'ci_host_key') | complete)
            require ($key_check.exit_code == 0 and ((($key_check.stdout | str trim | split row ' ' | first 2) | str join ' ') == (($public | str trim | split row ' ' | first 2) | str join ' '))) 'pinned SSH public key does not match job private key'
            # A second exact observation narrows the interval before dialing.
            require ((owner_identity_decision (snapshot $pid) $owner) == 'MATCH') 'build VM changed identity before SSH shutdown'
            let known_option = (ssh_known_hosts_option $known_path)
            let command = (^ssh -i ($work | path join 'ci_key') -o StrictHostKeyChecking=yes -o $known_option -o HostKeyAlgorithms=ssh-ed25519 -o ConnectTimeout=3 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 -o BatchMode=yes -p $port root@127.0.0.1 'shutdown -p now' | complete)
            $shutdown_rc = $command.exit_code
            {exit_code: $shutdown_rc, stderr: $command.stderr} | to json --raw | save --raw --force ($work | path join 'vm-shutdown-attempt.json')
            require ($shutdown_rc == 0) 'pinned build VM shutdown command failed'
        }
        for tick in 1..50 {
            if not ($proc | path exists) { break }
            let current = (snapshot $pid)
            exact_live_snapshot $current $owner
            require ((wait_decision true ($current.generation == $generation) ($current.state =~ '^[A-Za-z]$') ($tick == 50)) == 'WAIT') 'QEMU persisted, changed generation, or became unreadable during bounded wait'
            sleep 200ms
        }
        require (not ($proc | path exists)) 'QEMU remained after bounded natural-exit wait'
    }
    let matches = (matching_marker_pids $n.marker)
    require (($matches | length) == 0) 'another QEMU still uses the exact job marker'
    {mode: $mode, state: (if $observation.path == '' { 'already-exited' } else { 'naturally-exited' }), pid: $pid, generation: $generation, forced: false, marker: $n.marker, matching_marker_pids: $matches, observation: $observation, shutdown_rc: $shutdown_rc}
}
def main [--work: string = '/mnt/smolfire-ci', --mode: string, --capture, --cleanup, --receipt: string = ''] {
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'QEMU owner helper requires hosted Linux'
    require ($capture != $cleanup) 'choose exactly one of capture or cleanup'
    let n = (names $work $mode)
    let path = (if $receipt == '' { $n.receipt } else { $receipt })
    let result = (try { {ok: true, value: (if $capture { capture $work $mode } else { cleanup $work $mode })} } catch {|err| {ok: false, error: $err.msg} })
    if not $result.ok {
        {mode: $mode, state: 'hold-unresolved', forced: false, reason: $result.error} | to json --raw | save --raw --force $path
        error make {msg: $result.error}
    }
    $result.value | to json --raw | save --raw --force $path
    print ($result.value | to json --raw)
}
