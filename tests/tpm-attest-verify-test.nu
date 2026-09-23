#!/usr/bin/env nu
# SPDX-License-Identifier: Apache-2.0
# tests/tpm-attest-verify-test.nu — Tests for bin/attest-verify.nu
#
# Verifies the TPM quote verifier logic without requiring real TPM hardware.
# Uses pre-generated test fixtures.

# ── Assert helpers ─────────────────────────────────────────────────────────────

def "assert equal" [left: any, right: any] {
    if $left != $right {
        error make {msg: $"assert equal failed\n  left:  ($left | to nuon)\n  right: ($right | to nuon)"}
    }
}

def assert [cond] {
    if not $cond { error make {msg: "assert failed"} }
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def make-temp-dir [] { ^mktemp -d | str trim }

# Run attest-verify.nu and capture its exit code + stdout.
def run-verifier [quote_file: string, pcr_digest: string, nonce: string] {
    let result = (^nu bin/attest-verify.nu
        --quote $quote_file
        --expected-pcr-digest $pcr_digest
        --nonce $nonce
    ) | complete

    {
        exit_code: $result.exit_code,
        stdout: $result.stdout
    }
}

# Parse [attestation] block from verifier output.
def parse-attestation [output] {
    let lines = $output | lines | where {|l| $l != "" }
    mut result = {}
    mut in_block = false

    for line in $lines {
        if $line == "[attestation]" {
            $in_block = true
            continue
        }
        if not $in_block { continue }

        if ($line | str contains " = ") {
            let parts = $line | split row " = "
            if ($parts | length) >= 2 {
                let key = $parts.0 | str trim
                let val = $parts.1 | str trim | str replace -a '"' ''
                $result = ($result | insert $key $val)
            }
        }
    }

    $result
}

# Generate a valid quote TOML fixture.
def make-valid-quote [task_id: string, pcr_digest: string, nonce: string] {
    # Generate deterministic test keys and signatures
    let tmpdir = make-temp-dir

    # Generate RSA key pair for testing
    let priv_key = $"($tmpdir)/test_key.pem"
    let pub_key = $"($tmpdir)/test_key.pub"

    # Generate 2048-bit RSA key (using genpkey for OpenSSL 3.x compatibility)
    (^openssl genpkey -algorithm RSA -out $priv_key -pkeyopt rsa_keygen_bits:2048) | ignore
    (^openssl rsa -in $priv_key -pubout -out $pub_key) | ignore

    # Create test quote data
    let quote_json = ({
        task_id: $task_id,
        pcr_selection: "sha256:0,7",
        pcr_digest: $pcr_digest,
        nonce: $nonce,
        timestamp: "2026-09-23T00:00:00Z"
    } | to json)

    let quote_file = $"($tmpdir)/quote.json"
    $quote_json | save --force $quote_file

    # Sign the quote
    let sig_file = $"($tmpdir)/quote.sig"
    (^openssl dgst -sha256 -sign $priv_key -out $sig_file $quote_file) | ignore

    # Read and base64 encode everything
    let quote_b64 = (open --raw $quote_file | ^base64 | str trim)
    let sig_b64 = (open --raw $sig_file | ^base64 | str trim)
    let pub_b64 = (open --raw $pub_key | ^base64 | str trim)

    # Cleanup
    ^rm -rf $tmpdir

    # Build TOML quote file content
    let quote_toml = $'
task_id = "($task_id)"
pcr_digest = "($pcr_digest)"
nonce = "($nonce)"
quote_data = "($quote_b64)"
signature = "($sig_b64)"
ak_public = "($pub_b64)"
'
    $quote_toml
}

# ── Tests ────────────────────────────────────────────────────────────────────

print "test 1: verifier rejects missing quote file"
do {
    let tmp = make-temp-dir
    let result = run-verifier "/nonexistent/quote.toml" "abc123" "nonce123"
    assert equal $result.exit_code 1
    # When quote file is missing, error is printed to stderr, not attestation block
    # Just verify exit code is non-zero
    ^rm -rf $tmp
}

print "test 2: verifier accepts valid quote with matching PCR and nonce"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "1234567890abcdef"
    let quote_content = make-valid-quote "t-test-2" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let result = run-verifier $quote_file $pcr $nonce
    assert equal $result.exit_code 0
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "PASS"
    assert equal $att.pcr_digest_match "true"
    assert equal $att.nonce_match "true"
    assert equal $att.signature_valid "true"

    ^rm -rf $tmp
}

print "test 3: verifier rejects quote with mismatched PCR digest"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "1234567890abcdef"
    let quote_content = make-valid-quote "t-test-3" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let wrong_pcr = "0000000000000000000000000000000000000000000000000000000000000000"
    let result = run-verifier $quote_file $wrong_pcr $nonce
    assert equal $result.exit_code 1
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "FAIL"
    assert equal $att.pcr_digest_match "false"

    ^rm -rf $tmp
}

print "test 4: verifier rejects quote with mismatched nonce"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "1234567890abcdef"
    let quote_content = make-valid-quote "t-test-4" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let wrong_nonce = "ffffffffffffffff"
    let result = run-verifier $quote_file $pcr $wrong_nonce
    assert equal $result.exit_code 1
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "FAIL"
    assert equal $att.nonce_match "false"

    ^rm -rf $tmp
}

print "test 5: verifier emits structured attestation block"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "test-nonce-12345"
    let quote_content = make-valid-quote "t-test-5" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let result = run-verifier $quote_file $pcr $nonce
    assert equal $result.exit_code 0
    let att = parse-attestation $result.stdout

    # Verify all required fields present
    assert ("verdict" in $att)
    assert ("task_id" in $att)
    assert ("timestamp" in $att)
    assert ("pcr_digest_match" in $att)
    assert ("signature_valid" in $att)
    assert ("nonce_match" in $att)
    assert ("pcr_digest" in $att)
    assert ("nonce" in $att)
    assert ("ak_fingerprint" in $att)

    assert equal $att.task_id "t-test-5"
    assert equal $att.pcr_digest $pcr
    assert equal $att.nonce $nonce

    ^rm -rf $tmp
}

print "test 6: verifier rejects quote with tampered signature"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "1234567890abcdef"
    let quote_content = make-valid-quote "t-test-6" $pcr $nonce

    # Tamper with the signature
    let tampered = $quote_content | str replace -a "signature = " "signature = INVALID"
    let quote_file = $"($tmp)/quote.toml"
    $tampered | save --force $quote_file

    let result = run-verifier $quote_file $pcr $nonce
    assert equal $result.exit_code 1
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "FAIL"
    assert equal $att.signature_valid "false"

    ^rm -rf $tmp
}

print "test 7: verifier handles --expected-pcr-digest-file and --nonce-file"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "file-nonce-123"
    let quote_content = make-valid-quote "t-test-7" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let pcr_file = $"($tmp)/expected.pcr"
    $pcr | save --force $pcr_file
    let nonce_file = $"($tmp)/expected.nonce"
    $nonce | save --force $nonce_file

    let result = (^nu bin/attest-verify.nu
        --quote $quote_file
        --expected-pcr-digest-file $pcr_file
        --nonce-file $nonce_file
    ) | complete

    assert equal $result.exit_code 0
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "PASS"

    ^rm -rf $tmp
}

print "all tests passed"
