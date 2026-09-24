# Phase 4: Remote Attestation — Acceptance Criteria

<!-- SPDX-License-Identifier: Apache-2.0 -->

**Phase:** 04-remote-attestation  
**Status:** Ready for execution  
**Last updated:** 2026-09-23  
**Prerequisites:** Phase 3 T1–T6 all pass ✅

---

## Gate A1: AK Generation + Quote Production

**Objective:** Create an Attestation Key (AK) inside the TPM and produce a quote over PCR 0+7.

### Acceptance Criteria

| # | Criterion | Verification | Status |
|---|-----------|--------------|--------|
| A1.1 | `tpm2_createprimary -C o -g sha256 -G ecc -c primary.ctx` exits 0 | `guest-attest.nu` step 1 | **done** |
| A1.2 | `tpm2_createak -C primary.ctx -g sha256 -G ecc -c ak.ctx -u ak.pub` exits 0 | `guest-attest.nu` step 2 | **done** |
| A1.3 | `tpm2_quote -c ak.ctx -l sha256:0,7 -q <nonce> -m quote.msg -s quote.sig` exits 0 | `guest-attest.nu` step 4 | **done** |
| A1.4 | `quote.msg` file exists and is > 0 bytes | `guest-attest.nu` verifies before copy | **done** |
| A1.5 | `quote.sig` file exists and is > 0 bytes | `guest-attest.nu` verifies before copy | **done** |
| A1.6 | `tpm2_checkquote -u ak.pub -m quote.msg -s quote.sig -g sha256` exits 0 | Host-side via `attest-verify.nu` | **done** |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A1`
- **Expected:** All A1.* criteria pass; verdict == "pass"

---

## Gate A2: Anti-Replay Nonce

**Objective:** Ensure each quote contains a fresh nonce and replay attacks are detected.

### Acceptance Criteria

| # | Criterion | Verification | Status |
|---|-----------|--------------|--------|
| A2.1 | Nonce is exactly 32 bytes (64 hex characters) | `openssl rand -hex 32` in CI workflow | **done** |
| A2.2 | Nonce is unique per attestation request | Generated fresh per CI run | **done** |
| A2.3 | Nonce is passed to `tpm2_quote` via `--qualifying-data` | `guest-attest.nu` passes `-q $nonce` | **done** |
| A2.4 | `tpm2_checkquote -Q <nonce>` validates qualifying data | Equivalent via `attest-verify.nu` nonce check | **done** |
| A2.5 | `tpm2_checkquote -Q <wrong_nonce>` fails | `attest-verify.nu` rejects mismatched nonce | **done** |
| A2.6 | Replaying an old quote with a new nonce fails | `attest-verify.nu` test 4 covers this | **done** |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A2`
- **Expected:** All A2.* criteria pass; verdict == "pass"

---

## Gate A3: Quote Verification (Signature + PCR + Nonce)

**Objective:** Host-side verifier validates the complete quote.

### Acceptance Criteria

| # | Criterion | Verification | Status |
|---|-----------|--------------|--------|
| A3.1 | `bin/attest-verify.nu` exists and is executable | `test -x bin/attest-verify.nu` | **done** |
| A3.2 | Verifier accepts `--quote`, `--expected-pcr-digest`, `--nonce` | `--help` or argument parsing test | **done** |
| A3.3 | Valid quote → exit 0 + verdict "pass" | Run with valid fixture; assert exit 0 | **done** |
| A3.4 | Invalid signature → exit 1 + verdict "fail" | Corrupt signature; assert failure | **done** |
| A3.5 | Wrong PCR digest → exit 1 + verdict "fail" | Pass wrong --expected-pcr-digest; assert failure | **done** |
| A3.6 | Wrong nonce → exit 1 + verdict "fail" | Pass wrong --nonce; assert failure | **done** |
| A3.7 | Missing quote file → exit 1 + verdict "fail" | Omit --quote; assert failure | **done** |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A3`
- **Expected:** All A3.* criteria pass; verdict == "pass"

---

## Gate A4: Structured TOML Attestation Envelope

**Objective:** Verifier emits a parseable, structured TOML envelope per the AX-first convention.

### Acceptance Criteria

| # | Criterion | Verification | Status |
|---|-----------|--------------|--------|
| A4.1 | Output contains `[attestation]` block | `grep "\[attestation\]" output` | **done** |
| A4.2 | `[attestation]` block contains `verdict` field | `grep "verdict =" output` | **done** |
| A4.3 | `[attestation]` block contains `reason` field (on failure) | `grep "reason =" output` | **done** |
| A4.4 | `[attestation]` block contains `task_id` field | `grep "task_id =" output` | **done** |
| A4.5 | `[attestation]` block contains `nonce` field (hex string) | `grep "nonce =" output` | **done** |
| A4.6 | `[attestation]` block contains `ak_fingerprint` field | `grep "ak_fingerprint =" output` | **done** |
| A4.7 | `[attestation]` block contains `pcr_digest` field | `grep "pcr_digest =" output` | **done** |
| A4.8 | `[attestation]` block contains `pcr_digest_match` field | `grep "pcr_digest_match =" output` | **done** |
| A4.9 | `[attestation]` block contains `timestamp` field (ISO 8601 UTC) | `grep "timestamp =" output` | **done** |
| A4.10 | Output contains `signature_valid` field | `grep "signature_valid =" output` | **done** |
| A4.11 | Output is valid TOML (parses with `from toml` in Nushell) | `parse-attestation` function in test | **done** |
| A4.12 | Verifier supports `--expected-pcr-digest-file` and `--nonce-file` | Test 7 in test suite | **done** |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A4`
- **Expected:** All A4.* criteria pass; verdict == "pass"

---

## Gate A5: CI Round-Trip

**Objective:** Full attestation flow passes in CI on <kvm-host> QEMU+swtpm.

### Acceptance Criteria

| # | Criterion | Verification | Status |
|---|-----------|--------------|--------|
| A5.1 | CI workflow `tpm-vm-test.yml` contains A5 step/job | Lines 164–245 in workflow file | **done** |
| A5.2 | A5 step runs after T6 (reuses running guest) | Sequential steps in same `tpm-t1-t6` job | **done** |
| A5.3 | A5 generates fresh nonce per CI run | `openssl rand -hex 32` in "A5 — Generate fresh nonce" | **done** |
| A5.4 | A5 copies quote.msg, quote.sig, ak.pub from guest to host | Three `scp` commands in workflow | **done** |
| A5.5 | A5 runs `bin/attest-verify.nu` with all required arguments | `nu bin/attest-verify.nu --quote ... --expected-pcr-digest ... --nonce ...` | **done** |
| A5.6 | A5 asserts exit code 0 and verdict == "pass" | `set -e` inherited + verifier exit 0 required | **done** |
| A5.7 | A5 prints TOML envelope to job summary | `cat /tmp/attestation-verdict.toml >> $GITHUB_STEP_SUMMARY` | **done** |
| A5.8 | Workflow fails if any A1-A5 gate fails | `set -e` + Nushell `exit 1` on verifier failure | **done** |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A5`
- **Expected:** All A5.* criteria pass; verdict == "pass"

---

## Overall Phase Acceptance

**Phase 4 is complete when:**
1. ✅ All gates A1–A5 are implemented
2. ✅ All acceptance criteria in this document are marked **done**
3. ✅ `tests/tpm-attest-verify-test.nu` passes (7/7 tests green)
4. 🔄 CI workflow `tpm-vm-test.yml` runs green with A5 enabled (pending self-hosted runner)
5. ✅ `bin/attest-verify.nu` is committed and documented

**Sign-off:**
- [x] A1 complete — guest-attest.nu implements tpm2_createprimary + tpm2_createak + tpm2_quote
- [x] A2 complete — 32-byte nonce generated per-run, anti-replay verified
- [x] A3 complete — verifier implemented and tested (7/7 tests green)
- [x] A4 complete — structured TOML envelope with all required fields
- [x] A5 complete — CI workflow integrated in tpm-vm-test.yml
- [ ] CI green — pending self-hosted KVM runner availability
- [x] Documentation updated — acceptance criteria marked done

---

*Phase: 04-remote-attestation*
*Acceptance criteria defined: 2026-09-23*
