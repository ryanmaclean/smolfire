# Phase 4: Remote Attestation — Context

**Gathered:** 2026-09-23
**Status:** Ready for planning
**Mode:** auto (all decisions auto-selected from recommended options)

<!-- SPDX-License-Identifier: Apache-2.0 -->

<domain>
## Phase Boundary

Deliver a hardware-free remote attestation protocol built on the Phase 3 QEMU+swtpm
stack. The smolBSD guest generates TPM 2.0 quotes over PCR 0+7 using an Attestation
Key (AK), and a host-side verifier (`bin/attest-verify.nu`) validates the quote
signature, PCR digest, and anti-replay nonce — producing a structured TOML attestation
envelope.

**In scope:**
- Generate an Attestation Key (AK) inside the guest via `tpm2_createak`
- Produce a TPM 2.0 quote (`tpm2_quote`) over PCR 0+7 with a fresh nonce
- Verify quote signature + PCR digest + nonce on the host via `tpm2_checkquote` or equivalent
- Emit structured TOML attestation envelope (`[attestation]` block with verdict, evidence)
- CI gate: full quote→verify round-trip passes on <kvm-host> QEMU+swtpm

**Out of scope:**
- Physical board (Pi 5 / RK3588) — Phase 5
- Remote verifier service (network listener, REST API) — future enhancement
- Key attestation (EK certificate chain validation) — Phase 5 candidate
- Measured boot with Secure Boot chain (sbctl, efistub) — Phase 5 candidate
</domain>

<decisions>
## Implementation Decisions

### D-01: AK Strategy — Persistent vs Ephemeral
Use a **persistent AK** (loaded into TPM NV index) so the same key can be used across
multiple quotes without re-running `tpm2_createak` each time. This matches the CI pattern:
1. `tpm2_createprimary` → primary key in owner hierarchy
2. `tpm2_createak` → AK with loaded handle
3. Save AK public area to host for later verification
4. Reuse handle for all subsequent quotes

### D-02: Nonce Source
The host-side verifier generates a cryptographically random 32-byte nonce and passes
it to the guest via SSH command (or file) before quote generation. The nonce must:
- Be fresh per attestation request (not hardcoded, not reused)
- Be included in the quote message (tpm2_quote --qualifying-data)
- Be returned in the TOML envelope for correlation

### D-03: Verification Approach
Use `tpm2_checkquote` as the canonical verifier. Requires:
- Quote file (from guest)
- Signature file (from guest)
- AK public file (exported from guest or pre-shared)
- Expected PCR digest (recomputed on host from PCR values)
- Nonce (supplied by host, checked against quote)

Fallback: If `tpm2_checkquote` is unavailable on host, implement equivalent OpenSSL
signature verification in Nushell (parse TPMT_SIGNATURE, verify RSA/ECDSA sig over
digest).

### D-04: TOML Envelope Format
Per the AX-first convention, verifier emits a TOML block:

```toml
[attestation]
verdict       = "pass"        # or "fail"
reason        = "signature_valid_pcr_match_nonce_match"
gate          = "A5"          # which acceptance gate this satisfies
nonce         = "deadbeef..." # hex-encoded 32-byte nonce
ak_fingerprint = "sha256:..." # hash of AK public area
pcr_digest    = "sha256:..." # expected PCR digest from quote
pcr_selection  = "sha256:0,7" # which PCRs were quoted
timestamp     = "2026-09-23T12:34:56Z"

[[evidence]]
claim    = "quote_signature_valid"
verdict  = "pass"
evidence = "tpm2_checkquote exited 0"

[[evidence]]
claim    = "pcr_digest_matches_expected"
verdict  = "pass"
evidence = "computed sha256(PCR0||PCR7) == quote.digest"

[[evidence]]
claim    = "nonce_fresh"
verdict  = "pass"
evidence = "nonce present in qualifyingData field of quote"
```

### D-05: CI Integration
Extend `tpm-vm-test.yml` with an A5 job that:
1. Starts swtpm (reuse Phase 3 T1 setup)
2. Boots smolBSD image with TPM (reuse Phase 3 T2 setup)
3. Generates nonce on host
4. SSHs to guest: runs `tpm2_createak` + `tpm2_quote` with nonce
5. SCPs quote, signature, and AK pub back to host
6. Runs `bin/attest-verify.nu` with expected PCR values
7. Asserts TOML envelope verdict == "pass"

### Claude's Discretion
- Exact tpm2_createak handle allocation (0x81010001 vs auto)
- Whether to use RSA or ECC for the AK (ECC preferred: smaller signatures, faster)
- Exact Nushell vs shell script split for `bin/attest-verify.nu`
- Whether to cache AK pub on host filesystem between CI runs
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase specification
- `.planning/ROADMAP.md` lines 80-101 — Phase 4 scope and acceptance gates
- `.planning/phases/03-tpm-2-0-measured-boot/03-CONTEXT.md` — Phase 3 decisions and patterns
- `.planning/phases/03-tpm-2-0-measured-boot/03-RESEARCH.md` — TPM 2.0 command research

### Existing CI/scripts (reused from Phase 3)
- `.github/workflows/tpm-vm-test.yml` — TPM CI (to be extended with A5)
- `.github/workflows/build-image.yml` — Image build workflow
- `bin/qemu-smolbsd.nu` — QEMU launcher with --tpm flag
- `bin/swtpm-setup.nu` — swtpm lifecycle manager
- `bin/run-vm-tests.nu` — VM test orchestrator
- `tests/bhyve-tpm-pcr-verify.nu` — T1–T6 verifier (pattern reference)

### New files for Phase 4
- `bin/attest-verify.nu` — Host-side verifier (TOML envelope + tpm2_checkquote wrapper)
- `tests/tpm-attest-verify-test.nu` — A1–A5 acceptance test suite

### Infrastructure
- `docs/VM-TESTING.md` — Validated QEMU+swtpm command lines, PCR0 proof
- `docs/CICD.md` — CI/CD operator guide

### Key Phase 3 artifacts
- `03-T1T6-RESULTS.toml` — Proof that Phase 3 passed (prerequisite)
- `03-T5-RESULTS.toml` — Seal/unseal proof
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `bin/qemu-smolbsd.nu` — Supports `--tpm --arch amd64`, starts swtpm inline
- `bin/swtpm-setup.nu` — Full lifecycle: start/stop/status/reset; T1 gate built in
- `bin/run-vm-tests.nu` — 10-step orchestrator, `--tpm` and `--backend qemu` flags wired
- `tests/bhyve-tpm-pcr-verify.nu` — Structured claims pattern; reuse for A1–A5
- `tests/tpm-seal-test.nu` — TPM command pattern reference (createprimary, unseal, etc.)

### Established Patterns
- Log-step TOML format (`{ts, step, payload}`) used throughout all .nu scripts
- Attestation `[[claims]]` blocks expected by the coord-tick.nu proveryay hook
- All timestamps use `date to-timezone utc | format date "%Y-%m-%dT%H:%M:%SZ"`
- Tests emit structured TOML results; smolfire-test-report.nu aggregates them

### Integration Points
- `tpm-vm-test.yml` needs: A5 job added after T6 verification step
- `bin/attest-verify.nu` needs: guest SSH access (same as T2–T6), tpm2-tools on guest
- `tests/tpm-attest-verify-test.nu` needs: same SSH credentials as existing test scripts

### Known Constraints
- QEMU aarch64 TPM still blocked (ControlArea=0) — Phase 4 is amd64-only, same as Phase 3
- smolBSD image already has tpm2-tools baked in (Phase 3 D-02)
- PCR0 value is stable for a given kernel/build: `B6A903D197F7F1DFDAD0C3D74244009C9AA407F55AE5F753D7F8B3F0C10F5727`
</code_context>

<specifics>
## Specific Ideas

- The existing `tpm2_createprimary` + `tpm2_createak` pattern from `tests/tpm-seal-test.nu`
  can be reused. The AK public area can be exported with `tpm2_readpublic -c <ak_handle>`.
- `tpm2_quote` supports `--qualifying-data <hex>` for the nonce. The nonce should be
  exactly 32 bytes (64 hex chars) to align with SHA-256 block size.
- `tpm2_checkquote` requires: `-u <ak.pub> -m <quote.msg> -s <quote.sig> -g sha256 -Q <nonce>`.
  The `-Q` flag verifies the qualifying data (nonce) is present in the quote.
- For the TOML envelope, follow the exact `[attestation]` + `[[evidence]]` pattern
  already established in the coord-tick.nu proveryay hook.
</specifics>

<deferred>
## Deferred Ideas

- Physical Pi 5 / RK3588 TPM via fTPM/OP-TEE — Phase 5 (prerequisite: Phase 4 A1–A5 pass)
- Remote attestation REST API (verifier as a service) — Phase 5+ enhancement
- Key attestation with EK certificate chain — Phase 5+ (requires physical TPM with certs)
- Measured boot with Secure Boot chain (sbctl, efistub) — Phase 5 candidate
- aarch64 QEMU TPM (blocked: ControlArea=0) — needs physical board
</deferred>

---

*Phase: 04-remote-attestation*
*Context gathered: 2026-09-23*
