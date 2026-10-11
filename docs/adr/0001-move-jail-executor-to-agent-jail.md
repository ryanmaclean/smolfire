# ADR 0001: Move the jail executor to `agent-jail`; keep a thin adapter in smolfire

## Status

Accepted ownership decision. Agent-jail PR #3 and the paired smolfire adapter
are still draft migration work; implementation is not complete until both land
with a pinned agent-jail install artifact. Tracking issue: `ryanmaclean/agent-jail#2`.

## Context

`ryanmaclean/skills/docs/PROJECTS.md` states the cross-project ownership
rule:

> jail isolation -> agent-jail

`agent-jail/.project.toml` already declares
`canonical_for = ["bsd-jail-agent-isolation"]`, and its `AGENTS.md` lists
"jail isolation" and "jail lifecycle" under **Owns**.

Before the paired migration, the jail executor was implemented in this repo
(`smolfire`):

- `bin/jail-execute.nu` — `run-jail-task`, sibling of `bin/vm-execute.nu`,
  same `{verdict, boot_sec, outputs, error?}` contract
- `tests/jail-execute-test.nu` — host-independent tests, stubs the
  FreeBSD tools on `PATH`
- `docs/JAIL-EXECUTOR.md` — contract, backends (`--base` nullfs,
  `--zfs-snapshot` clone, `--image` ocijail), hardening (per-task salted
  naming, network off by default, rctl limits, bounded timeout, ordered
  teardown), enabling via `SMOLFIRE_EXECUTOR=jail`
- `bin/coord-tick.nu`'s `resolve-executor` picks `jail` per request and
  spawns `jail-execute.nu dispatch`

This is a duplicate-ownership situation under
`ryanmaclean/skills/docs/CONSTRAINTS.md`:

- **C1** — one primitive, one canonical owner. The registry already names
  `agent-jail` as that owner for jail isolation; smolfire holding the
  implementation is the second source of truth C1 warns against.
- **C20** — a proposal that adds/keeps a layer must state what invariant it
  uniquely owns and what layer disappears. smolfire's coordinator uniquely
  owns *executor routing/policy* (which task uses which executor); it does
  not need to uniquely own *jail lifecycle mechanics* (create, harden, run,
  teardown a jail), which duplicates what `agent-jail` is chartered to own.

## Decision

Ownership ruling (jev, 2026-09-23, Q10, confidence 0.86): **move the jail
executor to `agent-jail`; smolfire keeps a thin adapter.**

- `agent-jail` becomes the canonical implementation of jail lifecycle
  (create/harden/run/teardown across the `--base`/`--zfs-snapshot`/`--image`
  backends), preserving the existing `run-jail-task` contract
  (`{verdict, boot_sec, outputs, error?}`) so callers do not need to change
  result parsing.
- `smolfire` keeps `bin/coord-tick.nu`'s `resolve-executor` policy (routing:
  which request gets `vm` vs `jail`) and replaces `bin/jail-execute.nu`'s
  implementation with a thin adapter that calls out to `agent-jail`'s
  executor and translates the result into smolfire's existing dispatch
  envelope and state-file shape
  (`task_executors.<task_id> = {executor, network, request_id}`).
- The lifecycle tests in `tests/jail-execute-test.nu` move to
  `agent-jail` (same FreeBSD-tool stubbing approach); smolfire keeps a
  smaller test that the adapter forwards/translates correctly.
- `docs/JAIL-EXECUTOR.md` becomes canonical in `agent-jail`; smolfire's copy
  becomes a pointer stub.
- This repo's `.project.toml` `do_not_implement` and `AGENTS.md` "Do not
  duplicate" are updated in this PR to record `bsd-jail-agent-isolation` /
  jail isolation as owned elsewhere, so future proposals in this repo don't
  re-introduce a second jail-lifecycle implementation.

Full migration shape and sequencing are tracked in
`ryanmaclean/agent-jail#2`. The paired source candidate removes smolfire's
lifecycle copy, but the installed artifact and native acceptance remain open;
the ownership transfer is not complete merely because these files change.

## Alternatives considered

**Keep the jail executor in smolfire.** Rejected: contradicts the existing,
already-published registry ownership rule ("jail isolation -> agent-jail")
and `agent-jail`'s own `.project.toml`/`AGENTS.md`, without new evidence
that would justify revisiting that rule (per `CONSTRAINTS.md`'s guidance not
to re-open settled ownership casually). It would also leave `agent-jail`
(status: experimental) without the one thing its `.project.toml` says it
canonically owns.

## Consequences

- Positive: single canonical owner for jail lifecycle; `agent-jail` gains
  the implementation its charter already claims; smolfire's coordinator
  stays focused on routing/policy (dispatch, retries, executor selection)
  rather than jail mechanics.
- Cost: a coordinated first-party source transfer, lifecycle-test ownership,
  smolfire adapter, pinned install artifact, and native verification are
  required before this ADR's decision is fully realized. The paired smolfire
  change deletes `bin/jail-execute.nu` and adds `bin/coord-jail-dispatch.nu`;
  neither PR should be merged until both are reviewed against exact heads.
- Follow-up: `ryanmaclean/agent-jail#2` tracks the migration. Once the
  artifact pin, native gate, and paired merge complete, mark this ADR
  Implemented and remove the draft caveat above.

## References

- `ryanmaclean/skills/docs/PROJECTS.md` (ownership table)
- `ryanmaclean/skills/docs/CONSTRAINTS.md` (C1, C20, C27)
- `ryanmaclean/agent-jail/.project.toml`, `AGENTS.md`
- `docs/JAIL-EXECUTOR.md` (this repo)
- Migration-plan issue: `ryanmaclean/agent-jail#2`

🤖 Generated with [Claude Code](https://claude.com/claude-code)
