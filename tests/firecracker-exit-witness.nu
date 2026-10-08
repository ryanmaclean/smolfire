#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# One hosted FreeBSD guest reboot. Observe Firecracker exit; never signal it.
use firecracker-owner-scan.nu matching_config_pids

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def digest [path: string] { open --raw $path | hash sha256 }
def dir [work: string] { $work | path join 'firecracker-exit-witness' }
def config_path [work: string] { dir $work | path join 'one-boot-config.json' }
def intent_path [work: string] { dir $work | path join 'intent.json' }
def owner_path [work: string] { dir $work | path join 'owner.json' }
def expected_argv [work: string] { [($work | path join 'firecracker') '--no-api' '--config-file' (config_path $work)] }

export def identity_decision [observed: record, owner: record] {
    if $observed.generation != $owner.generation { return 'HOLD' }
    if $observed.state in ['Z' 'X' 'x'] { return 'WAIT_ABSENT' }
    if $observed.exe != $owner.exe or $observed.argv != $owner.argv { return 'HOLD' }
    'WAIT_ABSENT'
}
export def exit_decision [console_eof: bool, reboot_sent: bool, process_gone: bool, exact_scan_empty: bool, global_scan_empty: bool] {
    if $console_eof and $reboot_sent and $process_gone and $exact_scan_empty and $global_scan_empty { 'EXIT_OBSERVED' } else { 'HOLD' }
}
def proc_snapshot [pid: string] {
    let stat = $"/proc/($pid)/stat"
    require ($stat | path exists) 'recorded owner disappeared during identity read'
    let fields = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19 and $fields.0 =~ '^[A-Za-z]$' and $fields.19 =~ '^[0-9]+$') 'owner stat unreadable or malformed'
    let cmd = $"/proc/($pid)/cmdline"
    let args = (open --raw $cmd | decode utf-8 | split row (char nul) | where $it != '')
    let exe = (^readlink -f $"/proc/($pid)/exe" | complete)
    if not ($fields.0 in ['Z' 'X' 'x']) {
        require (($args | length) > 0 and $exe.exit_code == 0 and ($exe.stdout | str trim | str length) > 0) 'live owner argv or executable unreadable'
    }
    let second = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($second | length) > 19 and $second.19 == $fields.19) 'owner generation changed during read'
    {pid: $pid, generation: $fields.19, state: $fields.0, argv: $args, exe: (if $exe.exit_code == 0 { $exe.stdout | str trim } else { '' })}
}
def all_firecracker_pids [] {
    let ps = (^pgrep -x firecracker | complete)
    if $ps.exit_code == 1 { return [] }
    require ($ps.exit_code == 0) 'cannot enumerate Firecracker processes'
    let rows = ($ps.stdout | lines | where $it != '')
    require ($rows | all {|pid| $pid =~ '^[0-9]+$'}) 'Firecracker enumeration malformed'
    $rows | uniq | sort
}
def validate_records [work: string] {
    require ((intent_path $work | path exists) and (owner_path $work | path exists) and (config_path $work | path exists)) 'probe intent, owner or config absent'
    let intent = (open (intent_path $work))
    let owner = (open (owner_path $work))
    let argv = (expected_argv $work)
    require ($intent.config == (config_path $work) and $intent.argv == $argv and $intent.config_sha256 == (digest (config_path $work))) 'probe config changed after intent'
    require ($intent.release_elf_sha256 == (digest ($work | path join 'smolfire-kernel')) and $intent.firecracker_sha256 == (digest ($work | path join 'firecracker'))) 'pinned release ELF or Firecracker changed'
    require ($owner.pid =~ '^[0-9]+$' and $owner.generation =~ '^[0-9]+$') 'owner PID/generation malformed'
    require ($owner.config == $intent.config and $owner.exe == $argv.0 and $owner.argv == $argv) 'owner record differs from exact spawn intent'
    {intent: $intent, owner: $owner}
}
def verify_current [work: string] {
    let records = (validate_records $work)
    let owner = $records.owner
    let observed = (proc_snapshot $owner.pid)
    require (not ($observed.state in ['Z' 'X' 'x']) and (identity_decision $observed $owner) == 'WAIT_ABSENT') 'owner no longer live with exact generation/exe/argv'
    require ((matching_config_pids [$owner.config]) == [$owner.pid]) 'exact config scan does not identify only attached owner'
    require ((all_firecracker_pids) == [$owner.pid]) 'foreign Firecracker present; no console command'
    $observed | to json --raw | save --raw --force (dir $work | path join 'pre-reboot-owner.json')
    {state: 'EXACT_ATTACHED_OWNER', pid: $owner.pid, generation: $owner.generation, config: $owner.config, observation_sha256: (digest (dir $work | path join 'pre-reboot-owner.json'))}
}
def reconcile [work: string] {
    let root = (dir $work)
    if not (intent_path $work | path exists) {
        require ((all_firecracker_pids) | is-empty) 'probe never journaled, but a Firecracker is live'
        return {state: 'no-attempt', forced: false, pid: '', generation: '', matching_config_pids: [], global_firecracker_pids: []}
    }
    let intent = (open (intent_path $work))
    require ($intent.config == (config_path $work) and $intent.argv == (expected_argv $work)) 'attempted config or argv differs from one-boot intent'
    if not (owner_path $work | path exists) {
        let matches = (matching_config_pids [$intent.config])
        require ($matches | is-empty) 'spawn has no owner record and exact config remains live'
        require ((all_firecracker_pids) | is-empty) 'spawn has no owner record and another Firecracker remains live'
        error make {msg: 'spawn intent exists without captured owner; no exit witness'}
    }
    let records = (validate_records $work)
    let owner = $records.owner
    let proc = $"/proc/($owner.pid)"
    mut observation = {path: '', sha256: ''}
    if ($proc | path exists) {
        let first = (proc_snapshot $owner.pid)
        require ((identity_decision $first $owner) == 'WAIT_ABSENT') 'recorded PID generation/exe/argv changed before exit wait'
        let observation_path = ($root | path join 'exit-observation.json')
        $first | to json --raw | save --raw --force $observation_path
        $observation = {path: $observation_path, sha256: (digest $observation_path)}
        for tick in 1..20 {
            if not ($proc | path exists) { break }
            let current = (proc_snapshot $owner.pid)
            require ((identity_decision $current $owner) == 'WAIT_ABSENT') 'recorded owner changed while waiting for natural exit'
            require ($tick < 20) 'recorded Firecracker persists after bounded guest reboot wait'
            sleep 200ms
        }
        require (not ($proc | path exists)) 'recorded Firecracker remains after bounded wait'
    }
    let matches = (matching_config_pids [$intent.config])
    let global = (all_firecracker_pids)
    require (($matches | is-empty) and ($global | is-empty)) 'exact config or foreign Firecracker remains after reboot'
    {state: (if $observation.path == '' { 'already-exited' } else { 'naturally-exited' }), forced: false, pid: $owner.pid, generation: $owner.generation, config: $intent.config, config_sha256: $intent.config_sha256, matching_config_pids: $matches, global_firecracker_pids: $global, observation: $observation}
}
def expect_program [] {
    '
set timeout 30
set rc 0
set t0 [clock milliseconds]
spawn $env(FC_EXIT_BINARY) --no-api --config-file $env(FC_EXIT_CONFIG)
set child [exp_pid]
if {[catch {
  set f [open "/proc/$child/stat" r]
  set stat [read $f]
  close $f
  regexp {^.*\) (.*)$} $stat whole tail
  set fields [split $tail " "]
  set generation [lindex $fields 19]
  if {$generation eq ""} {error "no generation"}
  set out [open $env(FC_EXIT_OWNER) w]
  puts $out "{\"pid\":\"$child\",\"generation\":\"$generation\",\"config\":\"$env(FC_EXIT_CONFIG)\",\"exe\":\"$env(FC_EXIT_BINARY)\",\"argv\":\[\"$env(FC_EXIT_BINARY)\",\"--no-api\",\"--config-file\",\"$env(FC_EXIT_CONFIG)\"\]}"
  close $out
} why]} {
  puts "OWNER_RECORD=fail $why"
  exit 9
}
expect {
  -re "SMOLFIRE_NET_OK $env(FC_EXIT_NONCE)(\\r*\\n)" { puts "NET_GATE=pass" }
  "SMOLFIRE_NET_FAIL" { puts "NET_GATE=fail"; set rc 3 }
  -re {panic:} { puts "PANIC=observed before READY"; set rc 2 }
  timeout { puts "NET_GATE=timeout"; set rc 3 }
  eof { puts "CONSOLE_EOF=early"; set rc 2 }
}
if {$rc == 0} {
  expect {
    "SMOLFIRE_READY" { puts "TIME_TO_READY=[expr {[clock milliseconds]-$t0}]ms" }
    -re {panic:} { puts "PANIC=observed before READY"; set rc 2 }
    timeout { puts "READY=timeout"; set rc 1 }
    eof { puts "CONSOLE_EOF=before_READY"; set rc 2 }
  }
}
if {$rc == 0} {
  send -- {echo FIRE_$((6*7))}
  send -- "\r"
  expect {
    -re {(^|[\r\n])FIRE_42([\r\n]|$)} { puts "SHELL_GATE=pass" }
    timeout { puts "SHELL_GATE=timeout"; set rc 5 }
    eof { puts "CONSOLE_EOF=before_shell"; set rc 5 }
  }
}
if {$rc == 0} {
  if {[catch {exec nu $env(FC_EXIT_HELPER) --verify-current --work $env(FC_EXIT_WORK)} checked]} {
    puts "OWNER_VERIFY=fail $checked"; set rc 7
  } else { puts "OWNER_VERIFY=pass $checked" }
}
if {$rc == 0} {
  send -- "reboot\r"
  puts "GUEST_REBOOT_SENT=1"
  set timeout 15
  expect {
    eof { puts "CONSOLE_EOF=after_reboot" }
    timeout { puts "CONSOLE_EOF=timeout"; set rc 8 }
    -re {panic:} { puts "PANIC=observed after reboot"; set rc 8 }
  }
}
puts "EXPECT_RC=$rc"
exit $rc
'
}
def execute [work: string] {
    require (($env.GITHUB_REF? | default '') | str starts-with 'refs/heads/exp/fc-exit-') 'isolated exit-probe branch required'
    require (($env.GITHUB_SHA? | default '' | str length) == 40 and (^git rev-parse HEAD | str trim) == $env.GITHUB_SHA) 'exact checked-out source head required'
    require ('/dev/kvm' | path exists) 'hosted KVM absent'
    let root = (dir $work)
    require (not ($root | path exists)) 'probe result directory already exists; no second boot'
    require ((all_firecracker_pids) | is-empty) 'prior or foreign Firecracker exists; no probe boot'
    let release = ($work | path join 'smolfire-kernel')
    let binary = ($work | path join 'firecracker')
    require (($release | path exists) and ($binary | path exists)) 'release ELF or Firecracker binary missing'
    let elf = (^file -b $release | complete)
    require ($elf.exit_code == 0 and ($elf.stdout | str contains 'ELF 64-bit')) 'release artifact is not ELF64'
    let strings = (^strings $release | complete)
    require ($strings.exit_code == 0 and not ($strings.stdout | str contains 'SMOLFIRE_TSLOG_BEGIN')) 'instrumented ELF cannot serve as release witness'
    let version = (^$binary --version | complete)
    require ($version.exit_code == 0 and ($version.stdout | str contains 'v1.12.0')) 'Firecracker version mismatch'
    let tap = (^ip -4 addr show dev tap0 | complete)
    require ($tap.exit_code == 0 and ($tap.stdout | str contains '172.16.0.1/30')) 'TAP address mismatch'
    let nonce = $"fc-exit-(random uuid)"
    $nonce | save --raw --force ($work | path join 'www' 'token.txt')
    let fetched = (^curl -fsS --max-time 3 'http://172.16.0.1:8080/token.txt' | complete)
    require ($fetched.exit_code == 0 and $fetched.stdout == $nonce) 'hosted token service did not return exact nonce'
    mkdir $root
    let config = {'boot-source': {kernel_image_path: $release, boot_args: 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt'}, drives: [], 'network-interfaces': [{iface_id: 'eth0', guest_mac: '06:00:AC:10:00:02', host_dev_name: 'tap0'}], 'machine-config': {vcpu_count: 1, mem_size_mib: 512}}
    $config | to json --indent 2 | save --raw (config_path $work)
    {kind: 'firecracker-exit-witness-intent-v1', source_commit: $env.GITHUB_SHA, run_id: ($env.GITHUB_RUN_ID? | default ''), config: (config_path $work), config_sha256: (digest (config_path $work)), release_elf_sha256: (digest $release), firecracker_sha256: (digest $binary), nonce: $nonce, argv: (expected_argv $work)} | to json --indent 2 | save --raw (intent_path $work)
    'one-boot' | save --raw ($root | path join 'current-tag')
    let run = (with-env {FC_EXIT_BINARY: $binary, FC_EXIT_CONFIG: (config_path $work), FC_EXIT_OWNER: (owner_path $work), FC_EXIT_NONCE: $nonce, FC_EXIT_HELPER: ($env.GITHUB_WORKSPACE | path join 'tests' 'firecracker-exit-witness.nu'), FC_EXIT_WORK: $work} { ^expect -c (expect_program) | complete })
    $run.stdout | save --raw ($root | path join 'console.raw')
    $run.stderr | save --raw ($root | path join 'expect.stderr')
    let exit_state = (try { {ok: true, receipt: (reconcile $work)} } catch {|err| {ok: false, receipt: {state: 'hold-unresolved', forced: false, reason: $err.msg}} })
    $exit_state.receipt | to json --raw | save --raw --force ($root | path join 'early-cleanup.json')
    let raw = (open --raw ($root | path join 'console.raw'))
    let evidence = {kind: 'firecracker-freebsd-exit-witness-v1', source_commit: $env.GITHUB_SHA, expect_rc: $run.exit_code, raw_sha256: (digest ($root | path join 'console.raw')), intent_sha256: (digest (intent_path $work)), owner_sha256: (if (owner_path $work | path exists) { digest (owner_path $work) } else { '' }), pre_reboot_owner_sha256: (if ($root | path join 'pre-reboot-owner.json' | path exists) { digest ($root | path join 'pre-reboot-owner.json') } else { '' }), cleanup_sha256: (digest ($root | path join 'early-cleanup.json')), reboot_sent: ($raw | str contains 'GUEST_REBOOT_SENT=1'), console_eof: ($raw | str contains 'CONSOLE_EOF=after_reboot'), nonce_seen: ($raw | str contains $"SMOLFIRE_NET_OK ($nonce)"), ready_seen: ($raw | str contains 'SMOLFIRE_READY'), shell_seen: ($raw | str contains 'SHELL_GATE=pass'), owner_verified: ($raw | str contains 'OWNER_VERIFY=pass'), no_panic: (not ($raw | str contains 'panic:')), exit_state: $exit_state.receipt.state}
    let verdict = (exit_decision $evidence.console_eof $evidence.reboot_sent $exit_state.ok (($exit_state.receipt.matching_config_pids? | default ['unknown']) | is-empty) (($exit_state.receipt.global_firecracker_pids? | default ['unknown']) | is-empty))
    ($evidence | merge {verdict: (if $run.exit_code == 0 and $evidence.nonce_seen and $evidence.ready_seen and $evidence.shell_seen and $evidence.owner_verified and $evidence.no_panic and $verdict == 'EXIT_OBSERVED' { 'EXIT_OBSERVED' } else { 'HOLD' })}) | to json --indent 2 | save --raw --force ($root | path join 'early-result.json')
    require ((open ($root | path join 'early-result.json')).verdict == 'EXIT_OBSERVED') 'FreeBSD reboot did not prove exact Firecracker exit; no second boot'
    print (open --raw ($root | path join 'early-result.json'))
}
def main [--execute, --verify-current, --cleanup-only, --work: string = '/mnt/smolfire-ci'] {
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'hosted Linux only'
    require (($execute | into int) + ($verify_current | into int) + ($cleanup_only | into int) == 1) 'choose exactly one operation'
    if $verify_current { print ((verify_current $work) | to json --raw); return }
    if $execute { execute $work; return }
    let root = (dir $work)
    mkdir $root
    let outcome = (try { {ok: true, receipt: (reconcile $work)} } catch {|err| {ok: false, receipt: {state: 'hold-unresolved', forced: false, reason: $err.msg}} })
    $outcome.receipt | to json --raw | save --raw --force ($root | path join 'workflow-cleanup.json')
    print ($outcome.receipt | to json --raw)
    if not $outcome.ok { error make {msg: $outcome.receipt.reason} }
}
