#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# Late, read-only verdict for one FreeBSD guest reboot and VMM exit witness.
use firecracker-owner-scan.nu matching_config_pids

def require [ok: bool, why: string] { if not $ok { error make {msg: $why} } }
def sha [path: string] { require ($path | path exists) $"missing required witness file: ($path)"; open --raw $path | hash sha256 }
def no_firecracker [] {
    let ps = (^pgrep -x firecracker | complete)
    require ($ps.exit_code == 1) 'a Firecracker remains or global enumeration failed after teardown'
}
def verify [work: string] {
    let dir = ($work | path join 'firecracker-exit-witness')
    let intent_path = ($dir | path join 'intent.json')
    let owner_path = ($dir | path join 'owner.json')
    let early_path = ($dir | path join 'early-result.json')
    let cleanup_path = ($dir | path join 'early-cleanup.json')
    let late_path = ($dir | path join 'workflow-cleanup.json')
    let raw_path = ($dir | path join 'console.raw')
    let pre_path = ($dir | path join 'pre-reboot-owner.json')
    for path in [$intent_path $owner_path $early_path $cleanup_path $late_path $raw_path $pre_path] { require ($path | path exists) $"missing witness evidence: ($path)" }
    let intent = (open $intent_path)
    let owner = (open $owner_path)
    let early = (open $early_path)
    let cleanup = (open $cleanup_path)
    let late = (open $late_path)
    let pre = (open $pre_path)
    require ($intent.kind == 'firecracker-exit-witness-intent-v1' and $intent.source_commit == $env.GITHUB_SHA) 'intent source head differs from hosted exact head'
    require ($intent.config == ($dir | path join 'one-boot-config.json') and $intent.config_sha256 == (sha $intent.config)) 'intent config changed'
    require ($intent.release_elf_sha256 == (sha ($work | path join 'smolfire-kernel')) and $intent.firecracker_sha256 == (sha ($work | path join 'firecracker'))) 'pinned release ELF or Firecracker changed'
    require ($intent.argv == [($work | path join 'firecracker') '--no-api' '--config-file' $intent.config]) 'intent argv changed'
    require ($owner.pid =~ '^[0-9]+$' and $owner.generation =~ '^[0-9]+$' and $owner.config == $intent.config and $owner.exe == $intent.argv.0 and $owner.argv == $intent.argv) 'spawn-time owner differs from one-boot intent'
    require ($pre.pid == $owner.pid and $pre.generation == $owner.generation and $pre.exe == $owner.exe and $pre.argv == $owner.argv and not ($pre.state in ['Z' 'X' 'x'])) 'pre-reboot owner was not exact/live'
    require ($early.kind == 'firecracker-freebsd-exit-witness-v1' and $early.source_commit == $env.GITHUB_SHA and $early.verdict == 'EXIT_OBSERVED' and $early.expect_rc == 0) 'early witness did not prove exit'
    require ($early.intent_sha256 == (sha $intent_path) and $early.owner_sha256 == (sha $owner_path) and $early.pre_reboot_owner_sha256 == (sha $pre_path) and $early.raw_sha256 == (sha $raw_path) and $early.cleanup_sha256 == (sha $cleanup_path)) 'early witness hashes no longer match raw evidence'
    require ($early.reboot_sent and $early.console_eof and $early.nonce_seen and $early.ready_seen and $early.shell_seen and $early.owner_verified and $early.no_panic) 'guest/console evidence incomplete'
    let raw = (open --raw $raw_path)
    require (($raw | str contains 'GUEST_REBOOT_SENT=1') and ($raw | str contains 'CONSOLE_EOF=after_reboot') and ($raw | str contains $"SMOLFIRE_NET_OK ($intent.nonce)") and ($raw | str contains 'SHELL_GATE=pass') and not ($raw | str contains 'panic:')) 'raw console no longer supports early witness'
    for receipt in [$cleanup $late] {
        require ($receipt.state in ['already-exited' 'naturally-exited'] and not $receipt.forced and $receipt.pid == $owner.pid and $receipt.generation == $owner.generation and $receipt.config == $intent.config and $receipt.config_sha256 == $intent.config_sha256) 'early or late owner cleanup unresolved or mismatched'
        require (($receipt.matching_config_pids | is-empty) and ($receipt.global_firecracker_pids | is-empty)) 'early or late process scan not empty'
    }
    require (not ($"/proc/($owner.pid)" | path exists)) 'recorded owner PID remains after late teardown'
    require ((matching_config_pids [$intent.config]) | is-empty) 'exact attempted config still in use after late teardown'
    no_firecracker
    {kind: 'firecracker-freebsd-exit-final-v1', source_commit: $env.GITHUB_SHA, verdict: 'EXIT_CONFIRMED', single_boot_only: true, release_goal: 'UNPROVEN', owner_pid: $owner.pid, owner_generation: $owner.generation, intent_sha256: (sha $intent_path), owner_sha256: (sha $owner_path), console_sha256: (sha $raw_path), early_sha256: (sha $early_path), early_cleanup_sha256: (sha $cleanup_path), late_cleanup_sha256: (sha $late_path)}
}
def main [--work: string = '/mnt/smolfire-ci'] {
    require (($env.GITHUB_ACTIONS? | default '') == 'true' and ($env.RUNNER_OS? | default '') == 'Linux') 'hosted Linux only'
    let path = ($work | path join 'firecracker-exit-witness' 'final-verdict.json')
    let result = (try { {ok: true, value: (verify $work)} } catch {|err| {ok: false, value: {kind: 'firecracker-freebsd-exit-final-v1', verdict: 'HOLD', release_goal: 'UNPROVEN', reason: $err.msg}} })
    $result.value | to json --indent 2 | save --raw --force $path
    print ($result.value | to json --raw)
    if not $result.ok { error make {msg: $result.value.reason} }
}
