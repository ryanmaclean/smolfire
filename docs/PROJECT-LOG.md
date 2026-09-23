# smolBSD — Project Log

*Distilled from `var/mail/spool` (37 messages, tasks 0001–0014 + design D1–D3).
A cold agent should be able to orient in 5 minutes.*

---

## Original Goal

Build the smallest stable FreeBSD VM that boots unattended to a login prompt in
≤ 30 seconds, fits in 512 MiB on disk (qcow2 target: < 128 MiB), and ships only
`sh`, `vi`/`ed`, `rc.d`, and `pkg`. The secondary goal — equally important — is
to prove that Claude agents can hand off a long-running build project to each other
using only a BSD mbox file + TOML bodies, with no shared conversation history.

---

## Key Decisions and Rationale

### 1. mbox + TOML as coordination substrate (design D1–D3, 2026-04-30)

All inter-agent communication lives in `var/mail/spool`: a single RFC 822 mbox
file committed to the repo. Bodies are `Content-Type: text/toml`. Agents are
addressed as `<role>@smolbsd.local`. The coordinator harvests replies on each
tick and dispatches the next envelope.

Rationale: state survives a fresh clone; no shared memory or session context is
required; the entire project history is auditable in one file.

Side decisions from D1–D3: secrets via 1Password CLI (never written to spool);
retry policy as a state machine (max 3 attempts, 2× backoff); escalation via IRC
DM primary + spool HALT marker fallback.

### 2. aarch64-first (task-0003a REPLAN, 2026-04-30)

Original plan targeted amd64 inside <aarch64-builder>. After verifying that HVF on Apple
Silicon only accelerates a matching-ISA guest, the plan was replanned: aarch64
is the primary leg (native HVF, 10–30s boot), amd64 is the secondary leg (Vultr
KVM, needed because TCG on aarch64 is 5–10x too slow for the 30s gate).

Architecture decision file: `plans/tinyos/PHASE-1-ARCH-DECISION.md`.

### 3. Kernel config strategy

- **amd64**: `include MINIMAL` + strip physical hardware (`sys/amd64/conf/SMOLBSD`).
  Produced by task-0002 (architect + builder authoring chain).
- **arm64**: `include std.arm64` + `include std.virt` + strip physical hardware
  (`sys/arm64/conf/SMOLBSD`). Produced by task-0005. Uses FDT (required for QEMU
  virt machine); ACPI kept for graceful shutdown via EDK2.

### 4. Nushell actor coordinator (task-0006)

`bin/coord-tick.nu` implements the coordinator as a tail-recursive FSM: read
spool → compute next state → append message → repeat. `bin/mbox-parse.nu`
parses mbox + TOML bodies into structured records. Smoke-tested (task-0012):
35 messages parsed, idle quiesces cleanly on Nu 0.111.0.

### 5. Infrastructure drift correction (task-0003b)

The upstream `freebsd-build-vm` skill named the build VM `fb-vm-24` (stale) and
listed SSH port `2225` (stale). Ground truth: VM is `<aarch64-builder>`, port is `2222`.
All smolBSD docs use the correct names. The global skill needs a separate update
PR (flagged but out-of-scope for this repo). Gitea: `<gitea-host>:3001`, not
`gitea.local:3000` (QNAS hosts something else on :3000).

---

## What Was Built

| Artifact | Path | Status |
|----------|------|--------|
| amd64 kernel config | `sys/amd64/conf/SMOLBSD` | Complete |
| arm64 kernel config | `sys/arm64/conf/SMOLBSD` | Complete |
| amd64 QEMU release config | `release/tools/smolfire-qemu.conf` | Complete |
| Coordinator loop | `bin/coord-tick.nu` | Complete, smoke-tested |
| mbox parser | `bin/mbox-parse.nu` | Complete, 6/6 unit tests pass |
| amd64 boot-timing gate | `tests/time-to-ready.exp` | Complete |
| aarch64 boot-timing gate | `tests/time-to-ready-arm64.exp` | Complete |
| Nushell test runner | `tests/run-tests.nu` | Complete (unit + e2e + graceful skip) |
| Design spec | `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md` | v1.2 |
| Phase I aarch64 plan | `plans/tinyos/PHASE-1-AARCH64-TINY-BASELINE.md` | Complete |
| French translations | `README.fr.md`, `PHASE-1-AARCH64-TINY-BASELINE.fr.md`, `mailbox-jec-handoff-design.fr.md` | Complete |
| Japanese translations | `README.ja.md`, `PHASE-1-AARCH64-TINY-BASELINE.ja.md`, `mailbox-jec-handoff-design.ja.md` | Complete |

---

## What Is Running Now (as of 2026-05-04)

Two `buildworld` + `buildkernel` + `make release` pipelines are in flight:

**aarch64 on <aarch64-builder>** (`ssh -J <jump-host> -p 2222 builder@localhost`):
- Screen session: `smolbsd-world` (PID 15999, started 21:01:17 UTC)
- Native arm64 build; no cross-compile flags needed
- Monitor: `screen -r smolbsd-world` or `tail -f /var/tmp/smolbsd-world.log`

**amd64 on Vultr** (`REDACTED-VULTR-IP`, instance `REDACTED-VULTR-UUID-2`):
- Cross-compiled from <aarch64-builder> arm64 host with `TARGET=amd64 TARGET_ARCH=amd64`
- Status: provisioned (attempt 3); buildworld running

---

## What Comes Next

1. **Harvest builds** — when `make release` completes on both legs, collect
   `FreeBSD-15-*.qcow2` artifacts and run `tests/run-tests.nu --suite e2e`.
2. **Timing gate** — boot each qcow2 and verify ≤ 30s to login prompt.
3. **Size gate** — verify disk image ≤ 512 MiB; qcow2 ≤ 128 MiB.
4. **aarch64 release config** — `release/tools/smolfire-qemu-aarch64.conf` is
   defined in `PHASE-1-AARCH64-TINY-BASELINE.md §7.1` but not yet in the main
   tree (exists in worktree `blissful-shockley-eeb73b`); needs merge.
5. **Phase II** — physical boot on Pi 5 / RK3588 (plan in worktree; pending
   Phase I acceptance).
