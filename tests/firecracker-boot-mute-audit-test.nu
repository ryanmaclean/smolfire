#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Synthetic source-only fixtures. No VMM, kernel or KVM is launched.
def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def sha [p: string] { open --raw $p | hash sha256 }
def expected_args [variant: string] {
    let base = 'hint.acpi.0.disabled=0 machdep.disable_tsc_calibration=0 smolfire.ip=172.16.0.2/30 smolfire.gw=172.16.0.1 smolfire.fetch=http://172.16.0.1:8080/token.txt'
    if $variant == 'on' { $"($base) boot_mute=YES" } else { $base }
}
def run_audit [script: string, report: string] { ^nu $script $report | complete }
def reject [script: string, report: string, name: string] {
    let result = (run_audit $script $report)
    require ($result.exit_code != 0) $"audit accepted negative fixture ($name)"
}
def main [] {
    let here = ($env.CURRENT_FILE | path dirname)
    let audit = ($here | path join 'firecracker-boot-mute-audit.nu')
    let finalize = ($here | path join 'firecracker-boot-mute-finalize.nu')
    let temp = (($env.TMPDIR? | default '/tmp') | path join $"fc-ab-fixture-(random uuid)")
    mkdir $temp
    let work = ($temp | path join 'work')
    let dir = ($work | path join 'firecracker-boot-mute')
    mkdir $dir
    let binary = ($work | path join 'firecracker')
    let release = ($work | path join 'smolfire-kernel')
    let base_path = ($work | path join 'fc.json')
    'synthetic-firecracker-v1.12.0' | save --raw $binary
    'synthetic-release-elf' | save --raw $release
    let base = {'boot-source': {kernel_image_path: $release, boot_args: (expected_args 'off')}, drives: [], 'network-interfaces': [{iface_id: 'eth0', guest_mac: '06:00:AC:10:00:02', host_dev_name: 'tap0'}], 'machine-config': {vcpu_count: 1, mem_size_mib: 512}}
    $base | to json --indent 2 | save --raw $base_path
    mut samples = []
    for row in ([1 2 3 4 5 6] | enumerate) {
        let i = ($row.index + 1)
        let variant = (['off' 'on' 'on' 'off' 'off' 'on'] | get $row.index)
        let tag = $"release-($i)-($variant)"
        let nonce = $"fc-ab-00000000-0000-0000-0000-00000000000($i)"
        let ms = (if $variant == 'on' { 87 } else { 180 })
        let cfg = ($dir | path join $"($tag)-config.json")
        let intent_path = ($dir | path join $"($tag)-intent.json")
        let owner_path = ($dir | path join $"($tag)-owner.json")
        let raw_path = ($dir | path join $"($tag).raw")
        let stderr_path = ($dir | path join $"($tag).stderr")
        let cleanup_path = ($dir | path join $"($tag)-cleanup.json")
        let config = ($base | upsert 'boot-source' {kernel_image_path: $release, boot_args: (expected_args $variant)})
        $config | to json --indent 2 | save --raw $cfg
        let args = [$binary '--no-api' '--config-file' $cfg]
        {tag: $tag, variant: $variant, nonce: $nonce, config: $cfg, config_sha256: (sha $cfg), argv: $args} | to json --raw | save --raw $intent_path
        let pid = $"90($i)"
        {pid: $pid, generation: $"10($i)", config: $cfg, exe: $binary, argv: $args} | to json --raw | save --raw $owner_path
        $"SMOLFIRE_NET_OK ($nonce)\nNET_GATE=pass\nSMOLFIRE_READY\nTIME_TO_READY=($ms)ms\nFIRE_42\nSHELL_GATE=pass\nHOST_PING=pass\n" | save --raw $raw_path
        '' | save --raw $stderr_path
        {tag: $tag, pid: $pid, generation: $"10($i)", forced: false, state: 'term-exited'} | to json --raw | save --raw $cleanup_path
        $samples = ($samples | append {tag: $tag, variant: $variant, nonce: $nonce, release_elf_sha256: (sha $release), firecracker_sha256: (sha $binary), config_path: $cfg, config_sha256: (sha $cfg), intent_path: $intent_path, intent_sha256: (sha $intent_path), owner_path: $owner_path, owner_sha256: (sha $owner_path), raw_path: $raw_path, raw_sha256: (sha $raw_path), stderr_path: $stderr_path, cleanup_path: $cleanup_path, cleanup_sha256: (sha $cleanup_path), argv: $args, time_to_ready_ms: $ms, pair: (((($i - 1) / 2) | math floor) + 1), order_index: $i})
    }
    let tag = 'panic-control'
    let nonce = 'fc-ab-00000000-0000-0000-0000-000000000007'
    let cfg = ($dir | path join 'panic-control-config.json')
    let intent_path = ($dir | path join 'panic-control-intent.json')
    let owner_path = ($dir | path join 'panic-control-owner.json')
    let raw_path = ($dir | path join 'panic-control.raw')
    let stderr_path = ($dir | path join 'panic-control.stderr')
    let cleanup_path = ($dir | path join 'panic-control-cleanup.json')
    ($base | upsert 'boot-source' {kernel_image_path: $release, boot_args: (expected_args 'on')}) | to json --indent 2 | save --raw $cfg
    let args = [$binary '--no-api' '--config-file' $cfg]
    {tag: $tag, variant: 'on', nonce: $nonce, config: $cfg, config_sha256: (sha $cfg), argv: $args} | to json --raw | save --raw $intent_path
    {pid: '907', generation: '107', config: $cfg, exe: $binary, argv: $args} | to json --raw | save --raw $owner_path
    $"SMOLFIRE_NET_OK ($nonce)\nNET_GATE=pass\nSMOLFIRE_READY\nsysctl debug.kdb.panic=1\ndebug.kdb.panic: 0panic: kdb_sysctl_panic\nPANIC_CONTROL=pass\n" | save --raw $raw_path
    '' | save --raw $stderr_path
    {tag: $tag, pid: '907', generation: '107', forced: false, state: 'term-exited'} | to json --raw | save --raw $cleanup_path
    let panic = {tag: $tag, variant: 'on', nonce: $nonce, release_elf_sha256: (sha $release), firecracker_sha256: (sha $binary), config_path: $cfg, config_sha256: (sha $cfg), intent_path: $intent_path, intent_sha256: (sha $intent_path), owner_path: $owner_path, owner_sha256: (sha $owner_path), raw_path: $raw_path, raw_sha256: (sha $raw_path), stderr_path: $stderr_path, cleanup_path: $cleanup_path, cleanup_sha256: (sha $cleanup_path), argv: $args, time_to_ready_ms: null}
    let report = {kind: 'firecracker-boot-mute-pairs-v1', source_commit: ('a' | fill -c a -w 40), host_class: 'github-hosted-linux-kvm', host_cpu: 'synthetic CPU', firecracker_version: 'Firecracker v1.12.0', firecracker_path: $binary, firecracker_sha256: (sha $binary), release_elf_path: $release, release_elf_sha256: (sha $release), base_config_path: $base_path, base_config_sha256: (sha $base_path), samples: $samples, panic_control: $panic}
    let report_path = ($dir | path join 'report.json')
    $report | to json --indent 2 | save --raw $report_path
    let original_report = (open --raw $report_path)
    let original_panic_raw = (open --raw $raw_path)
    let original_first_raw = (open --raw $samples.0.raw_path)
    let original_first_config = (open --raw $samples.0.config_path)
    let original_first_intent = (open --raw $samples.0.intent_path)
    let original_first_owner = (open --raw $samples.0.owner_path)
    let original_first_cleanup = (open --raw $samples.0.cleanup_path)
    let original_release = (open --raw $release)
    let good = (run_audit $audit $report_path)
    require ($good.exit_code == 0) $"positive synthetic fixture failed: ($good.stderr)"
    let verdict = ($good.stdout | from json)
    require ($verdict.firecracker_release_goal == 'PENDING_TEARDOWN' and $verdict.all_muted_within_100ms) 'audit emitted premature PASS or wrong timing result'
    let doubled_cr = ($original_first_raw | str replace $"SMOLFIRE_NET_OK ($samples.0.nonce)\n" $"SMOLFIRE_NET_OK ($samples.0.nonce)\r\r\n")
    $doubled_cr | save --raw --force $samples.0.raw_path
    let cr_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert raw_sha256 (sha $samples.0.raw_path))))
    $cr_report | to json --raw | save --raw --force $report_path
    let cr_good = (run_audit $audit $report_path)
    require ($cr_good.exit_code == 0) $"CR CR LF positive raw marker rejected: ($cr_good.stderr)"
    $original_first_raw | save --raw --force $samples.0.raw_path
    $original_report | save --raw --force $report_path
    $good.stdout | save --raw ($dir | path join 'audit.json')
    $good.stdout | save --raw ($dir | path join 'workflow-audit.json')
    let configs = ($samples | get config_path | append $panic.config_path | sort)
    {tag: '', pid: '', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []} | to json --raw | save --raw ($dir | path join 'workflow-cleanup.json')
    let final_good = (^nu $finalize --work $work --audit $audit | complete)
    require ($final_good.exit_code == 0) $"synthetic finalizer rejected resolved receipt: ($final_good.stderr)"
    let observation_path = ($dir | path join $"($samples.0.tag)-owner-observation.json")
    let observation = {pid: '901', generation: '101', state: 'Z', argv: [], exe: ''}
    $observation | to json --raw | save --raw $observation_path
    let reconciled = {tag: $samples.0.tag, pid: '901', generation: '101', forced: false, state: 'already-exited-reconciled', observation_path: $observation_path, observation_sha256: (sha $observation_path), scanned_config: $samples.0.config_path, matching_config_pids: []}
    $reconciled | to json --raw | save --raw --force $samples.0.cleanup_path
    let reconciled_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $reconciled_report | to json --raw | save --raw --force $report_path
    let reconciled_good = (run_audit $audit $report_path)
    require ($reconciled_good.exit_code == 0) $"reconciled exited-owner positive fixture failed: ($reconciled_good.stderr)"
    $reconciled_good.stdout | save --raw --force ($dir | path join 'audit.json')
    $reconciled_good.stdout | save --raw --force ($dir | path join 'workflow-audit.json')
    let reconciled_final = (^nu $finalize --work $work --audit $audit | complete)
    require ($reconciled_final.exit_code == 0) $"finalizer rejected independently audited reconciled owner: ($reconciled_final.stderr)"
    ($observation | upsert generation '999') | to json --raw | save --raw --force $observation_path
    let bad_observation = ($reconciled | upsert observation_sha256 (sha $observation_path))
    $bad_observation | to json --raw | save --raw --force $samples.0.cleanup_path
    let bad_observation_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $bad_observation_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'reconciled observation generation changed with recomputed hashes'
    $observation | to json --raw | save --raw --force $observation_path
    ($reconciled | upsert matching_config_pids ['999']) | to json --raw | save --raw --force $samples.0.cleanup_path
    let residual_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $residual_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'reconciled cleanup retained matching config PID'
    ($observation | upsert state 'R' | upsert argv $samples.0.argv | upsert exe $binary) | to json --raw | save --raw --force $observation_path
    let live_observation = ($reconciled | upsert observation_sha256 (sha $observation_path))
    $live_observation | to json --raw | save --raw --force $samples.0.cleanup_path
    let live_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $live_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'exact live owner falsely called reconciled'
    $original_first_cleanup | save --raw --force $samples.0.cleanup_path
    $original_report | save --raw --force $report_path
    $good.stdout | save --raw --force ($dir | path join 'audit.json')
    $good.stdout | save --raw --force ($dir | path join 'workflow-audit.json')
    let missing_arm = ($report | upsert samples ($samples | drop 1))
    $missing_arm | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'missing arm'
    ($original_first_raw + 'changed') | save --raw --force $samples.0.raw_path
    $original_report | save --raw --force $report_path
    reject $audit $report_path 'raw hash mismatch'
    $original_first_raw | save --raw --force $samples.0.raw_path
    'changed-release-elf' | save --raw --force $release
    let changed_elf = ($report | upsert release_elf_sha256 (sha $release))
    $changed_elf | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'ELF changed after per-boot pin'
    $original_release | save --raw --force $release
    let changed_cfg = ((open $samples.0.config_path) | upsert 'machine-config' {vcpu_count: 2, mem_size_mib: 512})
    $changed_cfg | to json --raw | save --raw --force $samples.0.config_path
    let changed_intent = ((open $samples.0.intent_path) | upsert config_sha256 (sha $samples.0.config_path))
    $changed_intent | to json --raw | save --raw --force $samples.0.intent_path
    let changed_config_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert config_sha256 (sha $samples.0.config_path) | upsert intent_sha256 (sha $samples.0.intent_path))))
    $changed_config_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'config changed with recomputed hashes'
    $original_first_config | save --raw --force $samples.0.config_path
    $original_first_intent | save --raw --force $samples.0.intent_path
    let duplicate_nonce = ($report | upsert samples ($samples | update 1 ($samples.1 | upsert nonce $samples.0.nonce)))
    $duplicate_nonce | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'reused nonce'
    let extra_intent = ((open $samples.0.intent_path) | upsert argv ($samples.0.argv | append ['--extra']))
    $extra_intent | to json --raw | save --raw --force $samples.0.intent_path
    let extra_argv = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert argv ($samples.0.argv | append ['--extra']) | upsert intent_sha256 (sha $samples.0.intent_path))))
    $extra_argv | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'extra argv'
    ($samples.0 | select tag variant nonce config_path config_sha256 argv | rename tag variant nonce config config_sha256 argv) | to json --raw | save --raw --force $samples.0.intent_path
    {tag: $samples.0.tag, pid: '901', generation: '999', forced: false, state: 'term-exited'} | to json --raw | save --raw --force $samples.0.cleanup_path
    let bad_gen = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $bad_gen | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'changed cleanup generation receipt'
    {tag: $samples.0.tag, pid: '901', generation: '101', forced: false, state: 'term-exited'} | to json --raw | save --raw --force $samples.0.cleanup_path
    let early_ready = $"SMOLFIRE_READY\nSMOLFIRE_NET_OK ($samples.0.nonce)\nNET_GATE=pass\nTIME_TO_READY=180ms\nFIRE_42\nSHELL_GATE=pass\nHOST_PING=pass\n"
    $early_ready | save --raw --force $samples.0.raw_path
    let early_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert raw_sha256 (sha $samples.0.raw_path))))
    $early_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'READY before nonce'
    let host_only = $"NET_GATE=pass\nSMOLFIRE_READY\nTIME_TO_READY=180ms\nFIRE_42\nSHELL_GATE=pass\nHOST_PING=pass\n"
    $host_only | save --raw --force $samples.0.raw_path
    let host_only_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert raw_sha256 (sha $samples.0.raw_path))))
    $host_only_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'host-only token without guest raw marker'
    let extended = $"SMOLFIRE_NET_OK ($samples.0.nonce)abcdef\r\r\nNET_GATE=pass\nSMOLFIRE_READY\nTIME_TO_READY=180ms\nFIRE_42\nSHELL_GATE=pass\nHOST_PING=pass\n"
    $extended | save --raw --force $samples.0.raw_path
    let extended_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert raw_sha256 (sha $samples.0.raw_path))))
    $extended_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'extended raw nonce prefix'
    let echoed_shell = $"SMOLFIRE_NET_OK ($samples.0.nonce)\nNET_GATE=pass\nSMOLFIRE_READY\nTIME_TO_READY=180ms\necho FIRE_42\nSHELL_GATE=pass\nHOST_PING=pass\n"
    $echoed_shell | save --raw --force $samples.0.raw_path
    let echo_shell_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert raw_sha256 (sha $samples.0.raw_path))))
    $echo_shell_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'echo-only shell'
    $original_first_raw | save --raw --force $samples.0.raw_path
    let missing_generation = ((open $samples.0.owner_path) | upsert generation '')
    $missing_generation | to json --raw | save --raw --force $samples.0.owner_path
    let owner_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert owner_sha256 (sha $samples.0.owner_path))))
    $owner_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'absent owner generation'
    $original_first_owner | save --raw --force $samples.0.owner_path
    let forced_cleanup = ((open $samples.0.cleanup_path) | upsert forced true | upsert state 'kill-exited')
    $forced_cleanup | to json --raw | save --raw --force $samples.0.cleanup_path
    let forced_report = ($report | upsert samples ($samples | update 0 ($samples.0 | upsert cleanup_sha256 (sha $samples.0.cleanup_path))))
    $forced_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'TERM-resistant forced KILL receipt'
    $original_first_cleanup | save --raw --force $samples.0.cleanup_path
    let false_panic = $"SMOLFIRE_NET_OK ($nonce)\nNET_GATE=pass\nSMOLFIRE_READY\nsysctl debug.kdb.panic=1\ndebug.kdb.panic:PANIC_CONTROL=pass\n"
    $false_panic | save --raw --force $raw_path
    let echo_report = ($report | upsert panic_control ($panic | upsert raw_sha256 (sha $raw_path)))
    $echo_report | to json --raw | save --raw --force $report_path
    reject $audit $report_path 'echo-only panic'
    $original_panic_raw | save --raw --force $raw_path
    $original_report | save --raw --force $report_path
    let restaged = (run_audit $audit $report_path)
    require ($restaged.exit_code == 0 and (($restaged.stdout | from json).report_sha256 == (sha $report_path))) 'fixture was not restored before late teardown checks'
    {tag: '', pid: '', forced: true, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []} | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
    let final_bad = (^nu $finalize --work $work --audit $audit | complete)
    require ($final_bad.exit_code != 0) 'finalizer accepted forced late cleanup'
    {tag: '', pid: '999', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []} | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
    let forged = (^nu $finalize --work $work --audit $audit | complete)
    require ($forged.exit_code != 0) 'finalizer accepted forged late owner fields'
    {tag: '', pid: '', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: ['999']} | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
    let unreported = (^nu $finalize --work $work --audit $audit | complete)
    require ($unreported.exit_code != 0) 'finalizer accepted unreported matching config process'
    {tag: '', pid: '', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []} | to json --raw | save --raw --force ($dir | path join 'workflow-cleanup.json')
    rm ($dir | path join 'workflow-cleanup.json')
    let missing_late = (^nu $finalize --work $work --audit $audit | complete)
    require ($missing_late.exit_code != 0) 'finalizer accepted absent late cleanup'
    {tag: '', pid: '', forced: false, state: 'no-owner', scanned_configs: $configs, matching_config_pids: []} | to json --raw | save --raw ($dir | path join 'workflow-cleanup.json')
    rm ($dir | path join 'audit.json')
    let missing_audit = (^nu $finalize --work $work --audit $audit | complete)
    require ($missing_audit.exit_code != 0) 'finalizer accepted missing audit after runner exit 0'
    $good.stdout | save --raw ($dir | path join 'audit.json')
    rm $report_path
    let missing_report = (^nu $finalize --work $work --audit $audit | complete)
    require ($missing_report.exit_code != 0) 'finalizer accepted missing report after runner exit 0'
    $original_report | save --raw $report_path
    'panic-control' | save --raw ($dir | path join 'current-tag')
    let unresolved = (^nu $finalize --work $work --audit $audit | complete)
    require ($unresolved.exit_code != 0) 'finalizer accepted unresolved current owner'
    rm -r $temp
    print 'synthetic source-only Firecracker A/B audit/finalizer fixtures PASS'
}
