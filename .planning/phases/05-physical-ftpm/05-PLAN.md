<!-- SPDX-License-Identifier: Apache-2.0 -->
---
phase: 05-physical-ftpm
plan: "01"
type: plan-skeleton
wave: 1
depends_on: [04-remote-attestation]
autonomous: false
requirements: [FTPM-PRESENCE, FTPM-UBUNTU-PROBE, FTPM-UEFI-FREEBSD, FTPM-HW-QUOTE]

must_haves:
  truths:
    - "Phase 4 A1-A5 green (prerequisite, merged PR #59)"
    - "Binaries reused unchanged: bin/guest-attest.nu, bin/attest-verify.nu"
    - "Target host pi501 (10.0.3.11) confirmed online 2026-09-24 — do NOT re-probe"
    - "RP1 fTPM presence itself is UNCONFIRMED until first hardware touch (see P1)"
  artifacts:
    - path: ".planning/phases/05-physical-ftpm/05-CONTEXT.md"
      provides: "Phase 5 decisions + first-touch evidence log"
      contains: "D-01..D-0n, probe transcripts, EK-cert findings"
    - path: ".planning/phases/05-physical-ftpm/05-PLAN.md"
      provides: "This file — expanded from skeleton to executable plan after P1"
      contains: "P1/P2/P3 gates, acceptance criteria, human-physical steps"
  key_links:
    - from: "bin/attest-verify.nu (Phase 4)"
      to: "pi501 hardware quote"
      via: "scp + tpm2_checkquote"
      pattern: "same quote.msg / quote.sig / ak.pub envelope, real EK-backed AK"
---

<objective>
Port the Phase 4 quote→verify protocol (`bin/guest-attest.nu`,
`bin/attest-verify.nu`) from swtpm to the Pi 5 `pi501` hardware TPM
(roadmap: RP1 fTPM via RPi UEFI / edk2-platforms, BSD-2-Clause-Patent —
see ROADMAP.md Phase 5). Prove a real hardware-rooted PCR quote verifies
with the unchanged Phase 4 verifier.

Output of THIS file: skeleton only. Each gate expands into an executable
plan after its prerequisites are met — starting with first hardware touch.
</objective>

<context>
@/Users/studio/smolBSD/.planning/PROJECT.md
@/Users/studio/smolBSD/.planning/ROADMAP.md
@/Users/studio/smolBSD/.planning/STATE.md
@/Users/studio/smolBSD/.planning/phases/04-remote-attestation/04-CONTEXT.md
</context>

<hardware_facts verified="2026-09-24" reprobe="false">
- Host: Pi 5 `pi501` at 10.0.3.11, online.
- OS: Ubuntu aarch64 (Datadog tag `host:ubrpi501`; SSH banner Ubuntu OpenSSH 9.6).
- Monitoring: Datadog-muted.
- Access: NO ssh access available at time of writing. P1 is fully
  remote-capable the moment SSH credentials exist — no reimage, no travel.
</hardware_facts>

<research_notes accessed="2026-09-24" status="aid-only-nothing-confirmed-on-our-hardware">
- RPi UEFI for Pi 5: worproject/rpi5-uefi status table lists UART/SD/USB/PCIe
  as working, FreeBSD 13.2 bootable (Display/UART/USB/SD/PCIe) — but the
  table has NO TPM/fTPM row. TPM support under RPi UEFI: UNCONFIRMED.
  URL: https://github.com/worproject/rpi5-uefi
- FreeBSD on Pi 5 requires the UEFI firmware path (freebsd.org forum thread
  "FreeBSD on the Raspberry PI 5": UEFI v0.3 MUST be used) and is still
  rough — FreeBSD Foundation blog notes Pi 5 support lags Pi 4. Expect P2
  to be the hardest gate. URLs: https://forums.freebsd.org/threads/freebsd-on-the-raspberry-pi-5.90443
- Linux TPM on Pi 5 in the wild is discrete SPI TPM (Infineon SLB9670 /
  LetsTrust overlay + `tcg_tis_spi`), NOT an RP1 firmware TPM:
  raspberrypi/linux#6217 reports "No TPM chip found" for IMA on RPi 5;
  LetsTrust howto documents the SPI-overlay path. Whether ANY TPM
  (`/dev/tpm0`) exists on pi501's current Ubuntu install: UNCONFIRMED —
  that is exactly P1's first probe. URLs: https://github.com/raspberrypi/linux/issues/6217,
  https://letstrust.de/archives/9-Howto-Enable-TPM-Support-on-a-Raspberry-PI-0,-0W,-1,-2,-3,-3b+-and-make-it-work-with-the-LetsTrust-TPM.html
- Roadmap license audit (ROADMAP.md): edk2-platforms BSD-2-Clause-Patent
  and ms-tpm-20-ref / OP-TEE BSD-2-Clause already approved. No new license
  work expected for Phase 5.
</research_notes>

<gates>

<gate id="P1" name="RP1 fTPM presence on current Ubuntu OS">
  <prerequisites>
  - SSH access to pi501 (credential handoff — HUMAN step, remote).
  - Nothing else: no reimage, no physical touch, current Ubuntu install stays.
  </prerequisites>
  <probe_sketch>
  1. `ls -l /dev/tpm0 /dev/tpmrm0; dmesg | grep -i -E 'tpm|rp1'` — does a
     TPM exist at all, and which driver binds it?
  2. `apt list --installed | grep -i tpm; which tpm2_pcrread` — install
     `tpm2-tools` via apt if absent.
  3. `tpm2_pcrread sha256:0,7` (+ `tpm2_getcap properties-fixed` for
     manufacturer/firmware version) — record raw output into 05-CONTEXT.md.
  </probe_sketch>
  <acceptance_sketch>
  - PASS-A (fTPM present): `/dev/tpm0` exists, PCRs readable, manufacturer
    ID recorded → P2/P3 unblocked, plan expands to executable.
  - PASS-B (no TPM): documented negative (`dmesg` + kernel version +
    device-tree excerpt) → decision point: SPI TPM HAT, kernel/overlay
    change, or UEFI-exposed fTPM in P2. A negative probe is still a
    completed P1 — record, do not thrash.
  </acceptance_sketch>
  <human_physical>HUMAN-REMOTE (not physical): SSH credential handoff only.</human_physical>
</gate>

<gate id="P2" name="FreeBSD-on-Pi5 path via RPi UEFI / edk2">
  <prerequisites>
  - P1 evidence (know whether UEFI must also expose the TPM or just boot FreeBSD).
  - RPi UEFI firmware image (worproject/rpi5-uefi) staged somewhere scp-able.
  </prerequisites>
  <acceptance_sketch>
  - FreeBSD aarch64 boots on pi501 under RPi UEFI (serial or HDMI console
    shows loader → kernel), version recorded.
  - TPM visibility from FreeBSD noted (present/absent — absence does not
    fail P2, it scopes P3).
  </acceptance_sketch>
  <human_physical>
  HUMAN-PHYSICAL — flagged as OPEN QUESTIONS, not assertions:
  - Q-P2.1: Does flashing RPi UEFI require pulling the SD card (SD imaging
    on a laptop) or can it be staged remotely?
  - Q-P2.2: Is there a serial console available (PL011 on dedicated
    connector @115200 8n1 per rpi5-uefi docs), or only HDMI/keyboard?
  - Q-P2.3: Current bootloader on pi501 (EEPROM + boot chain) — unknown
    until first touch; UEFI vs network-boot decision deferred to evidence.
  </human_physical>
</gate>

<gate id="P3" name="Hardware-quote attestation round-trip with Phase 4 verifier">
  <prerequisites>
  - Whichever OS (Ubuntu and/or FreeBSD) exposes the TPM after P1/P2.
  - `bin/guest-attest.nu` + `bin/attest-verify.nu` reused UNCHANGED
    (port failures are evidence, not a license to fork the protocol).
  </prerequisites>
  <acceptance_sketch>
  - AK created on the HARDWARE TPM, `tpm2_quote -l sha256:0,7` with fresh
    nonce, quote artifacts scp'd off pi501.
  - Unchanged `bin/attest-verify.nu` returns exit 0 + TOML `verdict = "pass"`.
  - NEW trust question Phase 4 never had: the AK chains to a REAL
    manufacturer EK. `tpm2_getekcertificate` / EK-cert presence recorded;
    EK-cert chain validation and Privacy-CA scope are explicitly DEFERRED
    decisions (recorded open, not silently skipped): without EK validation
    the quote proves "a TPM" not "this Pi's TPM".
  </acceptance_sketch>
  <human_physical>None expected beyond P1/P2 access — remote-capable once the OS exposes the TPM.</human_physical>
</gate>

</gates>

<open_questions_requiring_first_hardware_touch>
- OQ-1: SSH access details (user, key, bastion/jump requirements) — blocks P1 start.
- OQ-2: Current bootloader chain on pi501 (EEPROM version, config.txt / boot order) — scopes P2.
- OQ-3: Kernel driver state (`uname -r`, `dmesg` TPM lines, device tree) — P1 probe target.
- OQ-4: EK certificate presence (`tpm2_getekcertificate` output) — P3 trust scope.
- OQ-5: Serial console availability (PL011 connector wired?) — determines whether P2 is debuggable remotely.
- OQ-6: RP1 fTPM itself — roadmap asserts it, public research finds only
  discrete-SPI-TPM evidence on Pi 5; treat as UNCONFIRMED until P1 probe.
</open_questions_requiring_first_hardware_touch>

<non_goals>
- RK3588 / OP-TEE fTPM TA: no hardware on hand — stays a roadmap line item,
  not this phase's work.
- ASIC / FPGA measured-boot ladder (SuperStation / MiSTer paths in
  docs/SUPERSTATION-PRE-ASIC-PLAN.md): separate track, not gated by this plan.
- Forking or redesigning the Phase 4 quote→verify protocol: reuse is the test.
</non_goals>

<success_criteria>
- P1: probe transcript committed to 05-CONTEXT.md (present OR documented-absent).
- P2: FreeBSD boot evidence recorded; physical-access questions answered, not guessed.
- P3: hardware quote verifies with unchanged Phase 4 verifier; EK-cert
  validation scope decision recorded (done or deferred-with-reason).
- This skeleton expanded into an executable 05-PLAN.md once P1 evidence lands.
</success_criteria>

<output>
After P1 first touch, create .planning/phases/05-physical-ftpm/05-CONTEXT.md
(D-01 onwards) and expand this skeleton into executable tasks.
</output>
