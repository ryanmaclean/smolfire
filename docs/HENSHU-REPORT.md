# Henshu Report — 2026-05-04

Editorial pass covering: reality reconciliation, narrative distillation,
i18n review, README polish, orphan detection.

---

## FIXED

### Task 1 — Reality Reconciliation

No stale hostnames or port numbers were found in active document prose.
All `fb-vm-24` and `2225` references in docs are correctly framed as
"stale skill name" with `<aarch64-builder>`/`2222` as the current truth. The design
spec §18 and all plan files already document the drift accurately.

The `gitea.local:3000` reference at `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md:223` is inside a TOML
code block labeled `scope = ["gitea.local:3000/api/v1/repos/*"]` and is
marked as `# advisory` — it is an example pattern, not a live URL. It is
also noted in §18.6 that the actual Gitea is `<gitea-host>:3001`. No change
needed there.

The `include MINIMAL` references in `sys/amd64/conf/SMOLBSD` and
`plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md` are correct for the amd64
kernel; `MINIMAL` is the proper FreeBSD amd64 base config. The aarch64
kernel correctly uses `std.arm64` + `std.virt` (not `MINIMAL`). This is
consistent with the task description's ground truth.

The `task-0001.architect` and `task-0002.builder` Message-IDs in
`sys/amd64/conf/SMOLBSD` and `tests/time-to-ready.exp` are authoring
provenance comments, not active references — no change needed.

No inline edits were required for Task 1.

### Task 2 — Narrative Distillation

**Created** `docs/PROJECT-LOG.md` — narrative arc of the project from
original goal through current state (two builds in flight).

### Task 3 — i18n Editorial Pass

**Fixed** `README.fr.md` line 50: `jj describe -m "votre message"` →
`jj describe -m "your message"`. The `-m` argument is a shell command
argument and must not be translated; only the comment was translated.

**Fixed** `README.ja.md` line 45: `jj describe -m "メッセージ"` →
`jj describe -m "your message"`. Same issue.

All other code blocks, paths, commands, and TOML content in all six
translated files were verified to be identical to the English originals.

### Task 4 — Front Door Polish

**Updated** `README.md`:
- Added "Current Status" section at top showing two in-flight builds with
  timestamps and instance IDs.
- Updated the amd64 section to include the Vultr IP.
- Expanded "Run acceptance tests" to show all three test invocations
  (aarch64 expect, amd64 expect, Nu runner).
- Updated "Project Layout" to include all tracked files:
  `release/tools/`, `sys/amd64/conf/`, `sys/arm64/conf/`,
  `tests/time-to-ready-arm64.exp`, `tests/run-tests.nu`.

---

## FLAGGED (needs human review)

### F-1: `jj describe -m "your message"` comment was translated in README.fr.md

The French README translated the jj command *comment* (`# update working-copy
description` → `# mettre à jour la description de la copie de travail`) which is
correct and desirable. However the argument `"your message"` was also translated
to `"votre message"` — this is a command literal and should remain English.
**Fixed inline.** Flagging for native-speaker confirmation that the English
literal is acceptable in a French-language document (it is idiomatic for CLI docs
to leave argument placeholders in English, but a native speaker may prefer
`"votre-message"` as a no-spaces placeholder instead).

### F-2: `release/tools/smolfire-qemu-aarch64.conf` missing from main tree

The file is defined in `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md §7.1`
and exists in worktree `blissful-shockley-eeb73b`. It has not been merged to
the main tree. The aarch64 build pipeline (task-0014) is in flight without it.
Recommend merging the worktree branch or cherry-picking the file before the
build harvest.

### F-3: `freebsd-build-vm` global skill is stale

`/Users/studio/.claude/skills/freebsd-build-vm/SKILL.md` still uses `fb-vm-24`
and port `2225`. This is documented in smolBSD spec §18 and in the plans, but
any agent that reads the skill cold will get wrong values. Needs a separate PR
to the skills repo. Out of scope for smolBSD but blocking for any future agent
that uses the skill.

### F-4: `plans/tinyos/PHASE-1-FORGE-TINY-BASELINE.md` superseded but not archived

This is the original amd64-first Phase I plan, superseded by the REPLAN that made
aarch64 primary (`PHASE-1-ARCH-DECISION.md` + `PHASE-1-AARCH64-TINY-BASELINE.md`).
The file is not wrong — it remains the authoritative amd64 leg design — but its
header still says "Status: design-complete — DO NOT BUILD until this file is
accepted" with no note that the REPLAN changed its scope to secondary. Consider
adding a one-line note at the top: `# Scope: amd64 secondary leg (see PHASE-1-ARCH-DECISION.md for REPLAN).`

### F-5: `plans/tinyos/PHASE-2-PHYSICAL-BOOT.md` in worktree only

The Phase 2 plan exists in `blissful-shockley-eeb73b` but not in the main tree.
This is intentional (work-in-progress) but worth noting for the next merge pass.

### F-6: Vultr amd64 buildworld status unknown

Task-0008 had three provisioning attempts. The spool shows "provisioned (attempt
3)" but no completion reply for the build itself. The build may still be running
or may have silently failed. Recommend a manual status check:
`ssh <vultr-ip> 'tail -30 /var/tmp/smolbsd-world.log'`.

### F-7: `docs/superpowers/specs/` path is unconventional

The spec lives at `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md`.
The `superpowers/` subdirectory is a vestige of the superpowers skill scaffolding
and is not meaningful for smolBSD. Consider relocating to `docs/specs/` in a
future clean-up pass. Not changed here to avoid breaking spool references.

---

## DEFERRED

### D-1: i18n prose quality for `PHASE-1-AARCH64-TINY-BASELINE.fr.md` and `.ja.md`

The translations are structurally accurate. Some technical calques are present in
the French file (e.g., "Forge de la Référence Minimale" for "Forge Tiny Baseline"
is literal but not how a French engineer would naturally phrase a phase name).
These are style questions, not correctness issues. Deferred pending native-speaker
review; no change made.

### D-2: `plans/tinyos/PHASE-1-ARCH-DECISION.md` — historical decision record

This file documents the amd64→aarch64 REPLAN reasoning. It is accurate and
complete as a decision record. No changes needed. Left as-is.

### D-3: `var/mail/spool` — per task instructions, immutable audit trail

Not modified. Skipped in all grep analysis.

### D-4: `bin/coord-tick.nu` and `bin/mbox-parse.nu` — code not reviewed

Henshu does not review code correctness. The smoke test (task-0012) verified
basic operation. Any code bugs are out of scope; flag via a separate code-review
pass.

### D-5: worktree `blissful-shockley-eeb73b`

The `.claude/worktrees/blissful-shockley-eeb73b/` tree is a live jj worktree
with additional files (`PHASE-2-PHYSICAL-BOOT.md`, `smolfire-qemu-aarch64.conf`,
`docs/fr/PHASE-1-OVERVIEW.md`, `docs/ja/PHASE-1-OVERVIEW.md`). These are
work-in-progress and not yet in the main tree. Noted; not modified.
