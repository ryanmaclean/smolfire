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
| A1.1 | `tpm2_createprimary -C o -g sha256 -G ecc -c primary.ctx` exits 0 | Run in guest; check exit code | not started |
| A1.2 | `tpm2_createak -C primary.ctx -g sha256 -G ecc -c ak.ctx -u ak.pub` exits 0 | Run in guest; check exit code | not started |
| A1.3 | `tpm2_quote -c ak.ctx -l sha256:0,7 -q <nonce> -m quote.msg -s quote.sig` exits 0 | Run in guest; check exit code | not started |
| A1.4 | `quote.msg` file exists and is > 0 bytes | `test -s quote.msg` in guest | not started |
| A1.5 | `quote.sig` file exists and is > 0 bytes | `test -s quote.sig` in guest | not started |
| A1.6 | `tpm2_checkquote -u ak.pub -m quote.msg -s quote.sig -g sha256` exits 0 | Run on host with copied files | not started |

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
| A2.1 | Nonce is exactly 32 bytes (64 hex characters) | Length check on host-generated nonce | not started |
| A2.2 | Nonce is unique per attestation request | Compare nonces across two runs; must differ | not started |
| A2.3 | Nonce is passed to `tpm2_quote` via `--qualifying-data` | Inspect tpm2_quote command line | not started |
| A2.4 | `tpm2_checkquote -Q <nonce>` validates qualifying data | Run with correct nonce; must exit 0 | not started |
| A2.5 | `tpm2_checkquote -Q <wrong_nonce>` fails | Run with wrong nonce; must exit 1 | not started |
| A2.6 | Replaying an old quote with a new nonce fails | Save quote from run 1, verify with run 2 nonce; must fail | not started |

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
| A3.1 | `bin/attest-verify.nu` exists and is executable | `test -x bin/attest-verify.nu` | not started |
| A3.2 | Verifier accepts `--quote-msg`, `--quote-sig`, `--ak-pub`, `--nonce`, `--pcr-digest` | `--help` or argument parsing test | not started |
| A3.3 | Valid quote → exit 0 + verdict "pass" | Run with A1 artifacts; assert exit 0 | not started |
| A3.4 | Invalid signature → exit 1 + verdict "fail" + reason "signature_invalid" | Corrupt quote.sig; assert failure | not started |
| A3.5 | Wrong PCR digest → exit 1 + verdict "fail" + reason "pcr_mismatch" | Pass wrong --pcr-digest; assert failure | not started |
| A3.6 | Wrong nonce → exit 1 + verdict "fail" + reason "nonce_mismatch" | Pass wrong --nonce; assert failure | not started |
| A3.7 | Missing AK pub → exit 1 + verdict "fail" + reason "missing_ak" | Omit --ak-pub; assert failure | not started |

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
| A4.1 | Output contains `[attestation]` block | `grep "\[attestation\]" output.toml` | not started |
| A4.2 | `[attestation]` block contains `verdict` field | `grep "verdict =" output.toml` | not started |
| A4.3 | `[attestation]` block contains `reason` field | `grep "reason =" output.toml` | not started |
| A4.4 | `[attestation]` block contains `gate` field with value "A5" | `grep "gate = \"A5\"" output.toml` | not started |
| A4.5 | `[attestation]` block contains `nonce` field (hex string) | `grep "nonce =" output.toml` | not started |
| A4.6 | `[attestation]` block contains `ak_fingerprint` field | `grep "ak_fingerprint =" output.toml` | not started |
| A4.7 | `[attestation]` block contains `pcr_digest` field | `grep "pcr_digest =" output.toml` | not started |
| A4.8 | `[attestation]` block contains `pcr_selection` field | `grep "pcr_selection =" output.toml` | not started |
| A4.9 | `[attestation]` block contains `timestamp` field (ISO 8601 UTC) | `grep "timestamp =" output.toml` | not started |
| A4.10 | Output contains at least 3 `[[evidence]]` blocks | Count `\[\[evidence\]\]` occurrences >= 3 | not started |
| A4.11 | Each `[[evidence]]` block contains `claim`, `verdict`, `evidence` fields | Field presence check per block | not started |
| A4.12 | TOML is valid (parses with `from toml` in Nushell) | `open output.toml | from toml` exits 0 | not started |

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
| A5.1 | CI workflow `tpm-vm-test.yml` contains A5 step/job | Inspect workflow file | not started |
| A5.2 | A5 step runs after T6 (reuses running guest) | Job dependency graph | not started |
| A5.3 | A5 generates fresh nonce per CI run | Inspect workflow (openssl rand -hex 32) | not started |
| A5.4 | A5 copies quote.msg, quote.sig, ak.pub from guest to host | SCP commands in workflow | not started |
| A5.5 | A5 runs `bin/attest-verify.nu` with all required arguments | Command line in workflow | not started |
| A5.6 | A5 asserts exit code 0 and verdict == "pass" | Workflow test assertion | not started |
| A5.7 | A5 prints TOML envelope to job summary | `echo "::notice::$(cat envelope.toml)"` or equivalent | not started |
| A5.8 | Workflow fails if any A1-A5 gate fails | `set -e` or equivalent error propagation | not started |

### Test Script
- **File:** `tests/tpm-attest-verify-test.nu`
- **Flag:** `--gate A5`
- **Expected:** All A5.* criteria pass; verdict == "pass"

---

## Overall Phase Acceptance

**Phase 4 is complete when:**
1. All gates A1–A5 are implemented
2. All acceptance criteria in this document are marked **done**
3. `tests/tpm-attest-verify-test.nu --gate A5` passes
4. CI workflow `tpm-vm-test.yml` runs green with A5 enabled
5. `bin/attest-verify.nu` is committed and documented

**Sign-off:**
- [ ] A1 complete
- [ ] A2 complete
- [ ] A3 complete
- [ ] A4 complete
- [ ] A5 complete
- [ ] CI green
- [ ] Documentation updated

---

*Phase: 04-remote-attestation*
*Acceptance criteria defined: 2026-09-23*
