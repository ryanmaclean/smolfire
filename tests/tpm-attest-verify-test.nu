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

print "test 8: verifier degrades gracefully when tpm2_checkquote fails or is missing"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "1234567890abcdef"
    let quote_content = make-valid-quote "t-test-8" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    # Case A: tpm2_checkquote absent (this macOS host has none) — RSA
    # fixture must still PASS via the openssl fallback, not crash.
    let result_absent = run-verifier $quote_file $pcr $nonce
    assert equal $result_absent.exit_code 0

    # Case B: tpm2_checkquote present but failing (e.g. RSA fixture blobs
    # are not TPMS_ATTEST format) — must fall back to openssl, not crash.
    let fakebin = $"($tmp)/fakebin"
    ^mkdir -p $fakebin
    let fake = $"($fakebin)/tpm2_checkquote"
    "#!/bin/sh\necho 'fake tpm2_checkquote: cannot parse input' >&2\nexit 2\n" | save --force $fake
    ^chmod +x $fake
    # NOTE: with-env replaces PATH, so resolve nu absolutely first —
    # otherwise the nested `nu bin/attest-verify.nu` call cannot be found.
    # ($env.PATH is a list in nushell — join it explicitly.)
    let nu_bin = (which nu | get path.0)
    let parent_path = ($env.PATH | str join (char esep))
    let result_fallback = with-env {PATH: $"($fakebin)(char esep)($parent_path)"} {
        (^$nu_bin bin/attest-verify.nu
            --quote $quote_file
            --expected-pcr-digest $pcr
            --nonce $nonce
        ) | complete | {exit_code: $in.exit_code, stdout: $in.stdout}
    }
    assert equal $result_fallback.exit_code 0
    let att = parse-attestation $result_fallback.stdout
    assert equal $att.verdict "PASS"
    assert equal $att.signature_valid "true"

    ^rm -rf $tmp
}

print "test 9: verifier accepts raw guest files via --quote-msg/--quote-sig/--ak-pub"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "raw-files-nonce-9"
    let quote_content = make-valid-quote "t-test-9" $pcr $nonce
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    # Recover the raw guest files by decoding the bundled TOML blobs
    # (byte-identical to quote.msg/quote.sig/ak.pub on the guest).
    let q = open $quote_file
    $q.quote_data | ^base64 -d | save --force $"($tmp)/quote.msg"
    $q.signature | ^base64 -d | save --force $"($tmp)/quote.sig"
    $q.ak_public | ^base64 -d | save --force $"($tmp)/ak.pub"

    let result = (^nu bin/attest-verify.nu
        --quote $quote_file
        --expected-pcr-digest $pcr
        --nonce $nonce
        --quote-msg $"($tmp)/quote.msg"
        --quote-sig $"($tmp)/quote.sig"
        --ak-pub $"($tmp)/ak.pub"
    ) | complete

    assert equal $result.exit_code 0
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "PASS"
    assert equal $att.signature_valid "true"

    # Raw guest files must be untouched (verifier stages copies).
    assert ($"($tmp)/quote.msg" | path exists)
    assert ($"($tmp)/quote.sig" | path exists)
    assert ($"($tmp)/ak.pub" | path exists)

    ^rm -rf $tmp
}

print "test 10: verifier rejects ECC-shaped blob via openssl path without erroring"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "ecc-shape-nonce-10"

    # EC P-256 AK (like the guest's ECC AK) with an ECC-shaped 64-byte
    # (r||s) signature blob that does NOT verify. The openssl RSA path
    # must return false (clean FAIL), never throw.
    (^openssl ecparam -genkey -name prime256v1 -out $"($tmp)/ec_priv.pem") | ignore
    (^openssl ec -in $"($tmp)/ec_priv.pem" -pubout -out $"($tmp)/ec_pub.pem") | ignore
    let quote_json = ({task_id: "t-test-10", pcr_digest: $pcr, nonce: $nonce} | to json)
    $quote_json | save --force $"($tmp)/quote.json"
    (^openssl rand -out $"($tmp)/quote.sig" 64) | ignore

    let quote_b64 = (open --raw $"($tmp)/quote.json" | ^base64 | str trim)
    let sig_b64 = (open --raw $"($tmp)/quote.sig" | ^base64 | str trim)
    let pub_b64 = (open --raw $"($tmp)/ec_pub.pem" | ^base64 | str trim)
    let quote_content = $'
task_id = "t-test-10"
pcr_digest = "($pcr)"
nonce = "($nonce)"
quote_data = "($quote_b64)"
signature = "($sig_b64)"
ak_public = "($pub_b64)"
'
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    let result = run-verifier $quote_file $pcr $nonce
    assert equal $result.exit_code 1
    # Still emits a well-formed attestation block (no crash, no throw).
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "FAIL"
    assert equal $att.signature_valid "false"

    ^rm -rf $tmp
}

print "test 11: tpm2 path is wired correctly (argv seam) and exit 0 means valid"
do {
    let tmp = make-temp-dir
    let pcr = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let nonce = "deadbeef01"
    # ECC-shaped blob the openssl path would reject — proves the PASS
    # below comes from the tpm2 path, not the fallback.
    (^openssl ecparam -genkey -name prime256v1 -out $"($tmp)/ec_priv.pem") | ignore
    (^openssl ec -in $"($tmp)/ec_priv.pem" -pubout -out $"($tmp)/ec_pub.pem") | ignore
    ({task_id: "t-test-11", pcr_digest: $pcr, nonce: $nonce} | to json) | save --force $"($tmp)/quote.json"
    (^openssl rand -out $"($tmp)/quote.sig" 64) | ignore
    let quote_b64 = (open --raw $"($tmp)/quote.json" | ^base64 | str trim)
    let sig_b64 = (open --raw $"($tmp)/quote.sig" | ^base64 | str trim)
    let pub_b64 = (open --raw $"($tmp)/ec_pub.pem" | ^base64 | str trim)
    let quote_content = $'
task_id = "t-test-11"
pcr_digest = "($pcr)"
nonce = "($nonce)"
quote_data = "($quote_b64)"
signature = "($sig_b64)"
ak_public = "($pub_b64)"
'
    let quote_file = $"($tmp)/quote.toml"
    $quote_content | save --force $quote_file

    # Fake tpm2_checkquote: records argv to a file, exits 0 (valid).
    let fakebin = $"($tmp)/fakebin"
    ^mkdir -p $fakebin
    let fake = $"($fakebin)/tpm2_checkquote"
    let argv_file = $"($fake).argv"
    ('#!/bin/sh' + "\n" + 'echo "$*" > "' + $argv_file + '"' + "\n" + 'exit 0' + "\n") | save --force $fake
    ^chmod +x $fake

    let nu_bin = (which nu | get path.0)
    let parent_path = ($env.PATH | str join (char esep))
    let result = with-env {PATH: $"($fakebin)(char esep)($parent_path)"} {
        (^$nu_bin bin/attest-verify.nu
            --quote $quote_file
            --expected-pcr-digest $pcr
            --nonce $nonce
        ) | complete | {exit_code: $in.exit_code, stdout: $in.stdout}
    }
    assert equal $result.exit_code 0
    let att = parse-attestation $result.stdout
    assert equal $att.verdict "PASS"
    assert equal $att.signature_valid "true"

    # The seam: exact tpm2_checkquote invocation the guest commands require
    # (-u ak.pub -m quote.msg -s quote.sig -f plain -g sha256 -q hex-nonce).
    let argv = open --raw $"($fake).argv" | str trim
    assert ($argv | str contains "-u ")
    assert ($argv | str contains "-m ")
    assert ($argv | str contains "-s ")
    assert ($argv | str contains "-f plain")
    assert ($argv | str contains "-g sha256")
    assert ($argv | str contains $"-q ($nonce)")

    ^rm -rf $tmp
}

print "all tests passed"
