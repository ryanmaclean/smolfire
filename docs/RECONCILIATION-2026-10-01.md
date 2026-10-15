# Reconciliation Status — 2026-10-01

Re-audit of the "what the code actually does" table in
`docs/RECONCILIATION-2026-05-16.md` (section 2) against the current
`bin/coord-*.nu` on the 0.6.0 branch. The old report is left untouched as a
historical record. Spec: `docs/superpowers/specs/2026-04-30-mailbox-jec-handoff-design.md`.

Scope note: only the spec-vs-code table is re-audited here. The old report's
translation-drift, stale-docs, CLAUDE.md-freshness and branch-model sections
are not re-audited by this pass.

Line references are to `bin/coord-tick.nu` unless noted, and drift as the
file changes: search for the named function instead.

## Status table

| Spec promise | 2026-05-16 | 2026-10-01 | Evidence / what changed |
|---|---|---|---|
| §2 Single spool, coordinator appends, subagents append | DONE | **DONE** | Unchanged: dispatch/escalation append via `save --append`; `coord-dispatch.nu`, `coord-fleet-dispatch.nu` workers append their replies. State persistence is now crash-atomic (`save-state`, temp file + same-dir rename). |
| §4 Envelope schema fields | PARTIAL | **PARTIAL** | Dispatch envelopes (`state-dispatching`) carry `task_id`, `action`, `executor` and, for retries, the §12 retry payload (new, see below). Still no `[brief]`, `[context_pointers]`, `[acceptance]`, `[reply_contract]` blocks; the worker prompt is built in `spawn-subagent`, not in the envelope. Needs a design decision on what the coordinator may know about a task (see Deferred). |
| §5 RTK `X-JEC-Compression` header | MISSING | **MISSING (deferred)** | `grep -rn "rtk\|X-JEC-Compression" bin/` finds nothing relevant. No `rtk` binary exists in this repo. |
| §6 N-parallel dispatch | PARTIAL | **DONE (bounded)** | Superseded by concurrent pending slots (`pending_slots`, slots == caps: fleet 2, jail 2, vm 4, global cap 8) and one detached worker spawn per slot-fill. The old "one dispatch per tick, break" gate only remains as the `SMOLFIRE_CONCURRENT=0` kill-switch. Not unbounded N by design (backpressure caps). |
| §7 `fleet-eval` cross-check of claims | MISSING | **MISSING (deferred)** | Claims are still checked for presence only (`attestation_required` with no `[[claims]]` => malformed). No `fleet-eval` subprocess exists anywhere in `bin/`. |
| §11 secret-materialize / secret-wipe | DONE | **DONE** | `bin/secret-materialize.nu`, `bin/secret-wipe.nu` present. |
| §12 Retry state machine / decision table | PARTIAL | **DONE (this pass)** for the table + backoff + payload; `pass+probe-failed` and `no-reply` budget doubling remain open | D2 table unchanged and correct. NEW: Fibonacci backoff `[60, 60, 120]` is now scheduled (see below). NEW: retry envelopes carry `prior_attempt_msgid`, `prior_attempt_count`, `format_violation`. Still not implemented: `prior_attempt_failure`, `probe_disagreement` (needs `fleet-eval`), `budget_tokens` doubling for `no-reply`, the spec's 30 min no-reply timeout (code uses 300 s per-slot timeout), per-retry Message-ID shape `<task-XXX.coord.rN@...>` (code uses `<coord.<tick>.r<N>.<ts>.<executor>.<idx>@...>`). |
| §12 No-double-dispatch invariant | MISSING | **DONE** | Commit `3ba774b`: `find-inflight-dispatch`, run once per slot-fill in `state-dispatching`, plus same-task-never-twice in harvest (`dispatch_skipped_duplicate_task`). Covered by `tests/coord-double-dispatch-test.nu` and `tests/coord-concurrent-pendings-test.nu`. |
| §13 IRC DM fallback | DONE | **DONE** | `try-irc-dm` in `coord-tick.nu`; host from `SMOLFIRE_IRC_HOST` (unset => inert `no-route`). `coord-escalate.nu` now has the same helper. |
| §13 `fallback_fired` / `fallback_status` in HALT marker | DONE (tick) / divergent (escalate) | **DONE in both (this pass)** | `coord-escalate.nu` now writes the full `write-halt-marker` field set plus `fallback_fired`/`fallback_status` (and legacy `escalated_at`). The known-gap note in `tests/coord-escalate-test.nu` is gone and the test now asserts the fields. Caveat: `coord-tick.nu` still writes the two fields in a second pass (`try-irc-dm` re-opens the marker), `coord-escalate.nu` writes them in one pass; same resulting record. |
| §13 Triple-failure path, exit 78 | MISSING | **DONE in `coord-escalate.nu` (this pass)** | Spool append fails AND IRC unreachable AND HALT write fails => `{"event":"smolbsd-coord-panic",...}` JSON on stderr, exit 78. Partial failure exits 1 with no panic JSON. `coord-tick.nu`'s own HALT path (`write-halt-marker`/`append-halt-message`) does not have a panic path; it is not routed through `coord-escalate.nu`. See Risks. |
| §17 `tools_required` pre-flight | DONE | **DONE** | `AGENT_CAPABILITIES` check in `state-harvesting` logs `dispatch_capability_mismatch` and marks the message seen (routing rejection, not a retry). |

New since the old report (not in its table, now covered): crash-safe atomic
state, max-inflight backpressure, worker heartbeat + dead-worker reap-to-retry,
concurrent pending slots, fleet executor.

## Implemented in this pass

1. **Fibonacci backoff (§12).** The harvest retry stamp sets `not_before`
   (RFC 3339 UTC) in the pending slot, `now + [60, 60, 120][min(attempts-1, 2)]`
   seconds. Nothing sleeps. `state-dispatching` sends only due slots; if only
   held slots remain it parks in `idle` with transition reason
   `retry-backoff`; `tick` wakes `idle`/`waiting` into `dispatching` with
   reason `retry-due` once a held slot is due. The schedule lives in the slot
   inside the one crash-atomic state record, so a crash/restart resumes the
   same schedule and the §12 no-double-dispatch guard still applies. An
   unparseable `not_before` fails open (due). The escalation path is not
   delayed. Because D2 allows retries only while attempts < 3, the delays
   actually used are 60 s and 60 s; the 120 s entry is reachable only if the
   attempt budget is raised. Kill-switch: `SMOLFIRE_RETRY_BACKOFF=0` restores
   immediate retry dispatch.
2. **Retry payload (§12).** Retry dispatch envelopes carry
   `prior_attempt_msgid` (the failed reply's Message-ID; for timeout/reap
   retries, the synthetic reply's id), `prior_attempt_count` (attempts made so
   far), and `format_violation` (only when the category is `malformed`). The
   fields travel in the slot and are cleared once sent.
3. **Exit 78 triple-failure (§13)** in `coord-escalate.nu`.
4. **HALT marker parity (§13)** in `coord-escalate.nu`.

Tests: `tests/coord-retry-backoff-test.nu` (new, subprocess-level),
`tests/coord-escalate-test.nu` (parity, exit 78, partial failure),
`tests/coord-fsm-tests.nu` (closed enumeration extended with `retry-backoff`,
`retry-due`). Existing retry-path suites (`coord-tick-test`, `coord-heartbeat-test`,
`coord-concurrent-pendings-test`, `coord-fsm-tests`) pin
`SMOLFIRE_RETRY_BACKOFF=0` because they exercise the D2 table and slot
mechanics, not scheduling, so their run-to-run determinism checks are
unchanged.

## Deferred (no tool or decision available in this repo)

- **RTK compression (§5).** Design question: the spec assumes an `rtk`
  tool that compresses command output before it is inlined into `[brief]`
  with an `X-JEC-Compression: rtk-v1` header, but no such binary exists and
  nothing in the repo produces or consumes compressed output. Should the
  coordinator own compression (a new Nushell step that summarizes tool output
  with a defined, lossless-or-bounded format), should it be delegated to the
  worker side, or should §5 be struck from the spec as future work? That
  decision also fixes whether dispatch envelopes grow a `[brief]` block at
  all (§4 gap).
- **`fleet-eval` claim verification (§7, plus `pass+probe-failed` and
  `probe_disagreement` in §12).** Design question: the spec has the
  coordinator re-probe every `[[claims]]` entry through `fleet-eval verify`
  and treat probe failure or inconclusive results as `pass+probe-failed` with
  a single retry, but no `fleet-eval` exists. What is a claim's probe
  language (a command run on the worker, an artifact hash, a spool-visible
  check), who is trusted to run it (the coordinator host versus the same
  executor that produced the claim), and what is the inconclusive policy
  (SSH timeout) given that today the only check is presence of a `[[claims]]`
  block?

## Risks / things to know

- The retry reply is only marked seen when the slot is stamped, so the
  backoff window relies on the stamped slot (not the spool) as the durable
  record; hand-clearing `pending_slots` in the state file during a backoff
  window drops that retry.
- `coord-tick.nu`'s own halt path has no panic/exit-78 path; routing it
  through `coord-escalate.nu` is an architecture decision left open.
- Pre-existing on this host, unrelated to this pass: the fleet-stub tests in
  `tests/coord-concurrent-pendings-test.nu` (cases 1, 10, 12) are
  timing dependent (suspected cause: the stub fleet worker answers before the
  tick ends, not confirmed); case 10 passes and fails intermittently on the
  base commit as well, and case 1 failed deterministically there.
