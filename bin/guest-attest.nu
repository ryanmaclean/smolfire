#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# guest-attest.nu — generate a TPM 2.0 quote inside a smolfire FreeBSD guest.
#
# Runs inside the FreeBSD guest to create a TPM 2.0 primary key and Attestation
# Key (AK), generate a quote over PCR 0 and PCR 7, and emit a TOML record with
# all artifact paths and the PCR digest.
#
# Prerequisites (FreeBSD port):
#   security/tpm2-tools — provides tpm2_createek, tpm2_createak,
#   tpm2_quote, tpm2_pcrread, tpm2_flushcontext.
#
# Usage:
#   nu guest-attest.nu --nonce abcdef1234567890
#   nu guest-attest.nu --nonce abcdef1234567890 --task-id job-001
#   nu guest-attest.nu --nonce abcdef1234567890 --output-dir /var/run/attest

# Emit a structured TOML log-step line to stdout.
def log-step [step: string, payload: record] {
    let ts  = date now | format date "%Y-%m-%dT%H:%M:%SZ"
    let row = {ts: $ts, step: $step} | merge $payload
    $row | to toml | print
    print "---"
}

# Generate a version-4-style UUID.
# Tries uuidgen first; falls back to openssl rand segments.
def gen-uuid [] {
    try {
        ^uuidgen | str trim
    } catch {
        let p1 = ^openssl rand -hex 4 | str trim
        let p2 = ^openssl rand -hex 2 | str trim
        let p3 = ^openssl rand -hex 2 | str trim
        let p4 = ^openssl rand -hex 2 | str trim
        let p5 = ^openssl rand -hex 6 | str trim
        $"($p1)-($p2)-($p3)-($p4)-($p5)"
    }
}

# Check that all required binaries exist in PATH.
def check-prereqs [] {
    let required = ["tpm2_createek" "tpm2_createak" "tpm2_quote" "tpm2_pcrread" "tpm2_flushcontext"]
    for bin in $required {
        if (which $bin | length) == 0 {
            return {ok: false, missing: $bin}
        }
    }
    {ok: true, missing: null}
}

# Run an external tpm2 command, log it, and return stdout.
# Exits non-zero on failure.
def run-tpm2 [label: string, args: list<string>] {
    let cmd_str = $args | str join " "
    log-step $label {cmd: $cmd_str}
    let result = try {
        run-external ($args | first) ...($args | skip 1) | complete
    } catch {|err|
        log-step $"($label)_failed" {error: $err.msg, cmd: $cmd_str}
        error make {msg: $"($label) failed: ($err.msg)\ncmd: ($cmd_str)"}
    }
    if $result.exit_code != 0 {
        let stderr_text = $result.stderr | str trim
        log-step $"($label)_failed" {exit_code: $result.exit_code, stderr: $stderr_text, cmd: $cmd_str}
        error make {msg: $"($label) exited ($result.exit_code): ($cmd_str)\nstderr: ($stderr_text)"}
    }
    $result.stdout | str trim
}

# Flush stale TPM state best-effort: transient objects (-t), saved sessions
# (-s), plus ACTIVE sessions (0x02xxxxxx handle range).
# T5 seal/unseal PCR-policy sessions leak ACTIVE sessions that neither -t
# nor -s reclaims, so by the time the guest step runs swtpm's tiny session
# table is full and EK creation dies on its 3rd StartAuthSession with
# TPM-side 0x903 "out of memory for session contexts" (trace-proven over
# the wire: ESAPI healthy, TPM-side exhaustion). Census active handles via
# tpm2_getcap and flush each one. tpm2_flushcontext exits 0 with nothing to
# flush, and any failure here must NOT fail the run — log the outcome in
# one guest_attest_flush step and always succeed.
def flush-tpm2 [] {
    let t = try {
        run-external "tpm2_flushcontext" "-t" | complete
    } catch {|err|
        {exit_code: -1, stdout: "", stderr: $err.msg}
    }
    let s = try {
        run-external "tpm2_flushcontext" "-s" | complete
    } catch {|err|
        {exit_code: -1, stdout: "", stderr: $err.msg}
    }
    # ACTIVE-session census: tpm2_getcap handles-loaded-session lists
    # 0x02xxxxxx handles (-t/-s never touch this range). Empty list → no-op;
    # any error → logged below, never fails the run.
    let cap = try {
        run-external "tpm2_getcap" "handles-loaded-session" | complete
    } catch {|err|
        {exit_code: -1, stdout: "", stderr: $err.msg}
    }
    let cap_stdout = try { $cap.stdout } catch { "" }
    let active_handles = try {
        $cap_stdout | split row -r '\s+' | where { str starts-with "0x02" } | uniq
    } catch { [] }
    mut active_flushed = 0
    mut active_failed = 0
    for h in $active_handles {
        let ok = flush-one-active $h
        if $ok { $active_flushed += 1 } else { $active_failed += 1 }
    }
    log-step "guest_attest_flush" {
        transient_exit_code: $t.exit_code,
        transient_stderr: ($t.stderr | str trim),
        session_exit_code: $s.exit_code,
        session_stderr: ($s.stderr | str trim),
        active_cap_exit_code: $cap.exit_code,
        active_cap_stderr: ($cap.stderr | str trim),
        active_handles: ($active_handles | length),
        active_flushed: $active_flushed,
        active_flush_failed: $active_failed
    }
}

# Flush one ACTIVE-session handle best-effort. Returns true on success.
# Helper keeps try/catch closures out of flush-tpm2's mutable counters
# (nushell forbids capturing mutable variables inside closures).
def flush-one-active [h: string] {
    try {
        let r = run-external "tpm2_flushcontext" $h | complete
        $r.exit_code == 0
    } catch {
        false
    }
}

# Parse PCR hex values from tpm2_pcrread text output.
# Returns a record {pcr0: "hex", pcr7: "hex"}.
def parse-pcrs [raw: string] {
    mut pcr0 = ""
    mut pcr7 = ""
    for line in ($raw | lines | each { str trim }) {
        if ($line | str contains ": 0x") {
            let parts = $line | split row ": 0x"
            if ($parts | length) >= 2 {
                let num = $parts.0 | str trim
                let val = $parts.1 | str trim
                if $num == "0" { $pcr0 = $val }
                if $num == "7" { $pcr7 = $val }
            }
        }
    }
    {pcr0: $pcr0, pcr7: $pcr7}
}

# Compute SHA256 digest of concatenated PCR 0 + PCR 7 values.
# Uses only openssl (in FreeBSD base and the guest image): decode the
# concatenated hex ASCII via `openssl enc -d -a`, then hash the decoded
# bytes with `openssl dgst -sha256`. Hex-dump utilities are NOT in
# FreeBSD base (nor in the guest image), so they are deliberately not
# used here.
def compute-pcr-digest [pcr0_hex: string, pcr7_hex: string] {
    let combined = $"($pcr0_hex)($pcr7_hex)"
    try {
        # Portable primary: openssl-only decode + hash pipeline.
        # NOTE: the trailing newline is load-bearing — `openssl enc -d -a`
        # skips whitespace while decoding, and some builds silently emit
        # zero bytes when the final base64 block is not newline-terminated.
        # ($combined already ends without a newline, so append one —
        # equivalent to POSIX `echo $combined | openssl enc -d -a`.)
        $"($combined)\n" | ^openssl enc -d -a | ^openssl dgst -sha256 | ^awk '{print $NF}' | str trim
    } catch {
        # Fallback: hash the hex string itself (ASCII)
        try {
            ^printf '%s' $combined | ^openssl dgst -sha256 | ^awk '{print $NF}' | str trim
        } catch {
            ""
        }
    }
}

# ── Entry point ───────────────────────────────────────────────────────────────

# Generate a TPM 2.0 attestation quote inside a smolfire FreeBSD guest.
#
# --nonce      hex nonce (required)
# --task-id    task identifier (default: auto-generated UUID)
# --output-dir directory for quote artifacts (default: /tmp)
export def main [
    --nonce:      string  # hex nonce (required)
    --task-id:    string = ""  # task identifier (default: UUID)
    --output-dir: string = "/tmp"  # directory for artifacts
] {
    # Validate required nonce
    if ($nonce | str length) == 0 {
        error make {msg: "--nonce is required (provide a hex string, e.g. --nonce abcdef1234)"}
    }

    let task_id = if ($task_id | str length) > 0 { $task_id } else { gen-uuid }

    log-step "guest_attest_begin" {
        task_id: $task_id
        nonce: $nonce
        output_dir: $output_dir
    }

    # Check prerequisites
    let prereqs = check-prereqs
    if not $prereqs.ok {
        log-step "guest_attest_prereq_fail" {missing: $prereqs.missing}
        error make {msg: $"missing prerequisite: ($prereqs.missing)\nInstall security/tpm2-tools and ensure it is in PATH"}
    }
    log-step "guest_attest_prereq_ok" {}

    # Reclaim stale transient objects/sessions left by earlier steps (T5
    # seal/unseal) before touching the EK. Best-effort: never fails the run.
    flush-tpm2

    # Ensure output directory exists
    if not ($output_dir | path exists) {
        ^mkdir -p $output_dir
        log-step "guest_attest_output_dir_created" {path: $output_dir}
    }

    let primary_ctx = [$output_dir "primary.ctx"] | path join
    let ak_ctx      = [$output_dir "ak.ctx"] | path join
    let ak_pub      = [$output_dir "ak.pub"] | path join
    let quote_msg   = [$output_dir "quote.msg"] | path join
    let quote_sig   = [$output_dir "quote.sig"] | path join
    let attest_toml = [$output_dir "attestation.toml"] | path join
    let expected_pcr_file = [$output_dir "expected_pcr.txt"] | path join

    # Step 1: Create endorsement key (EK) to parent the AK.
    # tpm2_createak drives a policy session matching the EK template's auth
    # policy (tpm2_createak(1): "-C: The endorsement key object"), so its
    # parent MUST be a tpm2_createek EK: a generic tpm2_createprimary parent
    # makes createak fail with 0x99D "a policy check failed" (tpm2-tools#3475).
    # Use the DEFAULT (RSA) EK template: the -G ecc EK template path fails on
    # cert-less swtpm with 0x903 "out of memory for session contexts" in
    # Esys_StartAuthSession + "Invalid EK authorization" (A5 runs 35908434059,
    # 35909133534 — deterministic across flush/no-flush, so not stale T5
    # sessions). EK alg does NOT constrain AK alg: the AK below stays ECC,
    # so the verifier's ECC quote path (tpm2_checkquote over ak.pub) is
    # untouched.
    run-tpm2 "guest_attest_createprimary" [
        "tpm2_createek"
        "-c" $primary_ctx
    ]

    # Step 2: Create Attestation Key under the primary key
    run-tpm2 "guest_attest_createak" [
        "tpm2_createak"
        "-C" $primary_ctx
        "-g" "sha256"
        "-G" "ecc"
        "-c" $ak_ctx
        "-u" $ak_pub
    ]

    # Step 3: Read PCR values to compute external digest
    let pcr_raw = run-tpm2 "guest_attest_pcrread" [
        "tpm2_pcrread"
        "sha256:0,7"
    ]
    let pcrs = parse-pcrs $pcr_raw

    if ($pcrs.pcr0 | str length) == 0 or ($pcrs.pcr7 | str length) == 0 {
        log-step "guest_attest_pcr_parse_fail" {raw: $pcr_raw}
        error make {msg: "failed to parse PCR 0 or PCR 7 from tpm2_pcrread output"}
    }

    let pcr_digest = compute-pcr-digest $pcrs.pcr0 $pcrs.pcr7 | str lowercase | str trim

    log-step "guest_attest_pcr_read" {
        pcr0: $pcrs.pcr0
        pcr7: $pcrs.pcr7
        pcr_digest: $pcr_digest
    }

    # Step 4: Generate TPM quote over PCR 0 + 7
    run-tpm2 "guest_attest_quote" [
        "tpm2_quote"
        "-c" $ak_ctx
        "-l" "sha256:0,7"
        "-q" $nonce
        "-m" $quote_msg
        "-s" $quote_sig
    ]

    log-step "guest_attest_quote_ok" {
        quote_msg: $quote_msg
        quote_sig: $quote_sig
        ak_pub: $ak_pub
        pcr_digest: $pcr_digest
    }

    # Step 4b: Write verifier input files expected by CI
    # (attestation.toml + expected_pcr.txt). Uses openssl base64 -A for
    # single-line base64 portable across FreeBSD base and Linux.
    let quote_b64 = ^openssl base64 -A -in $quote_msg | str trim
    let sig_b64 = ^openssl base64 -A -in $quote_sig | str trim
    let ak_b64 = ^openssl base64 -A -in $ak_pub | str trim
    let attest_record = {
        task_id: $task_id
        nonce: $nonce
        pcr_digest: $pcr_digest
        quote_data: $quote_b64
        signature: $sig_b64
        ak_public: $ak_b64
    }
    $attest_record | to toml | save --force $attest_toml
    $"($pcr_digest)\n" | save --force $expected_pcr_file

    log-step "guest_attest_artifacts_written" {
        attestation_toml: $attest_toml
        expected_pcr_file: $expected_pcr_file
    }

    # Step 5: Emit structured TOML result
    let result = {
        "guest-attest": {
            task_id: $task_id
            nonce: $nonce
            quote_msg: $quote_msg
            quote_sig: $quote_sig
            ak_pub: $ak_pub
            pcr_digest: $pcr_digest
        }
    }

    print ""
    $result | to toml | print
}
