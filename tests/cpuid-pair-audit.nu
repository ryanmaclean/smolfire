#!/usr/bin/env nu
# Non-release QEMU mechanism receipt checker. This never starts a VM.
# It deliberately cannot return a Firecracker acceptance verdict.
use cpuid-panic-evidence.nu panic_kernel_seen

def require [ok: bool, why: string] {
    if not $ok { error make { msg: $why } }
}

def file_sha [p: string] {
    require ($p | path exists) $"missing raw evidence: ($p)"
    open --raw $p | hash sha256
}

def normalized_argv [argv: list<string>] {
    $argv | each {|a|
        $a | str replace 'vmware-cpuid-freq=off' 'vmware-cpuid-freq=CONTROL'
           | str replace 'vmware-cpuid-freq=on' 'vmware-cpuid-freq=CONTROL'
    }
}

def check_sample [s: record, release_sha: string, tslog_sha: string, release_path: string, tslog_path: string] {
    require ($s.elf_sha256 == $release_sha) $"pair ($s.pair) uses a different release ELF"
    require ($s.cpuid_probe_elf_sha256 == $tslog_sha) $"pair ($s.pair) raw CPUID did not come from the pinned diagnostic ELF"
    require ($s.time_to_ready_ms > 0) $"pair ($s.pair) has no positive READY time"
    require ($s.net_ok and $s.host_ping_ok and $s.shell_ok) $"pair ($s.pair) failed a functional gate"
    require (not $s.panic_seen) $"pair ($s.pair) panicked"
    require ($s.nonce == $s.net_nonce_seen) $"pair ($s.pair) lacks its exact fresh network nonce"
    require ((file_sha $s.serial_path) == $s.serial_sha256) $"pair ($s.pair) serial digest mismatch"
    let serial = (open --raw $s.serial_path)
    require ($serial | str contains $"SMOLFIRE_NET_OK ($s.nonce)") $"pair ($s.pair) raw serial lacks nonce"
    require ($serial | str contains 'SMOLFIRE_READY') $"pair ($s.pair) raw serial lacks READY"
    require ($serial | str contains $"TIME_TO_READY=($s.time_to_ready_ms)ms") $"pair ($s.pair) raw serial lacks measured time"
    require ($serial | str contains 'SHELL_GATE=pass') $"pair ($s.pair) raw serial lacks shell pass"
    require ($serial | str contains 'HOST_PING=pass') $"pair ($s.pair) raw serial lacks host ping pass"
    require (not ($serial | str contains 'panic:')) $"pair ($s.pair) raw serial contains panic"
    require ((file_sha $s.cpuid_path) == $s.cpuid_sha256) $"pair ($s.pair) CPUID digest mismatch"
    let probe_serial = (open --raw $s.cpuid_path)
    require ($probe_serial | str contains $"SMOLFIRE_NET_OK ($s.cpuid_probe_nonce)") $"pair ($s.pair) diagnostic nonce absent"
    require ($probe_serial | str contains 'SMOLFIRE_READY') $"pair ($s.pair) diagnostic READY absent"
    require ($probe_serial | str contains 'SMOLFIRE_TSLOG_DONE') $"pair ($s.pair) diagnostic TSLOG dump incomplete"
    require ($probe_serial | str contains 'SHELL_GATE=pass') $"pair ($s.pair) diagnostic shell pass absent"
    require ($probe_serial | str contains 'HOST_PING=pass') $"pair ($s.pair) diagnostic ping pass absent"
    require (not ($probe_serial | str contains 'panic:')) $"pair ($s.pair) diagnostic panic"
    let cpu_arg = $"host,+invtsc,vmware-cpuid-freq=($s.variant)"
    require (($s.argv | where {|a| $a == $cpu_arg} | length) == 1) $"pair ($s.pair) lacks its exact CPU flag"
    require (($s.cpuid_probe_argv | where {|a| $a == $cpu_arg} | length) == 1) $"pair ($s.pair) diagnostic boot used a different CPU flag"
    require (($s.argv | where {|a| $a == '-cpu'} | length) == 1) $"pair ($s.pair) lacks one CPU selector"
    require (($s.argv | where {|a| $a == $release_path} | length) == 1) $"pair ($s.pair) release argv lacks pinned ELF"
    require (($s.cpuid_probe_argv | where {|a| $a == $tslog_path} | length) == 1) $"pair ($s.pair) probe argv lacks diagnostic ELF"
    let normalized_release = ($s.argv | each {|a| $a | str replace $release_path 'KERNEL'})
    let normalized_probe = ($s.cpuid_probe_argv | each {|a| $a | str replace $tslog_path 'KERNEL'})
    require ($normalized_release == $normalized_probe) $"pair ($s.pair) probe changed more than ELF"
    let raw_leaf = $"CPUID_40000010 max=($s.cpuid.max_leaf) eax=($s.cpuid.eax_khz) ebx=($s.cpuid.ebx_khz) ecx=($s.cpuid.ecx) edx=($s.cpuid.edx)"
    require ((open --raw $s.cpuid_path | str contains $raw_leaf) == true) $"pair ($s.pair) parsed CPUID does not match guest log"
    if $s.variant == 'on' {
        require ($s.cpuid.max_leaf >= 1073741840) $"pair ($s.pair) candidate lacks the CPUID range"
        require ($s.cpuid.eax_khz > 0 and $s.cpuid.ebx_khz > 0) $"pair ($s.pair) candidate CPUID frequency absent"
    } else {
        require ($s.cpuid.ebx_khz == 0) $"pair ($s.pair) baseline unexpectedly exposes APIC frequency"
    }
}

def main [report: path] {
    let r = (open $report)
    require ($r.kind == 'qemu-cpuid-frequency-paired-control-v1') 'wrong receipt kind'
    require ($r.host_class == 'off-nas-kvm') 'host was not an admitted off-NAS KVM host'
    require (($r.source_commit | str length) == 40) 'source commit is not pinned'
    require (($r.qemu_version | str length) > 0) 'QEMU version missing'
    require (($r.host_cpu | str length) > 0) 'host CPU missing'
    require ((file_sha $r.release_elf_path) == $r.release_elf_sha256) 'release ELF digest mismatch'
    require ((file_sha $r.tslog_elf_path) == $r.tslog_elf_sha256) 'TSLOG ELF digest mismatch'
    require ($r.release_elf_sha256 != $r.tslog_elf_sha256) 'diagnostic and release ELF are not distinct'
    require ($r.tslog_clockcalib_trace_sha256 == (file_sha $r.tslog_clockcalib_trace_path)) 'TSLOG raw trace mismatch'
    require ($r.panic_control_seen and $r.panic_control_sha256 == (file_sha $r.panic_control_serial_path)) 'panic visibility control missing'
    require ($r.panic_control_elf_sha256 == $r.release_elf_sha256) 'panic control used a different ELF'
    require (($r.panic_control_argv | where {|a| $a == $r.release_elf_path} | length) == 1) 'panic control argv lacks the release ELF'
    let panic_raw = (open --raw $r.panic_control_serial_path)
    require ((panic_kernel_seen $panic_raw) and ($panic_raw | str contains $"SMOLFIRE_NET_OK ($r.panic_control_nonce)")) 'panic control did not show kernel-origin panic line and raw nonce'
    require (($r.samples | length) >= 6) 'fewer than three A/B pairs'
    let ids = ($r.samples | get pair | uniq | sort)
    require (($ids | length) >= 3) 'fewer than three distinct pairs'
    require (($r.samples | get nonce | uniq | length) == ($r.samples | length)) 'network nonce reused'
    require (($r.samples | get cpuid_probe_nonce | uniq | length) == ($r.samples | length)) 'diagnostic network nonce reused'
    require (($r.samples | get nonce | append ($r.samples | get cpuid_probe_nonce) | uniq | length) == (($r.samples | length) * 2)) 'release/diagnostic nonce reused'
    require (($r.samples | get nonce | append ($r.samples | get cpuid_probe_nonce) | append $r.panic_control_nonce | uniq | length) == ((($r.samples | length) * 2) + 1)) 'panic control nonce reused'
    require (($r.samples | get serial_sha256 | uniq | length) == ($r.samples | length)) 'serial log reused'
    require (($r.samples | get cpuid_path | uniq | length) == ($r.samples | length)) 'CPUID log path reused'
    for pair in $ids {
        let samples = ($r.samples | where pair == $pair | sort-by order_index)
        require (($samples | length) == 2) $"pair ($pair) is not exactly A/B"
        require (($samples | get variant | sort) == ['off' 'on']) $"pair ($pair) variants wrong"
        require (($samples | get order_index | uniq | length) == 2) $"pair ($pair) order indices overlap"
        let a = ($samples | where variant == 'off' | first)
        let b = ($samples | where variant == 'on' | first)
        check_sample $a $r.release_elf_sha256 $r.tslog_elf_sha256 $r.release_elf_path $r.tslog_elf_path
        check_sample $b $r.release_elf_sha256 $r.tslog_elf_sha256 $r.release_elf_path $r.tslog_elf_path
        require ((normalized_argv $a.argv) == (normalized_argv $b.argv)) $"pair ($pair) changed more than the CPU flag"
        require ($a.cpuid.ebx_khz != $b.cpuid.ebx_khz) $"pair ($pair) did not change the guest APIC-frequency leaf"
    }
    let ordered = ($r.samples | sort-by order_index)
    require (($ordered | get order_index | uniq | length) == ($ordered | length)) 'global boot order duplicated'
    let baseline_argv = ($r.samples | where variant == 'off' | first | get argv)
    require ($r.panic_control_argv == $baseline_argv) 'panic control changed QEMU argv from release baseline'
    let pair_orders = ($ids | each {|pair| $r.samples | where pair == $pair | sort-by order_index | get variant | str join ','})
    require (($pair_orders | any {|x| $x == 'off,on'}) and ($pair_orders | any {|x| $x == 'on,off'})) 'paired orders are not balanced'
    let deltas = ($ids | each {|pair|
        let pair_samples = ($r.samples | where pair == $pair)
        let off = ($pair_samples | where variant == 'off' | first)
        let on = ($pair_samples | where variant == 'on' | first)
        {pair: $pair, off_ms: $off.time_to_ready_ms, on_ms: $on.time_to_ready_ms, saved_ms: ($off.time_to_ready_ms - $on.time_to_ready_ms)}
    })
    let candidate_strict = ($deltas | all {|x| $x.on_ms <= 100})
    {mechanism_control: 'PASS', candidate_all_within_100ms: $candidate_strict, firecracker_goal: 'UNPROVEN', paired_results: $deltas} | to json --indent 2
}
