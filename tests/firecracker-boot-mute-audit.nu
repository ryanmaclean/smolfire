#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Read-only, raw-derived audit. This stage can only emit PENDING_TEARDOWN.
use cpuid-panic-evidence.nu panic_kernel_seen

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def file_sha [path: string] {
    require ($path | path exists) $"missing evidence ($path)"
    open --raw $path | hash sha256
}
def assert_sha [path: string, expected: string] { require ((file_sha $path) == $expected) $"digest mismatch ($path)" }
def base_args [] { 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt' }
def expected_args [variant: string] { if $variant == 'on' { $"(base_args) boot_mute=YES" } else { base_args } }
def normalized_config [config: record] { $config | upsert 'boot-source' ($config.'boot-source' | upsert boot_args (base_args)) }
def actual_line [raw: string, wanted: string] {
    $raw | str replace --all "\r" "\n" | lines | any {|line| ($line | str trim) == $wanted}
}
def ordered [raw: string, a: string, b: string] {
    let first = ($raw | str index-of $a)
    let second = ($raw | str index-of $b)
    $first >= 0 and $second > $first
}
def check_boot [s: record, r: record, baseline: record, panic: bool] {
    let dir = ($s.config_path | path dirname)
    require (($s.tag | str contains '/') == false) 'tag contains a path separator'
    require ($s.config_path == ($dir | path join $"($s.tag)-config.json")) 'config path is not unique tagged path'
    require ($s.intent_path == ($dir | path join $"($s.tag)-intent.json")) 'intent path mismatch'
    require ($s.owner_path == ($dir | path join $"($s.tag)-owner.json")) 'owner path mismatch'
    require ($s.raw_path == ($dir | path join $"($s.tag).raw")) 'raw path mismatch'
    require ($s.cleanup_path == ($dir | path join $"($s.tag)-cleanup.json")) 'cleanup path mismatch'
    for entry in [[$s.config_path $s.config_sha256] [$s.intent_path $s.intent_sha256] [$s.owner_path $s.owner_sha256] [$s.raw_path $s.raw_sha256] [$s.cleanup_path $s.cleanup_sha256]] {
        assert_sha ($entry | get 0) ($entry | get 1)
    }
    require (($s.stderr_path | path exists) and ($s.stderr_path == ($dir | path join $"($s.tag).stderr"))) 'stderr path absent'
    let config = (open $s.config_path)
    require ($config.'boot-source'.kernel_image_path == $r.release_elf_path) 'boot kernel differs from pinned release ELF'
    require ($config.'boot-source'.boot_args == (expected_args $s.variant)) 'unexpected boot args'
    require ((normalized_config $config) == $baseline) 'config changed beyond boot_mute'
    let expected_argv = [$r.firecracker_path '--no-api' '--config-file' $s.config_path]
    require ($s.argv == $expected_argv) 'VMM argv changed'
    let intent = (open $s.intent_path)
    require ($intent.tag == $s.tag and $intent.variant == $s.variant and $intent.nonce == $s.nonce and $intent.config == $s.config_path and $intent.config_sha256 == $s.config_sha256 and $intent.argv == $expected_argv) 'intent differs from report'
    let owner = (open $s.owner_path)
    require (($owner.pid | into string) =~ '^[0-9]+$' and ($owner.generation | into string) =~ '^[0-9]+$' and $owner.config == $s.config_path) 'owner PID/generation/config invalid'
    let cleanup = (open $s.cleanup_path)
    require ($cleanup.tag == $s.tag and ($cleanup.pid | into string) == ($owner.pid | into string) and ($cleanup.generation | into string) == ($owner.generation | into string)) 'cleanup owner generation mismatch'
    require (not $cleanup.forced and ($cleanup.state in ['term-exited' 'already-exited'])) 'cleanup was forced, mismatched or unresolved'
    let raw = (open --raw $s.raw_path)
    require ($s.nonce =~ '^fc-ab-[0-9a-f-]+$') 'nonce format invalid'
    require (ordered $raw $"SMOLFIRE_NET_OK ($s.nonce)" 'SMOLFIRE_READY') 'network nonce absent or after READY'
    require ($raw | str contains 'NET_GATE=pass') 'network gate marker absent'
    require (not ($raw | str contains 'SMOLFIRE_NET_FAIL')) 'guest network failure present'
    if $panic {
        require ($s.variant == 'on' and $s.tag == 'panic-control') 'panic control must use muted release ELF'
        require (($raw | str contains 'PANIC_CONTROL=pass') and (panic_kernel_seen $raw)) 'kernel-origin panic line absent'
        require (ordered $raw 'SMOLFIRE_READY' 'panic: kdb_sysctl_panic') 'panic occurred before READY'
    } else {
        require (not ($raw | str contains 'panic:')) 'timed boot contains kernel panic'
        require ((actual_line $raw 'FIRE_42') and ($raw | str contains 'SHELL_GATE=pass') and ($raw | str contains 'HOST_PING=pass')) 'shell or host ping not proven'
        require (ordered $raw 'SMOLFIRE_READY' 'FIRE_42') 'shell output preceded READY'
        let rows = ($raw | parse -r 'TIME_TO_READY=(?<ms>[0-9]+)ms')
        require (($rows | length) == 1) 'READY time missing or ambiguous'
        let ms = ($rows.0.ms | into int)
        require ($ms > 0 and $ms == $s.time_to_ready_ms) 'raw READY time differs from report'
    }
}

def main [report: path] {
    let r = (open $report)
    require ($r.kind == 'firecracker-boot-mute-pairs-v1') 'wrong report kind'
    require ($r.host_class == 'github-hosted-linux-kvm') 'wrong host class'
    require ($r.source_commit =~ '^[0-9a-f]{40}$') 'source SHA absent'
    require (($r.host_cpu | str length) > 0) 'host CPU missing'
    require ($r.firecracker_version | str contains 'v1.12.0') 'unpinned Firecracker version'
    let work = ($r.base_config_path | path dirname)
    require ($r.firecracker_path == ($work | path join 'firecracker')) 'VMM path wrong'
    require ($r.release_elf_path == ($work | path join 'smolfire-kernel')) 'release ELF path wrong'
    require ($r.base_config_path == ($work | path join 'fc.json')) 'baseline config path wrong'
    require ($report == ($work | path join 'firecracker-boot-mute' 'report.json')) 'report outside fresh diagnostic directory'
    assert_sha $r.firecracker_path $r.firecracker_sha256
    assert_sha $r.release_elf_path $r.release_elf_sha256
    assert_sha $r.base_config_path $r.base_config_sha256
    let base = (open $r.base_config_path)
    let expected_base = {'boot-source': {kernel_image_path: $r.release_elf_path, boot_args: (base_args)}, drives: [], 'network-interfaces': [{iface_id: 'eth0', guest_mac: '06:00:AC:10:00:02', host_dev_name: 'tap0'}], 'machine-config': {vcpu_count: 1, mem_size_mib: 512}}
    require ($base == $expected_base) 'baseline config changed network, memory, vCPU or boot args'
    if (($env.GITHUB_ACTIONS? | default '') == 'true') {
        require ($r.source_commit == ($env.GITHUB_SHA? | default '')) 'report SHA differs from hosted checkout'
        let version = (^$r.firecracker_path --version | complete)
        require ($version.exit_code == 0 and ($version.stdout | str trim) == $r.firecracker_version) 'Firecracker version report differs from pinned executable'
    }
    let baseline = (normalized_config $base)
    require (($r.samples | length) == 6) 'not exactly six timed boots'
    require (($r.samples | get tag | uniq | length) == 6 and ($r.samples | get raw_path | uniq | length) == 6) 'timed boot evidence reused'
    require (($r.samples | get order_index | sort) == [1 2 3 4 5 6]) 'global boot order wrong'
    let expected_order = ['off' 'on' 'on' 'off' 'off' 'on']
    require (($r.samples | sort-by order_index | get variant) == $expected_order) 'pair order is not off/on, on/off, off/on'
    require (($r.samples | get pair | sort) == [1 1 2 2 3 3]) 'pair IDs wrong'
    for s in $r.samples { check_boot $s $r $baseline false }
    check_boot $r.panic_control $r $baseline true
    let nonces = ($r.samples | get nonce | append $r.panic_control.nonce)
    require (($nonces | uniq | length) == 7) 'fresh nonce reused'
    require (($r.panic_control.raw_path in ($r.samples | get raw_path)) == false) 'panic evidence reused'
    let deltas = ([1 2 3] | each {|pair|
        let rows = ($r.samples | where pair == $pair)
        let off = ($rows | where variant == 'off' | first)
        let on = ($rows | where variant == 'on' | first)
        {pair: $pair, off_ms: $off.time_to_ready_ms, on_ms: $on.time_to_ready_ms, saved_ms: ($off.time_to_ready_ms - $on.time_to_ready_ms)}
    })
    {kind: 'firecracker-boot-mute-preteardown-v1', source_commit: $r.source_commit, report_sha256: (file_sha $report), mechanism_pairs_complete: true, panic_visibility: true, all_muted_within_100ms: ($deltas | all {|x| $x.on_ms <= 100}), paired_results: $deltas, firecracker_release_goal: 'PENDING_TEARDOWN'} | to json --indent 2
}
