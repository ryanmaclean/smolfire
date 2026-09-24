#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# bhyve-tpm-argv-test.nu — argv-builder unit test for the bhyve TPM fix.
#
# Regression test for the bug where bin/bhyve-smolfire-vm.nu and
# bin/swtpm-setup.nu used a PCI-slot form (`-s N,tpm,type=swtpm,path=...`)
# for bhyve's TPM device. Per bhyve(8) (FreeBSD 15.1), TPM is an LPC/ACPI
# CRB device attached with `-l tpm,swtpm,<socket>` (or
# `-l tpm,passthru,/dev/tpm0` for passthrough, amd64 only) — there is no
# `-s N,tpm,...` PCI device.
#
# This test sources the argv-builder functions directly (no bhyve, no
# swtpm, no FreeBSD host required) and asserts:
#   A1  build-cmd-amd64 (--tpm) emits `-l tpm,swtpm,<sock>` verbatim
#   A2  build-cmd-amd64 (--tpm) never emits a `-s N,tpm,...` PCI slot
#   A3  build-cmd-amd64 (no --tpm) emits no tpm-related flag at all
#   A4  build-cmd-arm64 never emits any tpm-related flag (arm64 has no
#       bhyve TPM device backend)
#   A5  swtpm-setup.nu's build-start-args passes bhyve/QEMU the *data*
#       socket via --server (not just --ctrl), per swtpm(8)
#
# Usage:
#   nu tests/bhyve-tpm-argv-test.nu
#
# Output: TOML claims block, one [[claims]] record per assertion.
# Exit code: 0 if all assertions pass, 1 if any fail.

# Emit a structured TOML log-step line to stdout.
def log-step [step: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, step: $step} | merge $payload
    $row | to toml | print
    print "---"
}

# Build a claims record (all six fields required on one call site).
def make-claim [t: string, subject: string, expected: string, probe: string, evidence: string, verdict: string] {
    {t: $t, subject: $subject, expected: $expected, probe: $probe, evidence: $evidence, verdict: $verdict}
}

# Print one [[claims]] TOML stanza to stdout.
def emit-claim [claim: record] {
    print "[[claims]]"
    print $"t        = \"($claim.t)\""
    print $"subject  = \"($claim.subject)\""
    print $"expected = \"($claim.expected)\""
    print $"probe    = \"($claim.probe)\""
    print $"evidence = \"($claim.evidence)\""
    print $"verdict  = \"($claim.verdict)\""
    print ""
}

export def main [] {
    # Resolve repo root relative to this test file so it can run from any cwd.
    let script_dir = $env.CURRENT_FILE? | default "" | path dirname
    let repo_root  = if ($"($script_dir)/../bin" | path exists) {
        $script_dir | path join ".."
    } else {
        "."
    }
    let bhyve_script = $repo_root | path join "bin" "bhyve-smolfire-vm.nu"
    let swtpm_script = $repo_root | path join "bin" "swtpm-setup.nu"

    log-step "argv_test_start" {bhyve_script: $bhyve_script, swtpm_script: $swtpm_script}

    mut claims = []
    mut fail_count = 0

    # ── A1/A2: build-cmd-amd64 with --tpm ──────────────────────────────────
    let sock_path = "/var/run/smolfire-tpm/swtpm.sock"
    let amd64_tpm_cmd = (
        nu --no-config-file -c $"
            source '($bhyve_script)'
            let cmd = \(build-cmd-amd64 'smolfire' '/tmp/fake.raw' '512M' 2 '/dev/nmdm0A' true '($sock_path)')
            $cmd | str join ' '
        "
    )
    log-step "amd64_tpm_argv" {cmd: $amd64_tpm_cmd}

    let expected_flag = $"-l tpm,swtpm,($sock_path)"
    let has_lpc_tpm = $amd64_tpm_cmd | str contains $expected_flag
    $claims = ($claims | append (make-claim
        "A1" "bin/bhyve-smolfire-vm.nu build-cmd-amd64 --tpm"
        $expected_flag
        "source script; call build-cmd-amd64 with tpm=true; join argv"
        $amd64_tpm_cmd
        (if $has_lpc_tpm { "pass" } else { "fail" })
    ))
    if not $has_lpc_tpm { $fail_count = $fail_count + 1 }

    # No `-s N,tpm,...` PCI-slot form anywhere in the amd64+tpm argv.
    let has_bad_pci_tpm = ($amd64_tpm_cmd =~ '-s [0-9]+,tpm,')
    $claims = ($claims | append (make-claim
        "A2" "bin/bhyve-smolfire-vm.nu build-cmd-amd64 --tpm"
        "no -s N,tpm,... PCI slot present"
        "regex search for '-s [0-9]+,tpm,' in the argv"
        $amd64_tpm_cmd
        (if $has_bad_pci_tpm { "fail" } else { "pass" })
    ))
    if $has_bad_pci_tpm { $fail_count = $fail_count + 1 }

    # ── A3: build-cmd-amd64 without --tpm emits no tpm flag at all ─────────
    let amd64_notpm_cmd = (
        nu --no-config-file -c $"
            source '($bhyve_script)'
            let cmd = \(build-cmd-amd64 'smolfire' '/tmp/fake.raw' '512M' 2 '/dev/nmdm0A' false '')
            $cmd | str join ' '
        "
    )
    log-step "amd64_notpm_argv" {cmd: $amd64_notpm_cmd}
    let notpm_clean = not ($amd64_notpm_cmd | str contains "tpm")
    $claims = ($claims | append (make-claim
        "A3" "bin/bhyve-smolfire-vm.nu build-cmd-amd64 (no --tpm)"
        "no tpm-related flag present"
        "substring search for 'tpm' in the argv"
        $amd64_notpm_cmd
        (if $notpm_clean { "pass" } else { "fail" })
    ))
    if not $notpm_clean { $fail_count = $fail_count + 1 }

    # ── A4: build-cmd-arm64 never emits any tpm flag ───────────────────────
    let arm64_cmd = (
        nu --no-config-file -c $"
            source '($bhyve_script)'
            let cmd = \(build-cmd-arm64 'smolfire' '/tmp/fake.raw' '512M' 2)
            $cmd | str join ' '
        "
    )
    log-step "arm64_argv" {cmd: $arm64_cmd}
    let arm64_clean = not ($arm64_cmd | str contains "tpm")
    $claims = ($claims | append (make-claim
        "A4" "bin/bhyve-smolfire-vm.nu build-cmd-arm64"
        "no tpm-related flag present (arm64 bhyve has no TPM device backend)"
        "substring search for 'tpm' in the argv"
        $arm64_cmd
        (if $arm64_clean { "pass" } else { "fail" })
    ))
    if not $arm64_clean { $fail_count = $fail_count + 1 }

    # ── A5: swtpm-setup.nu build-start-args passes --server (data socket) ──
    let swtpm_args_str = (
        nu --no-config-file -c $"
            source '($swtpm_script)'
            let paths = resolve-paths '/var/run/smolfire-tpm' '' '' ''
            let args = build-start-args '/usr/local/bin/swtpm' $paths
            $args | str join ' '
        "
    )
    log-step "swtpm_start_args" {cmd: $swtpm_args_str}
    let has_server = $swtpm_args_str | str contains "--server type=unixio,path=/var/run/smolfire-tpm/swtpm.sock"
    let has_ctrl   = $swtpm_args_str | str contains "--ctrl type=unixio,path=/var/run/smolfire-tpm/swtpm-ctrl.sock"
    let server_ok  = $has_server and $has_ctrl
    $claims = ($claims | append (make-claim
        "A5" "bin/swtpm-setup.nu build-start-args"
        "--server (data socket, for bhyve/QEMU) AND --ctrl (control socket) both present, on distinct paths"
        "substring search for --server and --ctrl unixio paths in the argv"
        $swtpm_args_str
        (if $server_ok { "pass" } else { "fail" })
    ))
    if not $server_ok { $fail_count = $fail_count + 1 }

    # ── Emit claims + final verdict ─────────────────────────────────────────
    print ""
    print "# bhyve-tpm-argv-test result"
    for c in $claims { emit-claim $c }

    let overall = if $fail_count == 0 { "pass" } else { "fail" }
    log-step "argv_test_done" {fail_count: $fail_count, verdict: $overall}

    if $fail_count != 0 {
        exit 1
    }
}
