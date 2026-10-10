#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Hosted, branch-only Firecracker boot_mute mechanism experiment.
use cpuid-panic-evidence.nu panic_kernel_seen
use firecracker-version-evidence.nu stable_firecracker_version
use firecracker-owner-scan.nu matching_config_pids

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def digest [path: string] { open --raw $path | hash sha256 }
def result_dir [work: string] { $work | path join 'firecracker-boot-mute' }
def boot_args [variant: string] {
    let base = 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt'
    if $variant == 'on' { $"($base) boot_mute=YES" } else { $base }
}
def argv [work: string, config: string] { [($work | path join 'firecracker') '--no-api' '--config-file' $config] }

def proc_generation [pid: string] {
    let stat = $"/proc/($pid)/stat"
    require ($stat | path exists) 'owner PID disappeared during generation check'
    let fields = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19) 'malformed /proc owner stat'
    $fields | get 19
}
def proc_snapshot [pid: string] {
    let stat = $"/proc/($pid)/stat"
    require ($stat | path exists) 'owner PID disappeared during state check'
    let fields = (open --raw $stat | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19 and $fields.0 =~ '^[A-Za-z]$') 'owner stat unreadable or malformed'
    let state = $fields.0
    let cmd = $"/proc/($pid)/cmdline"
    require ($cmd | path exists) 'owner PID disappeared during argv check'
    let args = (open --raw $cmd | decode utf-8 | split row (char nul) | where $it != '')
    let exe = (^readlink -f $"/proc/($pid)/exe" | complete)
    if not ($state in ['Z' 'X' 'x']) {
        require (($args | length) > 0 and $exe.exit_code == 0 and ($exe.stdout | str trim | str length) > 0) 'live owner cmdline or executable unreadable'
    }
    require ((proc_generation $pid) == $fields.19) 'owner PID generation changed during observation'
    {pid: $pid, generation: $fields.19, state: $state, argv: $args, exe: (if $exe.exit_code == 0 { $exe.stdout | str trim } else { '' })}
}
def owner_decision [same_generation: bool, state: string, readable: bool] {
    if not $same_generation or not $readable { return 'HOLD' }
    if not ($state =~ '^[A-Za-z]$') { return 'HOLD' }
    'WAIT_ABSENT'
}
def owner_identity_decision [observed: record, owner: record] {
    if $observed.generation != $owner.generation { return 'HOLD' }
    if $observed.state in ['Z' 'X' 'x'] { return 'WAIT_ABSENT' }
    if $observed.exe != $owner.exe or $observed.argv != $owner.argv { return 'HOLD' }
    'WAIT_ABSENT'
}
def global_firecracker_clear [] {
    let processes = (^pgrep -x firecracker | complete)
    require ($processes.exit_code == 1) 'Firecracker remains or process enumeration failed; refuse TAP reuse'
}
def validate_owner_record [owner: record, intent: record] {
    require ($owner.pid =~ '^[0-9]+$') 'owner PID is malformed'
    require (($owner.generation | str length) > 0) 'owner generation is absent'
    require ($owner.config == $intent.config) 'owner config differs from intent'
    require ($owner.exe == $intent.argv.0 and $owner.argv == $intent.argv) 'spawn-time owner executable/argv differs from intent'
}
def no_matching_config [config: string] {
    let matches = (matching_config_pids [$config])
    require (($matches | length) == 0) 'a Firecracker still uses the attempted config; refuse resolved cleanup'
    $matches
}
def wait_absent [pid: string, owner: record] {
    let proc = $"/proc/($pid)"
    for _ in 1..20 {
        if not ($proc | path exists) { return true }
        let observed = (proc_snapshot $pid)
        require ((owner_identity_decision $observed $owner) == 'WAIT_ABSENT') 'owner identity changed while waiting for exit'
        sleep 200ms
    }
    not ($proc | path exists)
}
def prior_firecracker_decision [pgrep_exit_code: int] {
    # No spawn-time generation exists for the ordinary gate's PID. This
    # diagnostic never signals any process, including its own Firecracker.
    if $pgrep_exit_code == 1 { 'CLEAR' } else { 'HOLD' }
}
def stop_current [work: string] {
    let dir = (result_dir $work)
    let current = ($dir | path join 'current-tag')
    if not ($current | path exists) {
        mut configs = []
        mut matching = []
        for intent_path in (glob ($dir | path join '*-intent.json')) {
            let intent = (open $intent_path)
            $configs = ($configs | append $intent.config)
            $matching = ($matching | append (matching_config_pids [$intent.config]))
        }
        let configs = ($configs | sort)
        let matches = ($matching | flatten | uniq | sort)
        if ($matches | length) > 0 {
            let receipt = {tag: '', pid: '', forced: false, state: 'hold-unreported-owner', scanned_configs: $configs, matching_config_pids: $matches}
            $receipt | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
            error make {msg: 'unreported Firecracker still uses one of the tagged configs; refuse unverified signal'}
        }
        global_firecracker_clear
        return {tag: '', pid: '', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []}
    }
    let tag = (open --raw $current | str trim)
    require ($tag =~ '^(release-[1-6]-(off|on)|panic-control)$') 'current tag is malformed'
    let intent_path = ($dir | path join $"($tag)-intent.json")
    require ($intent_path | path exists) 'attempted boot lacks intent; hold'
    let intent = (open $intent_path)
    let owner_path = ($dir | path join $"($tag)-owner.json")
    if not ($owner_path | path exists) {
        let matches = (matching_config_pids [$intent.config])
        let receipt = {tag: $tag, pid: '', forced: false, state: 'hold-no-owner', matching_config_pids: $matches}
        $receipt | to json --raw | save --raw --force ($dir | path join $"($tag)-cleanup.json")
        error make {msg: $"attempted spawn has no owner record; matching config PIDs: ($matches); refuse unverified kill"}
    }
    let owner = (open $owner_path)
    validate_owner_record $owner $intent
    let pid = $owner.pid
    let proc = $"/proc/($pid)"
    if not ($proc | path exists) {
        try {
            let matches = (no_matching_config $intent.config)
            global_firecracker_clear
            let receipt = {tag: $tag, pid: $pid, forced: false, state: 'already-exited', generation: $owner.generation, scanned_config: $intent.config, matching_config_pids: $matches}
            $receipt | to json --raw | save --raw --force ($dir | path join $"($tag)-cleanup.json")
            rm $current
            return $receipt
        } catch {|err|
            let receipt = {tag: $tag, pid: $pid, forced: false, state: 'hold-unresolved', generation: $owner.generation, reason: $err.msg}
            $receipt | to json --raw | save --raw --force ($dir | path join $"($tag)-cleanup.json")
            error make {msg: $err.msg}
        }
    }
    try {
        let first = (proc_snapshot $pid)
        require ((owner_decision ($first.generation == $owner.generation) $first.state true) == 'WAIT_ABSENT') 'owner PID generation or state changed; refuse reconciliation'
        require ((owner_identity_decision $first $owner) == 'WAIT_ABSENT') 'owner executable or argv changed; refuse reconciliation'
        let observation_path = ($dir | path join $"($tag)-owner-observation.json")
        $first | to json --raw | save --raw --force $observation_path
        require (wait_absent $pid $owner) 'owner did not exit naturally within bounded wait'
        let matches = (no_matching_config $intent.config)
        global_firecracker_clear
        let receipt = {tag: $tag, pid: $pid, forced: false, state: 'naturally-exited', generation: $owner.generation, observation_path: $observation_path, observation_sha256: (digest $observation_path), scanned_config: $intent.config, matching_config_pids: $matches}
        $receipt | to json --raw | save --raw --force ($dir | path join $"($tag)-cleanup.json")
        rm $current
        return $receipt
    } catch {|err|
        let receipt = {tag: $tag, pid: $pid, forced: false, state: 'hold-unresolved', generation: $owner.generation, reason: $err.msg}
        $receipt | to json --raw | save --raw --force ($dir | path join $"($tag)-cleanup.json")
        error make {msg: $err.msg}
    }
}

def expect_program [] {
    '
set timeout 30
set rc 0
set t0 [clock milliseconds]
spawn $env(FC_AB_BINARY) --no-api --config-file $env(FC_AB_CONFIG)
set child [exp_pid]
if {[catch {
  set f [open "/proc/$child/stat" r]
  set stat [read $f]
  close $f
  regexp {^.*\) (.*)$} $stat whole tail
  set fields [split $tail " "]
  set generation [lindex $fields 19]
  if {$generation eq ""} {error "no generation"}
  set out [open $env(FC_AB_OWNER) w]
  puts $out "{\"pid\":\"$child\",\"generation\":\"$generation\",\"config\":\"$env(FC_AB_CONFIG)\",\"exe\":\"$env(FC_AB_BINARY)\",\"argv\":\[\"$env(FC_AB_BINARY)\",\"--no-api\",\"--config-file\",\"$env(FC_AB_CONFIG)\"\]}"
  close $out
} why]} {
  catch {close}
  puts "OWNER_RECORD=fail $why"
  exit 9
}
expect {
  -re "SMOLFIRE_NET_OK $env(FC_AB_NONCE)(\\r*\\n)" { puts "NET_GATE=pass" }
  "SMOLFIRE_NET_FAIL" { puts "NET_GATE=fail"; set rc 3 }
  -re {panic:} { puts "VERDICT=fail panic before network"; set rc 2 }
  timeout { puts "VERDICT=fail no network nonce"; set rc 3 }
  eof { puts "VERDICT=fail early VM exit"; set rc 2 }
}
if {$rc == 0} {
  expect {
    "SMOLFIRE_READY" { puts "TIME_TO_READY=[expr {[clock milliseconds]-$t0}]ms" }
    -re {panic:} { puts "VERDICT=fail panic before READY"; set rc 2 }
    timeout { puts "VERDICT=fail no READY"; set rc 1 }
    eof { puts "VERDICT=fail exit before READY"; set rc 2 }
  }
}
if {$rc == 0 && $env(FC_AB_MODE) != "panic"} {
  send -- {echo FIRE_$((6*7))}
  send -- "\r"
  expect {
    -re {(^|[\r\n])FIRE_42([\r\n]|$)} { puts "SHELL_GATE=pass" }
    timeout { puts "SHELL_GATE=fail"; set rc 5 }
    eof { puts "SHELL_GATE=fail early exit"; set rc 5 }
  }
  if {$rc == 0} {
    if {[catch {exec ping -c 2 -W 2 172.16.0.2} ping_out]} {
      puts "HOST_PING=fail $ping_out"; set rc 6
    } else { puts "HOST_PING=pass" }
  }
}
if {$rc == 0 && $env(FC_AB_MODE) == "panic"} {
  send -- "sysctl debug.kdb.panic=1\r"
  expect {
    -re {(^|[\r\n]|debug[.]kdb[.]panic: *[0-9]*)panic: kdb_sysctl_panic([\r\n]|$)} { puts "PANIC_CONTROL=pass" }
    timeout { puts "PANIC_CONTROL=fail"; set rc 8 }
    eof { puts "PANIC_CONTROL=fail early exit"; set rc 8 }
  }
}
puts "VERDICT_RC=$rc"
exit $rc
'
}

def one_boot [work: string, tag: string, variant: string, mode: string, release: string, release_sha: string, binary_sha: string] {
    let dir = (result_dir $work)
    require ((digest $release) == $release_sha and (digest ($work | path join 'firecracker')) == $binary_sha) 'pinned ELF or VMM bytes changed before boot'
    let nonce = $"fc-ab-(random uuid)"
    let token = ($work | path join 'www' 'token.txt')
    $nonce | save --raw --force $token
    let fetch = (^curl -fsS --max-time 3 'http://172.16.0.1:8080/token.txt' | complete)
    require ($fetch.exit_code == 0 and $fetch.stdout == $nonce) 'host token server did not return fresh nonce'
    let config_path = ($dir | path join $"($tag)-config.json")
    let config = {
        'boot-source': {kernel_image_path: $release, boot_args: (boot_args $variant)}
        drives: []
        'network-interfaces': [{iface_id: 'eth0', guest_mac: '06:00:AC:10:00:02', host_dev_name: 'tap0'}]
        'machine-config': {vcpu_count: 1, mem_size_mib: 512}
    }
    $config | to json --indent 2 | save --raw $config_path
    let intent = {tag: $tag, variant: $variant, nonce: $nonce, config: $config_path, config_sha256: (digest $config_path), argv: (argv $work $config_path)}
    $intent | to json --indent 2 | save --raw ($dir | path join $"($tag)-intent.json")
    $tag | save --raw ($dir | path join 'current-tag')
    let log = ($dir | path join $"($tag).raw")
    let owner = ($dir | path join $"($tag)-owner.json")
    let run = (with-env {FC_AB_BINARY: ($work | path join 'firecracker'), FC_AB_CONFIG: $config_path, FC_AB_OWNER: $owner, FC_AB_NONCE: $nonce, FC_AB_MODE: $mode} {
        ^expect -c (expect_program) | complete
    })
    $run.stdout | save --raw $log
    $run.stderr | save --raw ($dir | path join $"($tag).stderr")
    let cleanup = (stop_current $work)
    require ((digest $release) == $release_sha and (digest ($work | path join 'firecracker')) == $binary_sha) 'pinned ELF or VMM bytes changed during boot'
    require (not $cleanup.forced) $"($tag) cleanup was forced; stop experiment"
    require ($run.exit_code == 0) $"($tag) Expect failed rc=($run.exit_code); raw retained"
    let raw = (open --raw $log)
    require ($raw | str contains $"SMOLFIRE_NET_OK ($nonce)") $"($tag) raw nonce missing"
    require ($raw | str contains 'SMOLFIRE_READY') $"($tag) READY missing"
    if $mode == 'panic' {
        require (($raw | str contains 'PANIC_CONTROL=pass') and (panic_kernel_seen $raw)) 'muted same-ELF kernel panic output absent'
    } else {
        require (($raw | str contains 'SHELL_GATE=pass') and ($raw | str contains 'HOST_PING=pass') and not ($raw | str contains 'panic:')) $"($tag) functional/panic gate failed"
    }
    {tag: $tag, variant: $variant, nonce: $nonce, release_elf_sha256: $release_sha, firecracker_sha256: $binary_sha, config_path: $config_path, config_sha256: (digest $config_path), intent_path: ($dir | path join $"($tag)-intent.json"), intent_sha256: (digest ($dir | path join $"($tag)-intent.json")), owner_path: $owner, owner_sha256: (digest $owner), raw_path: $log, raw_sha256: (digest $log), stderr_path: ($dir | path join $"($tag).stderr"), cleanup_path: ($dir | path join $"($tag)-cleanup.json"), cleanup_sha256: (digest ($dir | path join $"($tag)-cleanup.json")), argv: (argv $work $config_path), time_to_ready_ms: (if $mode == 'panic' { null } else { let rows = ($raw | parse -r 'TIME_TO_READY=(?<ms>[0-9]+)ms'); require (($rows | length) == 1) 'ambiguous READY time'; $rows.0.ms | into int })}
}

def main [--execute, --cleanup-only, --work: string = '/mnt/smolfire-ci', --audit: string = 'tests/firecracker-boot-mute-audit.nu'] {
    if $cleanup_only {
        require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'cleanup requires hosted Linux'
        let outcome = (try { {ok: true, value: (stop_current $work)} } catch {|err| {ok: false, value: {tag: '', pid: '', forced: false, state: 'hold-unresolved', reason: $err.msg}} })
        print ($outcome.value | to json --raw)
        if not $outcome.ok { error make {msg: $outcome.value.reason} }
        require (not $outcome.value.forced) 'forced cleanup is a failed diagnostic'
        return
    }
    if not $execute { print 'SOURCE ONLY: no Firecracker launched'; return }
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'hosted Linux required'
    require (($env.GITHUB_REF? | default '') | str starts-with 'refs/heads/exp/boot-mute-') 'isolated branch required'
    require (($env.GITHUB_SHA? | default '' | str length) == 40) 'source SHA missing'
    require ((^git rev-parse HEAD | str trim) == $env.GITHUB_SHA) 'checked-out head differs from GITHUB_SHA'
    require ('/dev/kvm' | path exists) 'hosted KVM missing'
    let release = ($work | path join 'smolfire-kernel')
    let binary = ($work | path join 'firecracker')
    require (($release | path exists) and ($binary | path exists) and ($audit | path exists)) 'pinned ELF, Firecracker or auditor absent'
    let release_sha = (digest $release)
    let binary_sha = (digest $binary)
    let elf_type = (^file -b $release | complete)
    require ($elf_type.exit_code == 0 and ($elf_type.stdout | str contains 'ELF 64-bit')) 'release is not 64-bit ELF'
    let elf_strings = (^strings $release | complete)
    require ($elf_strings.exit_code == 0 and not ($elf_strings.stdout | str contains 'SMOLFIRE_TSLOG_BEGIN')) 'release ELF is instrumented'
    let fc_version = (^$binary --version | complete)
    require ($fc_version.exit_code == 0) 'Firecracker version command failed'
    let stable_version = (stable_firecracker_version $fc_version.stdout)
    require ($stable_version == 'Firecracker v1.12.0') 'Firecracker version mismatch'
    let tap = (^ip -4 addr show dev tap0 | complete)
    require ($tap.exit_code == 0 and ($tap.stdout | str contains '172.16.0.1/30')) 'TAP config mismatch'
    require (($work | path join 'www' 'token.txt' | path exists)) 'token server file absent'
    let dir = (result_dir $work)
    require (not ($dir | path exists)) 'result directory exists; preserve and use fresh runner'
    mkdir $dir
    let processes = (^pgrep -x firecracker | complete)
    # The earlier ordinary gate does not record a spawn-time PID generation.
    # Its live process cannot be safely signaled by this experiment; HOLD.
    require ((prior_firecracker_decision $processes.exit_code) == 'CLEAR') 'prior or foreign Firecracker remains live; no diagnostic boot or signal'
    let plans = [{pair: 1, variants: ['off' 'on']} {pair: 2, variants: ['on' 'off']} {pair: 3, variants: ['off' 'on']}]
    mut samples = []
    for p in $plans {
        for variant in $p.variants {
            let i = (($samples | length) + 1)
            let boot = (one_boot $work $"release-($i)-($variant)" $variant 'release' $release $release_sha $binary_sha)
            $samples = ($samples | append ($boot | merge {pair: $p.pair, order_index: $i}))
        }
    }
    let panic = (one_boot $work 'panic-control' 'on' 'panic' $release $release_sha $binary_sha)
    let host_cpu = (open --raw /proc/cpuinfo | lines | where {|x| $x | str starts-with 'model name'} | first)
    let report_path = ($dir | path join 'report.json')
    require ((digest $release) == $release_sha and (digest $binary) == $binary_sha) 'pinned ELF or VMM bytes changed before report'
    {kind: 'firecracker-boot-mute-pairs-v1', source_commit: $env.GITHUB_SHA, host_class: 'github-hosted-linux-kvm', host_cpu: $host_cpu, firecracker_version: $fc_version.stdout, firecracker_path: $binary, firecracker_sha256: $binary_sha, release_elf_path: $release, release_elf_sha256: $release_sha, base_config_path: ($work | path join 'fc.json'), base_config_sha256: (digest ($work | path join 'fc.json')), samples: $samples, panic_control: $panic} | to json --indent 2 | save --raw $report_path
    let audit_result = (^nu $audit $report_path | complete)
    $audit_result.stdout | save --raw ($dir | path join 'audit.json')
    $audit_result.stderr | save --raw ($dir | path join 'audit.stderr')
    require ($audit_result.exit_code == 0) 'Firecracker pair audit failed; raw retained'
    print $audit_result.stdout
}
