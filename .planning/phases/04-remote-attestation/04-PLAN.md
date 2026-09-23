---
phase: 04-remote-attestation
plan: "01"
type: execute
wave: 1
depends_on: [03-tpm-2-0-measured-boot]
autonomous: true
requirements: [ATTEST-AK, ATTEST-QUOTE, ATTEST-VERIFY, ATTEST-TOML, ATTEST-CI]

must_haves:
  truths:
    - "Phase 3 T1-T6 all pass (prerequisite)"
    - "smolBSD amd64 image with tpm2-tools exists on <kvm-host>"
    - "swtpm + QEMU stack proven working from Phase 3"
    - "tpm2_createak, tpm2_quote, tpm2_checkquote available in guest"
  artifacts:
    - path: "bin/attest-verify.nu"
      provides: "Host-side verifier script (quote validation + TOML envelope)"
      contains: "tpm2_checkquote wrapper, TOML output, verdict logic"
    - path: "tests/tpm-attest-verify-test.nu"
      provides: "A1-A5 acceptance test suite"
      contains: "A1-A5 test cases, TOML results"
  key_links:
    - from: "tests/tpm-attest-verify-test.nu"
      to: "bin/attest-verify.nu"
      via: "ssh + scp"
      pattern: "quote.msg, quote.sig, ak.pub transferred from guest to host"
    - from: "bin/attest-verify.nu"
      to: ".github/workflows/tpm-vm-test.yml"
      via: "CI job step"
      pattern: "A5 gate runs attest-verify.nu and asserts verdict == pass"
---

<objective>
Implement hardware-free remote attestation: smolBSD guest generates a TPM 2.0 quote
over PCR 0+7 using an Attestation Key (AK), and a host-side verifier
(`bin/attest-verify.nu`) validates the quote signature, PCR digest, and anti-replay
nonce — producing a structured TOML attestation envelope.

Purpose: Prove the smolBSD guest's boot state (PCR 0+7) can be cryptographically
verified by a remote party without trusting the guest. Foundation for Phase 5
physical fTPM attestation.

Output: `bin/attest-verify.nu` and `tests/tpm-attest-verify-test.nu` committed;
A1-A5 all passing in CI.
</objective>

<execution_context>
@/Users/studio/.claude/get-shit-done/workflows/execute-plan.md
@/Users/studio/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@/Users/studio/smolBSD/.planning/PROJECT.md
@/Users/studio/smolBSD/.planning/ROADMAP.md
@/Users/studio/smolBSD/.planning/STATE.md
@/Users/studio/smolBSD/.planning/phases/04-remote-attestation/04-CONTEXT.md
@/Users/studio/smolBSD/.planning/phases/03-tpm-2-0-measured-boot/03-CONTEXT.md
</context>

<interfaces>
<!-- Key patterns from existing test scripts -->
<!-- tests/tpm-seal-test.nu already does tpm2_createprimary + tpm2_createpolicy -->
<!-- bin/run-vm-tests.nu already orchestrates SSH to guest with --tpm --backend qemu -->

From tests/bhyve-tpm-pcr-verify.nu (claims pattern):
```nu
[[claims]]
t        = "T1"
subject  = "..."
expected = "..."
probe    = "..."
evidence = "..."
verdict  = "pass"
```

Pattern to follow for A1-A5:
```nu
[[claims]]
t        = "A1"
subject  = "tpm2_createak produces AK; tpm2_quote succeeds over sha256:0,7"
expected = "quote.msg and quote.sig files produced; tpm2_checkquote exits 0"
probe    = "ssh root@127.0.0.1 -p 2241 'tpm2_createak ... && tpm2_quote ...'"
evidence = "AK handle 0x81010001 created; quote over PCR 0+7 generated"
verdict  = "pass"
```
</interfaces>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: A1 — Generate AK and produce quote over PCR 0+7</name>
  <files>
    - tests/tpm-attest-verify-test.nu
    - bin/attest-verify.nu (stub)
  </files>
  <read_first>
    - tests/tpm-seal-test.nu (understands tpm2_createprimary pattern)
    - docs/VM-TESTING.md (PCR0 value reference)
    - .planning/phases/04-remote-attestation/04-CONTEXT.md (D-01, D-02)
  </read_first>
  <action>
    **RED:** Write failing test in `tests/tpm-attest-verify-test.nu` that asserts:
    1. `tpm2_createprimary -C o -g sha256 -G ecc -c primary.ctx` succeeds
    2. `tpm2_createak -C primary.ctx -g sha256 -G ecc -c ak.ctx -u ak.pub` succeeds
    3. `tpm2_quote -c ak.ctx -l sha256:0,7 -q <nonce> -m quote.msg -s quote.sig` succeeds
    4. Files quote.msg and quote.sig are non-empty
    5. `tpm2_checkquote -u ak.pub -m quote.msg -s quote.sig -g sha256` succeeds

    Run test — MUST fail (files don't exist yet).
    Commit: `test(04-remote-attestation): add failing A1 test`

    **GREEN:** Implement the TPM command sequence in `tests/tpm-attest-verify-test.nu`.
    The script should SSH to the guest, run the AK + quote commands, and copy
    quote.msg, quote.sig, and ak.pub back to the host for verification.

    Run test — MUST pass.
    Commit: `feat(04-remote-attestation): implement A1 AK + quote generation`
  </action>
  <verify>
    <automated>nu tests/tpm-attest-verify-test.nu --dry-run</automated>
  </verify>
  <acceptance_criteria>
    - tpm2_createprimary succeeds (primary key in owner hierarchy)
    - tpm2_createak succeeds (AK created, ak.pub exported)
    - tpm2_quote succeeds over sha256:0,7 with a nonce
    - quote.msg and quote.sig files exist and are non-empty
    - tpm2_checkquote validates the quote against ak.pub (exit 0)
  </acceptance_criteria>
  <done>A1 passing: AK generated, quote produced, quote signature validates.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 2: A2 — Anti-replay nonce in quote</name>
  <files>
    - tests/tpm-attest-verify-test.nu
  </files>
  <read_first>
    - .planning/phases/04-remote-attestation/04-CONTEXT.md (D-02)
  </read_first>
  <action>
    **RED:** Extend `tests/tpm-attest-verify-test.nu` with A2 test that asserts:
    1. The nonce supplied to tpm2_quote (--qualifying-data) appears in the quote message
    2. A different nonce produces a different quote signature
    3. Replaying an old quote with a new nonce fails tpm2_checkquote

    Run test — MUST fail.
    Commit: `test(04-remote-attestation): add failing A2 anti-replay test`

    **GREEN:** Implement nonce generation (32-byte random hex) on the host,
    pass it to guest via SSH command, and verify qualifying data in quote.

    Run test — MUST pass.
    Commit: `feat(04-remote-attestation): implement A2 anti-replay nonce`
  </action>
  <verify>
    <automated>nu tests/tpm-attest-verify-test.nu --gate A2</automated>
  </verify>
  <acceptance_criteria>
    - Nonce is 32 bytes (64 hex chars), fresh per test run
    - Nonce is passed to tpm2_quote via --qualifying-data
    - tpm2_checkquote with -Q <nonce> validates qualifying data
    - Replaying old quote with new nonce fails verification
  </acceptance_criteria>
  <done>A2 passing: Quote contains fresh nonce; replay attacks detected.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 3: A3 — Verify quote signature + PCR digest + nonce</name>
  <files>
    - bin/attest-verify.nu
    - tests/tpm-attest-verify-test.nu
  </files>
  <read_first>
    - .planning/phases/04-remote-attestation/04-CONTEXT.md (D-03)
  </read_first>
  <action>
    **RED:** Write failing test that asserts `bin/attest-verify.nu`:
    1. Takes quote.msg, quote.sig, ak.pub, expected PCR digest, and nonce as arguments
    2. Runs tpm2_checkquote (or equivalent) and returns exit 0 on valid quote
    3. Returns exit 1 on invalid signature, wrong PCR digest, or nonce mismatch
    4. Produces structured TOML output (even on failure)

    Run test — MUST fail (attest-verify.nu is stub).
    Commit: `test(04-remote-attestation): add failing A3 verifier test`

    **GREEN:** Implement `bin/attest-verify.nu`:
    - Parse command-line args (quote.msg, quote.sig, ak.pub, nonce, pcr_digest)
    - Run `tpm2_checkquote -u ak.pub -m quote.msg -s quote.sig -g sha256 -Q nonce`
    - Parse result and emit TOML envelope
    - Return exit 0 on pass, exit 1 on fail

    Run test — MUST pass.
    Commit: `feat(04-remote-attestation): implement A3 quote verifier`
  </action>
  <verify>
    <automated>nu bin/attest-verify.nu --help</automated>
  </verify>
  <acceptance_criteria>
    - attest-verify.nu accepts: --quote-msg, --quote-sig, --ak-pub, --nonce, --pcr-digest
    - Validates signature with tpm2_checkquote (or OpenSSL fallback)
    - Validates PCR digest matches expected value
    - Validates nonce is present in quote qualifying data
    - Returns exit 0 + TOML envelope on pass
    - Returns exit 1 + TOML envelope on fail (with reason field)
  </acceptance_criteria>
  <done>A3 passing: Host-side verifier validates quote signature, PCR digest, and nonce.</done>
</task>

<task type="auto" tdd="true">
  <name>Task 4: A4 — Structured TOML attestation envelope</name>
  <files>
    - bin/attest-verify.nu
  </files>
  <read_first>
    - .planning/phases/04-remote-attestation/04-CONTEXT.md (D-04)
  </read_first>
  <action>
    **RED:** Write failing test that asserts TOML output from attest-verify.nu:
    1. Contains `[attestation]` block with verdict, reason, gate, nonce, ak_fingerprint, pcr_digest
    2. Contains `[[evidence]]` blocks for each claim (signature, PCR, nonce)
    3. TOML is valid and parseable by `from toml`
    4. All required fields are present and non-empty

    Run test — MUST fail.
    Commit: `test(04-remote-attestation): add failing A4 TOML envelope test`

    **GREEN:** Update `bin/attest-verify.nu` to emit the exact TOML format from D-04:
    - Compute ak_fingerprint = sha256(ak.pub bytes)
    - Compute pcr_digest from expected values
    - Build [attestation] block + [[evidence]] blocks
    - Write to stdout (or file if --output specified)

    Run test — MUST pass.
    Commit: `feat(04-remote-attestation): implement A4 TOML attestation envelope`
  </action>
  <verify>
    <automated>nu bin/attest-verify.nu --quote-msg /dev/null --quote-sig /dev/null --ak-pub /dev/null --nonce 0000 --pcr-digest 0000 2>&1 | grep -q 'verdict = "fail"'</automated>
  </verify>
  <acceptance_criteria>
    - TOML output contains [attestation] block with all required fields
    - TOML output contains [[evidence]] blocks for signature, PCR, and nonce claims
    - Output is valid TOML (parses with `from toml` in Nushell)
    - Verdict is "pass" or "fail" (no other values)
    - Timestamp uses ISO 8601 UTC format
  </acceptance_criteria>
  <done>A4 passing: Verifier emits structured TOML attestation envelope.</done>
</task>

<task type="auto">
  <name>Task 5: A5 — CI round-trip gate</name>
  <files>
    - .github/workflows/tpm-vm-test.yml
  </files>
  <read_first>
    - .github/workflows/tpm-vm-test.yml (current structure)
    - .planning/phases/04-remote-attestation/04-CONTEXT.md (D-05)
  </read_first>
  <action>
    Extend `.github/workflows/tpm-vm-test.yml` with an A5 job that runs after
    the T6 verification step:

    1. Reuse the running smolBSD guest from T1-T6 (don't reboot)
    2. Generate a fresh nonce on the host: `openssl rand -hex 32`
    3. SSH to guest and run:
       ```sh
       tpm2_createprimary -C o -g sha256 -G ecc -c primary.ctx
       tpm2_createak -C primary.ctx -g sha256 -G ecc -c ak.ctx -u ak.pub
       tpm2_quote -c ak.ctx -l sha256:0,7 -q $NONCE -m /tmp/quote.msg -s /tmp/quote.sig
       ```
    4. SCP /tmp/quote.msg, /tmp/quote.sig, /tmp/ak.pub back to host
    5. Run: `nu bin/attest-verify.nu --quote-msg quote.msg --quote-sig quote.sig --ak-pub ak.pub --nonce $NONCE --pcr-digest $EXPECTED_PCR_DIGEST`
    6. Assert exit code 0 and TOML verdict == "pass"
    7. Print TOML envelope in job summary

    The EXPECTED_PCR_DIGEST is computed as sha256(PCR0 || PCR7) where PCR0 and PCR7
    are read from the guest during T4/T6 verification (already done).

    Add the A5 job as a separate step or job that depends on T6 passing.
  </action>
  <verify>
    <automated>cat .github/workflows/tpm-vm-test.yml | grep -A 10 "A5"</automated>
  </verify>
  <acceptance_criteria>
    - tpm-vm-test.yml contains an A5 attestation step/job
    - A5 reuses the running guest (no redundant boot)
    - A5 generates fresh nonce per run
    - A5 runs attest-verify.nu and asserts exit 0 + verdict == "pass"
    - A5 prints TOML envelope to job summary
    - A5 fails the workflow if verification fails
  </acceptance_criteria>
  <done>A5 passing: Full quote→verify round-trip green in CI.</done>
</task>

</tasks>

<verification>
1. `nu tests/tpm-attest-verify-test.nu --dry-run` — exits 0 (syntax valid)
2. `nu tests/tpm-attest-verify-test.nu --gate A1` — passes (AK + quote)
3. `nu tests/tpm-attest-verify-test.nu --gate A2` — passes (anti-replay)
4. `nu tests/tpm-attest-verify-test.nu --gate A3` — passes (verifier)
5. `nu tests/tpm-attest-verify-test.nu --gate A4` — passes (TOML envelope)
6. `nu tests/tpm-attest-verify-test.nu --gate A5` — passes (full round-trip)
7. `shellcheck --shell=sh bin/attest-verify.nu` — exits 0 (if script is shell)
   or `nu --no-config-file -c "source bin/attest-verify.nu; help"` — exits 0 (if Nushell)
</verification>

<success_criteria>
- A1: tpm2_createak produces an AK; tpm2_quote succeeds over sha256:0,7
- A2: Quote message contains the supplied nonce; signature verifies with the AK pub
- A3: tpm2_checkquote (or equivalent) validates quote against expected PCR digest
- A4: Verifier writes [attestation] TOML block with verdict, pcr_digest, nonce, ak_fingerprint
- A5: Full quote→verify round-trip green in CI against the smolBSD image
- All acceptance criteria in 04-ACCEPTANCE.md are met
</success_criteria>

<output>
After completion, create .planning/phases/04-remote-attestation/04-01-SUMMARY.md
</output>
