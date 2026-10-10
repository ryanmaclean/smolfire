#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Hosted ordinary gate cleanup: observe natural exit; never signal a PID.
use firecracker-owner-scan.nu matching_config_pids

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def digest [path: string] { open --raw $path | hash sha256 }
def generation_state [pid: string] {
    let stat = $"/proc/($pid)/stat"
    require ($stat | path exists) 'ordinary owner disappeared during state read'
    let fields = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19 and $fields.0 =~ '^[A-Za-z]$' and $fields.19 =~ '^[0-9]+$') 'ordinary owner state or generation unreadable'
    {state: $fields.0, generation: $fields.19}
}
def snapshot [pid: string] {
    let base = (generation_state $pid)
    let cmd = $"/proc/($pid)/cmdline"
    require ($cmd | path exists) 'ordinary owner disappeared during argv read'
    let args = (open --raw $cmd | decode utf-8 | split row (char nul) | where $it != '')
    let exe = (^readlink -f $"/proc/($pid)/exe" | complete)
    if not ($base.state in ['Z' 'X' 'x']) {
        require (($args | length) > 0 and $exe.exit_code == 0 and ($exe.stdout | str trim | str length) > 0) 'live ordinary owner argv or executable unreadable'
    }
    require ((generation_state $pid).generation == $base.generation) 'ordinary PID changed during observation'
    {pid: $pid, generation: $base.generation, state: $base.state, argv: $args, exe: (if $exe.exit_code == 0 { $exe.stdout | str trim } else { '' })}
}
export def wait_decision [present: bool, same_generation: bool, readable_state: bool, exhausted: bool] {
    if not $present { return 'EXITED' }
    if not $same_generation or not $readable_state or $exhausted { return 'HOLD' }
    'WAIT'
}
def cleanup [work: string] {
    let config = ($work | path join 'fc.json')
    let binary = ($work | path join 'firecracker')
    let owner_path = ($work | path join 'firecracker-owner.json')
    let pidfile = ($work | path join 'firecracker.pid')
    require (($config | path exists) and ($owner_path | path exists) and ($pidfile | path exists)) 'ordinary gate config or spawn-time owner record absent'
    let owner = (open $owner_path)
    require (($owner.pid | into string) =~ '^[0-9]+$' and ($owner.generation | into string) =~ '^[0-9]+$') 'ordinary owner PID or generation malformed'
    require ($owner.config == $config and $owner.exe == $binary and $owner.argv == [$binary '--no-api' '--config-file' $config]) 'ordinary owner identity differs from exact gate intent'
    require ((open --raw $pidfile | str trim) == ($owner.pid | into string)) 'ordinary PID file differs from spawn-time owner'
    let pid = ($owner.pid | into string)
    let generation = ($owner.generation | into string)
    let proc = $"/proc/($pid)"
    mut observation = {path: '', sha256: ''}
    if ($proc | path exists) {
        let first = (snapshot $pid)
        require ($first.generation == $generation) 'ordinary owner PID generation changed'
        let observation_path = ($work | path join 'firecracker-ordinary-observation.json')
        $first | to json --raw | save --raw --force $observation_path
        $observation = {path: $observation_path, sha256: (digest $observation_path)}
        for tick in 1..20 {
            if (wait_decision ($proc | path exists) true true false) == 'EXITED' { break }
            let current = (snapshot $pid)
            require ((wait_decision true ($current.generation == $generation) ($current.state =~ '^[A-Za-z]$') ($tick == 20)) == 'WAIT') 'ordinary owner persisted, changed generation, or became unreadable during bounded wait'
            sleep 200ms
        }
        require (not ($proc | path exists)) 'ordinary owner remained after bounded natural-exit wait'
    }
    let matches = (matching_config_pids [$config])
    require (($matches | length) == 0) 'ordinary Firecracker still uses gate config; hold without signal'
    {state: (if $observation.path == '' { 'already-exited' } else { 'naturally-exited' }), pid: $pid, generation: $generation, forced: false, scanned_config: $config, matching_config_pids: $matches, observation: $observation}
}
def main [--work: string = '/mnt/smolfire-ci', --receipt: string = ''] {
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'ordinary cleanup requires hosted Linux'
    let receipt_path = (if $receipt == '' { $work | path join 'firecracker-ordinary-cleanup.json' } else { $receipt })
    let result = (try { {ok: true, value: (cleanup $work)} } catch {|err| {ok: false, error: $err.msg} })
    if not $result.ok {
        {state: 'hold-unresolved', forced: false, reason: $result.error} | to json --raw | save --raw --force $receipt_path
        error make {msg: $result.error}
    }
    $result.value | to json --raw | save --raw --force $receipt_path
    print ($result.value | to json --raw)
}
