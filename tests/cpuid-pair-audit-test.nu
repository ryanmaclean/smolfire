#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Synthetic fixture only; no VM or host action.

def digest [p: string] { open --raw $p | hash sha256 }

def main [] {
    let dir = (^mktemp -d | str trim)
    let audit = ($env.CURRENT_FILE | path dirname | path join 'cpuid-pair-audit.nu')
    let release = ($dir | path join 'release.elf')
    let tslog = ($dir | path join 'tslog.elf')
    let trace = ($dir | path join 'tslog.raw')
    let panic = ($dir | path join 'panic.raw')
    'synthetic release ELF' | save --raw $release
    'synthetic diagnostic ELF' | save --raw $tslog
    'synthetic clockcalib phase' | save --raw $trace
    'SMOLFIRE_NET_OK panic-nonce
SMOLFIRE_READY
panic: synthetic visible control' | save --raw $panic
    mut samples = []
    for pair in 1..3 {
        let variants = (if $pair == 2 { ['on' 'off'] } else { ['off' 'on'] })
        for variant in $variants {
            let i = (($samples | length) + 1)
            let max = (if $variant == 'on' { 1073741840 } else { 1073741825 })
            let eax = (if $variant == 'on' { 2500000 } else { 0 })
            let ebx = (if $variant == 'on' { 100000 } else { 0 })
            let serial = ($dir | path join $"serial-($i).raw")
            let cpuid_path = ($dir | path join $"cpuid-($i).raw")
            let time_ms = (if $variant == 'on' { 90 } else { 220 })
            $"SMOLFIRE_NET_OK nonce-($i)\nSMOLFIRE_READY\nTIME_TO_READY=($time_ms)ms\nSHELL_GATE=pass\nHOST_PING=pass\n" | save --raw $serial
            $"SMOLFIRE_NET_OK cpuid-nonce-($i)\nSMOLFIRE_READY\nSMOLFIRE_TSLOG_DONE\nSHELL_GATE=pass\nHOST_PING=pass\nCPUID_40000010 max=($max) eax=($eax) ebx=($ebx) ecx=0 edx=0\n" | save --raw $cpuid_path
            let release_argv = ['qemu-system-x86_64' '-M' 'microvm' '-accel' 'kvm' '-cpu' $"host,+invtsc,vmware-cpuid-freq=($variant)" '-m' '512M' '-kernel' $release '-append' 'smolfire.fetch=http://172.16.0.1:8080/token.txt']
            let probe_argv = ['qemu-system-x86_64' '-M' 'microvm' '-accel' 'kvm' '-cpu' $"host,+invtsc,vmware-cpuid-freq=($variant)" '-m' '512M' '-kernel' $tslog '-append' 'smolfire.fetch=http://172.16.0.1:8080/token.txt']
            $samples = ($samples | append {
                pair: $pair, order_index: $i, variant: $variant,
                elf_sha256: (digest $release), time_to_ready_ms: $time_ms,
                net_ok: true, host_ping_ok: true, shell_ok: true, panic_seen: false,
                nonce: $"nonce-($i)", net_nonce_seen: $"nonce-($i)",
                serial_path: $serial, serial_sha256: (digest $serial),
                cpuid_path: $cpuid_path, cpuid_sha256: (digest $cpuid_path), cpuid_probe_nonce: $"cpuid-nonce-($i)",
                cpuid_probe_elf_sha256: (digest $tslog), cpuid_probe_argv: $probe_argv,
                cpuid: {max_leaf: $max, eax_khz: $eax, ebx_khz: $ebx, ecx: 0, edx: 0},
                argv: $release_argv
            })
        }
    }
    let report = ($dir | path join 'report.json')
    {
        kind: 'qemu-cpuid-frequency-paired-control-v1', host_class: 'off-nas-kvm',
        source_commit: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        qemu_version: 'synthetic QEMU', host_cpu: 'synthetic CPU',
        release_elf_path: $release, release_elf_sha256: (digest $release),
        tslog_elf_path: $tslog, tslog_elf_sha256: (digest $tslog),
        tslog_clockcalib_trace_path: $trace, tslog_clockcalib_trace_sha256: (digest $trace),
        panic_control_serial_path: $panic, panic_control_sha256: (digest $panic), panic_control_seen: true,
        panic_control_elf_sha256: (digest $release), panic_control_nonce: 'panic-nonce',
        panic_control_argv: ($samples | where variant == 'off' | first | get argv),
        samples: $samples
    } | to json | save --raw $report
    let valid = (^nu $audit $report | complete)
    if $valid.exit_code != 0 { error make {msg: $"valid synthetic fixture failed: ($valid.stderr)"} }
    let parsed = ($valid.stdout | from json)
    if $parsed.firecracker_goal != 'UNPROVEN' or not $parsed.candidate_all_within_100ms {
        error make {msg: 'synthetic verdict is wrong'}
    }
    let bad = ($dir | path join 'bad.json')
    (open $report | update samples.0.net_nonce_seen 'wrong' | to json) | save --raw $bad
    let rejected = (^nu $audit $bad | complete)
    if $rejected.exit_code == 0 { error make {msg: 'mismatched network nonce was accepted'} }
    let wrong_cpu = ($dir | path join 'wrong-cpu.json')
    let wrong_argv = (open $report | get samples.0.cpuid_probe_argv | each {|a| $a | str replace 'vmware-cpuid-freq=off' 'vmware-cpuid-freq=on'})
    (open $report | update samples.0.cpuid_probe_argv $wrong_argv | to json) | save --raw $wrong_cpu
    let cpu_rejected = (^nu $audit $wrong_cpu | complete)
    if $cpu_rejected.exit_code == 0 { error make {msg: 'wrong diagnostic CPU flag was accepted'} }
    print 'synthetic validator PASS: valid 3-pair receipt accepted, nonce and diagnostic-CPU faults rejected, Firecracker goal unproven'
}
