<!-- SPDX-License-Identifier: Apache-2.0 -->
# Concurrent pendings design (per-executor slots)

Status: **design only — no code.** Implements TRIZ #5 Segmentation:
pendings segmented per executor; the S-012 no-double-dispatch guard is
EXTENDED, not removed. Gastown parity goal: fleet cap (2) reachable via
parallel slots instead of today's hard concurrency-1.

## 1. Current single-pending flow (with refs)

One `nu bin/coord-tick.nu` invocation = one tick; `tick` recurses through
several FSM transitions in memory but `save-state` runs exactly once at the
end (`bin/coord-tick.nu:1604-1607`). State shape in `default-state`
(`bin/coord-tick.nu:75-96`): scalar `pending_request_id` (:82),
`pending_task_id` (:83), `pending_to_addr` (:84), `dispatched_at` (:85).

Flow per task:

1. `state-harvesting` (`:980-1262`) scans the spool. A fail/blocked reply
   with attempts < 3 takes the retry path (`:1107-1135`), stamping the
   scalars (`:1123-1128`); an unmatched outbound request takes the
   new-request path (`:1225-1231`), stamping the same scalars plus
   `task_executors`.
2. `state-dispatching` (`:1398-1499`) appends one mbox message, occupies one
   `inflight` slot keyed by task_id (`:1468`), spawns exactly one worker
   (jail `:1470-1473`, fleet `:1474-1482`, vm `:1483-1488`), then OVERWRITES
   `pending_request_id` with the new dispatch Message-ID (`:1493-1498`).
3. `state-waiting` (`:1266-1341`) matches replies by a single predicate:
   `In-Reply-To == pending_request_id` (`:1276-1283`). On match it clears
   all three scalars (`:1300-1304`) and recurses to harvesting; the 300 s
   timeout path (`:1309-1335`) injects a synthetic fail the same way.
4. `state-harvesting` classifies the reply via the D2 table (`:1075-1080`):
   accept releases the slot + clears attempts/executor record (`:1096-1102`);
   HALT releases the slot and appends to `halted_tasks` (`:1147-1152`).

Lines that enforce singularity (all must change; nothing else may assume
scalar pendings):

- `default-state` scalars (`:82-85`) — one task's worth of fields exist.
- Harvest "first one wins": `if $has_dispatch { break }` (`:1004`) plus the
  `has_dispatch` gate on the harvesting→dispatching transition (`:1248`) —
  at most one dispatch target per tick.
- `state-waiting` matches exactly one `pending_request_id` (`:1276-1283`)
  and blanks the scalars on receipt (`:1300-1304`) — a second outstanding
  dispatch is invisible until the first resolves (proven live: 5-task drain
  went sequential).
- `prune-inflight` exempts exactly one task (`:554,557-560`) and
  `sweep-dead-workers` excludes exactly one pending (`:721,735`).
- The S-012 crash-recovery guard `find-inflight-dispatch` (`:1362-1394`,
  commit `3ba774b`) takes a single `pending_request_id` and
  `state-dispatching` consults it once (`:1399`).

## 2. Proposed: executor-keyed pending slots

```toml
[pending_slots.vm]    task_id = "t-1"  request_id = "<coord…>"  dispatched_at = "…"
[pending_slots.jail]  task_id = ""     request_id = ""          dispatched_at = ""
[pending_slots.fleet] task_id = "t-7"  request_id = "<coord…>"  dispatched_at = "…"
```

Choice justified: **executor-keyed record slots, NOT a task→executor map.**
Caps (`MAX_INFLIGHT_PER_EXECUTOR`, `:67`), heartbeat attribution
(`resolve-task-executor`, `:650-656`), and all three spawn paths
(`:772,794,825`) are already keyed by executor string, so a slot table keyed
the same way plugs into every existing gate without translation. A
task→executor map answers "where is T?" but cannot express "vm slot full,
fleet slot free", which is the scheduling question. Cost: unknown executors
fall back to the global cap only (existing `cap-for-executor` rule, `:462`),
so unknown-executor tasks never occupy a named slot — they queue until a
known slot frees. Slot count is fixed (one per known executor); raising the
fleet cap to N later means N slots per executor, a mechanical extension.

Per-executor waiting/harvest matching (reply→slot correlation):

- `state-waiting` iterates slots, not scalars: for each occupied slot, match
  `In-Reply-To == slot.request_id`. First match clears THAT slot and routes
  to harvesting with the slot's task context. Timeout injection (`:1309+`)
  becomes per-slot (each slot carries its own `dispatched_at`).
- Harvest's accept/retry/HALT paths already operate on the reply's `task_id`
  (`:1092-1153`); they release the slot whose `task_id` equals the reply's
  (slot lookup by task, not by scalar) and clear only that slot.
- New-request dispatch fills a FREE slot whose executor equals the resolved
  executor (`resolve-executor`, `:411-433`); retry dispatch reuses the slot
  of the reply's recorded executor. The `has_dispatch` break (`:1004`)
  becomes "one dispatch per free slot per tick" (bounded by free slots).

Extended no-double-dispatch guard (S-012 survives, per slot):

- Enqueue-time: `find-inflight-dispatch` keeps its signature but is called
  once PER slot-fill with that slot's `request_id`; a re-derived request
  with an outstanding unanswered dispatch resumes that dispatch's id
  (`:1400-1413` shape, slot-scoped) instead of appending.
- Harvest-time: before stamping a slot, assert no OTHER occupied slot holds
  the same `task_id` — same-task-in-two-slots is refused (logged
  `dispatch_skipped_duplicate_task`, trigger stays unseen, like
  backpressure deferral `:1209-1217`).
- Crash-recovery scan covers all slots: on tick entry after `load-state`,
  run the spool scan for every occupied slot's `request_id`; any slot whose
  dispatch is present-but-unanswered resumes waiting, any slot whose
  dispatch is answered routes to harvesting. Same idempotence argument as
  `3ba774b`, generalized from 1 to N.

## 3. Interplay per feature

- S-002 halt: halt is per-task, unchanged. A HALT verdict clears only that
  task's slot (`:1147-1152` shape) and appends `halted_tasks`; other slots
  keep draining. `dispatch_skipped_halted` (`:1160-1164`) and the
  prune/sweep halted exclusions (`:566,735`) apply per slot-task.
- S-003 budgets: `attempt_counts` stays per-task (`:86`), D2 table
  (`:1075-1080`) unchanged — attempts increment per reply regardless of
  which slot carried the dispatch. Slots hold no budget state.
- Rate-limit caps: per-executor counting already exists (`inflight-counts`
  `:489-499`, `inflight-status` `:504-516`). Rule: slots ≤ caps ALWAYS —
  a slot may only fill when `inflight-status` for that executor is under
  cap. Slots are the waiting-room chairs, caps are the fire code; chairs
  never exceed code. The dispatch backstop (`:1429-1440`) becomes per-slot
  (un-mark only that slot's trigger).
- Heartbeat reap: `record-heartbeat` (`:660-668`) fires per slot-task on
  that slot's round trip; `sweep-dead-workers` (`:715-767`) keeps its shape
  but the pending exemption (`:735`) becomes "any task in any occupied
  slot" — the 300 s per-slot timeout path owns those instead.
- S-006 atomicity: `pending_slots` lives in the same state record as
  `inflight`, covered by atomic `save-state` (`:157-170`) and fail-closed
  `load-state` (`:110-141`). One save per tick still; slot table torn-write
  protection is inherited, not re-implemented.
- Fleet roles: `resolve-executor` (`:411-433`) unchanged; role-routed fleet
  work fills the fleet slot. Fleet cap 2 with 1 slot means the second
  permit still queues — slot count per executor must eventually equal its
  cap (see §6).
- Spawn paths: one spawn per slot-fill, same argv-only convention
  (`:769-807`); `SMOLFIRE_SPAWN_SUBAGENT` kill switch (`:826-834`)
  gates all slots at once.

## 4. Migration + rollback

Migration (single `pending_task_id` → slots):

1. `load-state` backfill: if `pending_task_id != ""` and `pending_slots`
   absent, map the legacy triple onto the slot of the task's recorded
   executor (`task_executors[task].executor`, else `vm`), then blank the
   legacy keys. Old state files resume waiting on the same dispatch —
   no re-dispatch, no S-012 violation.
2. `save-state` writes slots only; legacy keys are dropped after one
   successful slotted save (two-release removal: read-compat now,
   write-clean next).
3. Mixed-version risk is nil (single coordinator binary per root), but the
   backfill is idempotent anyway — re-running it on slotted state is a no-op.

Rollback: env kill-switch `SMOLFIRE_CONCURRENT=0` restores single-pending:
harvest fills at most one slot per tick (the `has_dispatch` break, `:1004`),
waiting matches the lowest-executor-name occupied slot first, extra slots
drain without refill. Default is ON once implemented; the switch exists for
one release, then is removed with the legacy keys.

## 5. NON-goals + rejection log

- NON-goal: raising caps (vm 4 / jail 2 / fleet 2 / global 8 stay fixed).
- NON-goal: multi-slot-per-executor (fleet cap 2 served by 1 slot + queue;
  N-slots-per-executor is the follow-up, not this phase).
- NON-goal: changing the D2 retry table, HALT format, telemetry schema, or
  the 300 s timeout value.
- Rejected: global pending pool (one shared queue across executors) — loses
  the executor→cap→heartbeat keying every gate already uses; rejected.
- Rejected: thread-per-task (concurrent tick processes) — breaks the
  one-save-per-tick atomicity (`:1607`) that S-006 depends on; rejected.
- Rejected: removing the S-012 guard because "slots make it unlikely" —
  slots make double-dispatch MORE likely (N outstanding requests, same
  crash window); the guard is extended, never removed; rejected.

## 6. Acceptance criteria (implementation phase)

1. Two-executor parallel green path: vm + fleet requests dispatched in one
   tick, both replies harvested, both slots empty, suite green.
2. Same-task-never-twice under crash injection: kill -9 between spool
   append and save with 2 slots occupied; restart appends zero bytes
   (spool byte-identical) and resumes both slots (extends
   `tests/coord-double-dispatch-test.nu`).
3. Halt interplay: HALT on slot A's task clears only slot A; slot B drains
   to accept in the same run.
4. Retry/budget: fail×2 then pass on one slot retried through the same slot;
   attempts == 3 escalates and frees the slot (extends
   `tests/coord-ratelimit-test.nu` + `tests/coord-heartbeat-test.nu`).
5. Heartbeat: dead fleet worker reaps only its slot's tasks to synthetic
   fail; other slots untouched; resurrection clears on next round trip.
6. Back-compat: legacy state file with scalar pending loads, backfills,
   resumes; `SMOLFIRE_CONCURRENT=0` restores sequential drain.
7. Full suite (`tests/run-all.sh`) green, including `no-new-python-test`
   (new tests in Nushell).
