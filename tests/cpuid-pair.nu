#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Branch-only QEMU mechanism control. Copy to tests/cpuid-pair.nu only after peer review.
# Default invocation is source-only; --execute is for an admitted GitHub KVM job.

def require [ok: bool, why: string] {
    if not $ok { error make {msg: $why} }
}
def fail [why: string] { error make {msg: $why} }

def require_external_success [result: record, context: string] {
    # Nu 0.115.1 can silently end a script with rc=0 while interpolating an
    # empty external stderr into an eagerly evaluated success-path message.
    if $result.exit_code != 0 {
        let detail = ($result.stderr | str trim)
        let shown = (if $detail == '' { 'empty stderr' } else { $detail })
        fail $"($context): exit ($result.exit_code): ($shown)"
    }
}

def digest [p: string] { open --raw $p | hash sha256 }

def qemu_argv [work: string, kernel: string, variant: string] {
    [
        'qemu-system-x86_64' '-M' 'microvm' '-accel' 'kvm'
        '-cpu' $"host,+invtsc,vmware-cpuid-freq=($variant)"
        '-m' '512M' '-kernel' $kernel
        '-append' 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt'
        '-netdev' 'tap,id=n0,ifname=tap0,script=no,downscript=no'
        '-device' 'virtio-net-device,netdev=n0'
        '-display' 'none' '-serial' 'mon:stdio'
        '-pidfile' ($work | path join 'cpuid-control' 'current-qemu.pid')
    ]
}

def prior_qemu_argv [release: string] {
    [
        'qemu-system-x86_64' '-M' 'microvm' '-accel' 'kvm' '-cpu' 'host' '-m' '512M'
        '-kernel' $release
        '-append' 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.fetch=http://10.0.2.2:8080/token.txt'
        '-netdev' 'user,id=n0' '-device' 'virtio-net-device,netdev=n0'
        '-display' 'none' '-serial' 'mon:stdio'
    ]
}

def arg_after [argv: list<string>, flag: string] {
    let hits = ($argv | enumerate | where {|row| $row.item == $flag})
    require (($hits | length) == 1) $"QEMU argv missing or duplicating ($flag)"
    let next = (($hits | first | get index) + 1)
    require ($next < ($argv | length)) $"QEMU argv has no value for ($flag)"
    $argv | get $next
}

def proc_generation [pid_text: string] {
    let stat_path = $"/proc/($pid_text)/stat"
    require ($stat_path | path exists) 'owned QEMU process disappeared during identity check'
    let fields = (open --raw $stat_path | split row ') ' | last | split row --regex '\s+' | where $it != '')
    require (($fields | length) > 19) 'owned QEMU process stat is malformed'
    $fields | get 19
}

def matches_qemu_argv [normalized: list<string>, kind: string, pidfile: string, release: string, tslog: string] {
    if $kind == 'control' {
        let work = ($pidfile | path dirname | path dirname)
        let exact = (['off' 'on'] | each {|variant|
            [$release $tslog] | each {|kernel| qemu_argv $work $kernel $variant}
        } | flatten)
        $normalized in $exact
    } else if $kind == 'prior' {
        $normalized == (prior_qemu_argv $release)
    } else {
        false
    }
}

def verify_qemu [pid_text: string, kind: string, pidfile: string, release: string, tslog: string] {
    let cmd_path = $"/proc/($pid_text)/cmdline"
    require ($cmd_path | path exists) 'owned QEMU process disappeared during argv check'
    let argv = (open --raw $cmd_path | decode utf-8 | split row (char nul) | where $it != '')
    require (($argv | length) >= 8) 'owned QEMU argv is incomplete'
    require (($argv | first | path basename) == 'qemu-system-x86_64') 'PID points at a foreign executable'
    let normalized = ($argv | update 0 'qemu-system-x86_64')
    require (matches_qemu_argv $normalized $kind $pidfile $release $tslog) 'PID does not match an exact owned QEMU command'
    proc_generation $pid_text
}

def cleanup_decision [same_generation: bool, exact_argv: bool, term_wait_elapsed: bool] {
    if not $same_generation or not $exact_argv { return 'REFUSE' }
    if $term_wait_elapsed { 'KILL' } else { 'WAIT' }
}

def stop_exact_qemu [pid_text: string, kind: string, pidfile: string, release: string, tslog: string] {
    let proc_path = $"/proc/($pid_text)"
    if not ($proc_path | path exists) { return {pid: $pid_text, forced: false, state: 'already-exited'} }
    let generation = (verify_qemu $pid_text $kind $pidfile $release $tslog)
    let term = (^kill -TERM $pid_text | complete)
    require ($term.exit_code == 0) 'TERM failed for exact owned QEMU'
    for _ in 1..20 {
        if not ($proc_path | path exists) { return {pid: $pid_text, forced: false, state: 'term-exited'} }
        require ((proc_generation $pid_text) == $generation) 'QEMU PID generation changed after TERM; no signal to replacement'
        sleep 200ms
    }
    let current = (verify_qemu $pid_text $kind $pidfile $release $tslog)
    require ((cleanup_decision ($current == $generation) true true) == 'KILL') 'QEMU identity changed before KILL; no forced signal'
    let killed = (^kill -KILL $pid_text | complete)
    require ($killed.exit_code == 0) 'KILL failed for exact stubborn QEMU'
    for _ in 1..25 {
        if not ($proc_path | path exists) { return {pid: $pid_text, forced: true, state: 'kill-exited'} }
        require ((proc_generation $pid_text) == $generation) 'QEMU PID generation changed after KILL'
        sleep 200ms
    }
    fail 'Exact owned QEMU remains in /proc after bounded KILL/reap wait'
}

def stop_owned_qemu [pidfile: string, release: string, tslog: string] {
    if not ($pidfile | path exists) { return {pid: '', forced: false, state: 'no-pidfile'} }
    let pid_text = (open --raw $pidfile | str trim)
    require ($pid_text =~ '^[0-9]+$') 'QEMU pidfile is malformed'
    let result = (stop_exact_qemu $pid_text 'control' $pidfile $release $tslog)
    rm $pidfile
    $result
}

def stop_prior_gate_qemu [work: string, release: string, tslog: string] {
    # The earlier stock QEMU gate records its child PID without -pidfile.
    let saved = ($work | path join 'qemu-microvm.pid')
    if not ($saved | path exists) { return {pid: '', forced: false, state: 'no-prior-pidfile'} }
    let pid_text = (open --raw $saved | str trim)
    require ($pid_text =~ '^[0-9]+$') 'prior QEMU PID evidence malformed'
    stop_exact_qemu $pid_text 'prior' $saved $release $tslog
}

def qmp_accepts [variant: string] {
    let request = "{\"execute\":\"qmp_capabilities\"}\n{\"execute\":\"quit\"}\n"
    # Use the same machine class as the guest boots. -M none with a KVM host
    # CPU failed before option validation (apic-id was not initialized).
    let result = ($request | ^timeout 10s qemu-system-x86_64 -M microvm -accel kvm -cpu $"host,+invtsc,vmware-cpuid-freq=($variant)" -S -nodefaults -display none -monitor none -serial none -qmp stdio | complete)
    require_external_success $result $"QEMU rejected vmware-cpuid-freq=($variant)"
}

def expect_program [] {
    # A single spawned QEMU is owned by Expect and given a unique pidfile.
    # GNU timeout bounds an unexpected Expect hang; Nu then reconciles that pidfile.
    '
set timeout 45
set t0 [clock milliseconds]
set rc 0
spawn qemu-system-x86_64 -M microvm -accel kvm -cpu $env(CPUID_CPU) -m 512M \
  -kernel $env(CPUID_KERNEL) -append $env(CPUID_BOOT_ARGS) \
  -netdev tap,id=n0,ifname=tap0,script=no,downscript=no \
  -device virtio-net-device,netdev=n0 -display none -serial mon:stdio \
  -pidfile $env(CPUID_PIDFILE)
set vm_pid [exp_pid]
expect {
  -re "SMOLFIRE_NET_OK $env(CPUID_NONCE)" { puts "NET_GATE=pass" }
  "SMOLFIRE_NET_FAIL" { puts "NET_GATE=fail"; set rc 3 }
  -re {panic:} { puts "VERDICT=fail panic before READY"; set rc 2 }
  timeout { puts "VERDICT=fail no network nonce"; set rc 3 }
  eof { puts "VERDICT=fail early QEMU exit"; set rc 2 }
}
if {$rc == 0} {
  expect {
    "SMOLFIRE_READY" { puts "TIME_TO_READY=[expr {[clock milliseconds]-$t0}]ms" }
    -re {panic:} { puts "VERDICT=fail panic before READY"; set rc 2 }
    timeout { puts "VERDICT=fail no READY"; set rc 1 }
    eof { puts "VERDICT=fail QEMU exit before READY"; set rc 2 }
  }
}
if {$rc == 0 && $env(CPUID_MODE) == "probe"} {
  set timeout 300
  expect {
    "SMOLFIRE_TSLOG_DONE" { puts "TSLOG_CAPTURE=pass" }
    timeout { puts "VERDICT=fail no TSLOG dump"; set rc 4 }
    eof { puts "VERDICT=fail QEMU exit during TSLOG"; set rc 4 }
  }
}
if {$rc == 0 && $env(CPUID_MODE) != "panic"} {
  set timeout 30
  send -- {echo FIRE_$((6*7))}
  send -- "\r"
  expect {
    "FIRE_42" { puts "SHELL_GATE=pass" }
    timeout { puts "SHELL_GATE=fail"; set rc 5 }
    eof { puts "SHELL_GATE=fail QEMU exit"; set rc 5 }
  }
  if {$rc == 0} {
    if {[catch {exec ping -c 2 -W 2 172.16.0.2} ping_out]} {
      puts "HOST_PING=fail $ping_out"; set rc 6
    } else { puts "HOST_PING=pass" }
  }
}
if {$rc == 0 && $env(CPUID_MODE) == "probe"} {
  send -- "/rescue/cpuid_40000010\r"
  expect {
    -re {CPUID_40000010 max=[0-9]+ eax=[0-9]+ ebx=[0-9]+ ecx=[0-9]+ edx=[0-9]+} { puts "CPUID_PROBE=pass" }
    timeout { puts "CPUID_PROBE=fail"; set rc 7 }
    eof { puts "CPUID_PROBE=fail QEMU exit"; set rc 7 }
  }
}
if {$rc == 0 && $env(CPUID_MODE) == "panic"} {
  send -- "sysctl debug.kdb.panic=1\r"
  expect {
    -re {panic:} { puts "PANIC_CONTROL=pass" }
    timeout { puts "PANIC_CONTROL=fail"; set rc 8 }
    eof { puts "PANIC_CONTROL=fail QEMU exit"; set rc 8 }
  }
}
catch {exec kill -TERM $vm_pid}
catch {close}
catch {wait}
puts "VERDICT_RC=$rc"
exit $rc
'
}

def boot [work: string, kernel: string, variant: string, mode: string, tag: string] {
    let result_dir = ($work | path join 'cpuid-control')
    let token_file = ($work | path join 'www' 'token.txt')
    let nonce = $"cpuid-(random uuid)"
    $nonce | save --raw --force $token_file
    let fetched = (^curl -fsS --max-time 3 'http://172.16.0.1:8080/token.txt' | complete)
    require ($fetched.exit_code == 0 and ($fetched.stdout | str trim) == $nonce) 'token server did not serve the fresh nonce'
    let pidfile = ($result_dir | path join 'current-qemu.pid')
    let release = ($work | path join 'smolfire-kernel')
    let tslog = ($work | path join 'smolfire-kernel-tslog')
    let pre = (stop_owned_qemu $pidfile $release $tslog)
    require (not $pre.forced) 'previous exact QEMU required KILL; no next boot'
    let log = ($result_dir | path join $"($tag).raw")
    let args = (qemu_argv $work $kernel $variant)
    let run = (with-env {
        CPUID_CPU: $"host,+invtsc,vmware-cpuid-freq=($variant)",
        CPUID_KERNEL: $kernel,
        CPUID_BOOT_ARGS: ($args | get 12),
        CPUID_PIDFILE: $pidfile,
        CPUID_NONCE: $nonce,
        CPUID_MODE: $mode
    } { ^timeout --signal=TERM --kill-after=5s 360s expect -c (expect_program) | complete })
    $run.stdout | save --raw --force $log
    let cleanup = (stop_owned_qemu $pidfile $release $tslog)
    $cleanup | to json --raw | save --raw --force ($result_dir | path join $"($tag)-cleanup.json")
    require (not $cleanup.forced) $"($tag) QEMU needed ownership-checked KILL; raw log retained"
    require_external_success $run $"($tag) VM gate failed; see ($log)"
    require ($run.stdout | str contains $"SMOLFIRE_NET_OK ($nonce)") $"($tag) raw network nonce missing"
    if $mode == 'panic' {
        require ($run.stdout | str contains 'PANIC_CONTROL=pass') $"($tag) raw panic control missing"
    } else {
        require (($run.stdout | str contains 'SHELL_GATE=pass') and ($run.stdout | str contains 'HOST_PING=pass')) $"($tag) raw shell/ping markers missing"
    }
    {nonce: $nonce, log: $log, sha256: (digest $log), argv: $args, stdout: $run.stdout}
}

def leaf [raw: string] {
    let rows = ($raw | parse -r 'CPUID_40000010 max=(?<max>[0-9]+) eax=(?<eax>[0-9]+) ebx=(?<ebx>[0-9]+) ecx=(?<ecx>[0-9]+) edx=(?<edx>[0-9]+)')
    require (($rows | length) == 1) 'guest CPUID leaf missing or ambiguous'
    let x = ($rows | first)
    {max_leaf: ($x.max | into int), eax_khz: ($x.eax | into int), ebx_khz: ($x.ebx | into int), ecx: ($x.ecx | into int), edx: ($x.edx | into int)}
}

def ready_time [raw: string] {
    let rows = ($raw | parse -r 'TIME_TO_READY=(?<ms>[0-9]+)ms')
    require (($rows | length) == 1) 'READY time missing or ambiguous'
    ($rows | first | get ms | into int)
}

def main [--execute, --cleanup-only, --work: string = '/mnt/smolfire-ci', --audit: string = 'tests/cpuid-pair-audit.nu'] {
    if $cleanup_only {
        require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'cleanup requires the hosted Linux job'
        let release = ($work | path join 'smolfire-kernel')
        let tslog = ($work | path join 'smolfire-kernel-tslog')
        let pidfile = ($work | path join 'cpuid-control' 'current-qemu.pid')
        let cleanup = (stop_owned_qemu $pidfile $release $tslog)
        print ($cleanup | to json --raw)
        require (not $cleanup.forced) 'workflow teardown required ownership-checked KILL; retain failed gate'
        return
    }
    if not $execute {
        print 'SOURCE-ONLY PLAN: GitHub-hosted KVM, one unchanged release ELF, separate TSLOG+CPUID ELF, 3 balanced A/B release pairs, guest leaf probes, panic control. No VM launched.'
        return
    }
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'execution requires an admitted GitHub-hosted Linux job'
    require (($env.GITHUB_REF? | default '') | str starts-with 'refs/heads/exp/cpuid-freq-') 'diagnostic branch ref is not isolated'
    require (($env.GITHUB_SHA? | default '' | str length) == 40) 'source commit is not pinned'
    let checked_out = (^git rev-parse HEAD | str trim)
    require ($checked_out == $env.GITHUB_SHA) 'checked-out source differs from hosted run SHA'
    require ('/dev/kvm' | path exists) 'KVM device missing'
    let release = ($work | path join 'smolfire-kernel')
    let tslog = ($work | path join 'smolfire-kernel-tslog')
    require (($release | path exists) and ($tslog | path exists) and ($audit | path exists)) 'one or more ELF/auditor inputs missing'
    require ((digest $release) != (digest $tslog)) 'release and diagnostic ELF must be distinct'
    let release_type = (^file -b $release | complete)
    let tslog_type = (^file -b $tslog | complete)
    require ($release_type.exit_code == 0 and ($release_type.stdout | str contains 'ELF 64-bit') and $tslog_type.exit_code == 0 and ($tslog_type.stdout | str contains 'ELF 64-bit')) 'one or both kernels are not x86-64 ELF artifacts'
    let release_strings = (^strings $release | complete)
    let tslog_strings = (^strings $tslog | complete)
    require ($release_strings.exit_code == 0 and $tslog_strings.exit_code == 0) 'ELF string inspection failed'
    require (not ($release_strings.stdout | str contains 'SMOLFIRE_TSLOG_BEGIN')) 'shipping release ELF contains TSLOG rc'
    require (($tslog_strings.stdout | str contains 'SMOLFIRE_TSLOG_BEGIN') and ($tslog_strings.stdout | str contains 'CPUID_40000010 max=')) 'diagnostic ELF lacks TSLOG or guest reporter'
    require (($work | path join 'www' 'token.txt' | path exists) and ('/sys/class/net/tap0' | path exists)) 'existing token server/TAP gate missing'
    let tap = (^ip -4 addr show dev tap0 | complete)
    require ($tap.exit_code == 0 and ($tap.stdout | str contains '172.16.0.1/30')) 'TAP host address differs from pinned boot args'
    let free_kib = (^df -Pk $work | lines | last | split row -r '\s+' | get 3 | into int)
    require ($free_kib >= 1048576) 'hosted runner has less than 1 GiB free for bounded logs'
    let result_dir = ($work | path join 'cpuid-control')
    require (not ($result_dir | path exists)) 'result directory already exists; preserve it and use a fresh runner'
    mkdir $result_dir
    for variant in ['off' 'on'] { qmp_accepts $variant }
    let prior_cleanup = (stop_prior_gate_qemu $work $release $tslog)
    $prior_cleanup | to json --raw | save --raw ($result_dir | path join 'prior-qemu-cleanup.json')
    require (not $prior_cleanup.forced) 'prior same-job QEMU required KILL; no diagnostic boot'
    let off_smoke = (boot $work $tslog 'off' 'probe' 'smoke-off')
    let on_smoke = (boot $work $tslog 'on' 'probe' 'smoke-on')
    let off_leaf = (leaf $off_smoke.stdout)
    let on_leaf = (leaf $on_smoke.stdout)
    require ($off_leaf.ebx_khz == 0 and $on_leaf.max_leaf >= 1073741840 and $on_leaf.eax_khz > 0 and $on_leaf.ebx_khz > 0) 'QEMU flag did not prove the intended raw guest CPUID difference; no timed pair started'
    let plans = [
        {pair: 1, variants: ['off' 'on']}
        {pair: 2, variants: ['on' 'off']}
        {pair: 3, variants: ['off' 'on']}
    ]
    mut samples = []
    for plan in $plans {
        for variant in $plan.variants {
            let order = (($samples | length) + 1)
            let run = (boot $work $release $variant 'release' $"release-($order)-($variant)")
            $samples = ($samples | append {
                pair: $plan.pair, order_index: $order, variant: $variant,
                elf_sha256: (digest $release), time_to_ready_ms: (ready_time $run.stdout),
                net_ok: true, host_ping_ok: true, shell_ok: true, panic_seen: false,
                nonce: $run.nonce, net_nonce_seen: $run.nonce,
                serial_path: $run.log, serial_sha256: $run.sha256, argv: $run.argv
            })
        }
    }
    mut paired = []
    for sample in $samples {
        let probe = (boot $work $tslog $sample.variant 'probe' $"probe-($sample.order_index)-($sample.variant)")
        $paired = ($paired | append ($sample | merge {
            cpuid_path: $probe.log, cpuid_sha256: $probe.sha256,
            cpuid_probe_nonce: $probe.nonce, cpuid_probe_elf_sha256: (digest $tslog),
            cpuid_probe_argv: $probe.argv, cpuid: (leaf $probe.stdout)
        }))
    }
    let panic = (boot $work $release 'off' 'panic' 'panic-control')
    require ($panic.stdout | str contains 'PANIC_CONTROL=pass') 'same-ELF panic visibility control failed'
    let cpu_rows = (open --raw /proc/cpuinfo | lines | where {|x| $x | str starts-with 'model name'})
    require (($cpu_rows | length) > 0) 'host CPU identity missing'
    let qemu_version = (^qemu-system-x86_64 --version | lines | first)
    let report = ($result_dir | path join 'report.json')
    {
        kind: 'qemu-cpuid-frequency-paired-control-v1', host_class: 'off-nas-kvm',
        source_commit: $env.GITHUB_SHA, qemu_version: $qemu_version, host_cpu: ($cpu_rows | first),
        release_elf_path: $release, release_elf_sha256: (digest $release),
        tslog_elf_path: $tslog, tslog_elf_sha256: (digest $tslog),
        tslog_clockcalib_trace_path: ($paired | first | get cpuid_path),
        tslog_clockcalib_trace_sha256: ($paired | first | get cpuid_sha256),
        panic_control_serial_path: $panic.log, panic_control_sha256: $panic.sha256, panic_control_seen: true,
        panic_control_elf_sha256: (digest $release), panic_control_argv: $panic.argv, panic_control_nonce: $panic.nonce,
        samples: $paired
    } | to json --indent 2 | save --raw $report
    let checked = (^nu $audit $report | complete)
    $checked.stdout | save --raw ($result_dir | path join 'audit.json')
    require_external_success $checked 'paired receipt audit failed'
    let verdict = ($checked.stdout | from json)
    print $checked.stdout
    require ($verdict.candidate_all_within_100ms) 'QEMU candidates missed the strict 100ms diagnostic threshold; Firecracker goal remains open'
    print 'QEMU mechanism diagnostic only; Firecracker ≤100ms release acceptance remains UNPROVEN.'
}
