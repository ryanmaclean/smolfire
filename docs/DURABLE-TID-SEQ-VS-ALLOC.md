# Caller-supplied sequence vs hardware-allocated TID (#89)

Question from #89: can TID allocation be removed from hardware?

Short answer: **yes, for v0.** In a bounded model check, the caller-supplied
sequence model (B) keeps every safety invariant under the modeled faults. It
also needs less trusted state than the only allocator variant that is safe
(A1). The #89 kill criterion is therefore met: remove the allocator from v0.

This is the "model before RTL" step from `docs/FORMAL-DURABLE-TID-PLAN.md`
and skills RFC 0005. It is a bounded exploration, not a proof, and it does
not check liveness. The TLA+/PlusCal spec is the next step on the ladder.

## Models

| Model | Submit | Duplicate handling | Trusted state |
|---|---|---|---|
| A0: hardware allocates | `submit(req)`, hardware assigns `next_tid` | none | epoch, next_tid, durable_seq, visible_seq, FSM |
| A1: A0 plus a dedup index | `submit(req)` | index from `request_id` to `tid` covering every retryable request | A0 plus one index entry per request in the retry window |
| B: caller supplies | `submit(seq, req)` | `seq <= durable_seq`: re-ack if same payload, reject otherwise. `seq == durable_seq+1`: accept. Anything else: reject | epoch, durable_seq, visible_seq, FSM |

In B the expected sequence is always `durable_seq + 1` (one outstanding
operation), so B needs no pending or next-sequence register.

## What is checked

`bin/durable-tid-model.nu` explores every reachable state breadth-first. It
keeps the shortest counterexample for each violated invariant.

- **Faults:** a reset after every boundary (allocate, write, flush,
  durable-ack, publish), a lost acknowledgement, a delayed acknowledgement
  (the caller retries before the completion arrives), and duplicate
  submission. An adversarial caller may send any payload under any sequence
  number.
- **Recovery:** rebuilds the trusted registers from durable media only.
  Completions already on their way to the caller are not recalled.
- **State invariants:** NoDuplicateCommittedTid, GapFreeOrderedLog,
  DuplicateRequestCommitsAtMostOnce, CompletionImpliesDurable,
  UncommittedNeverVisible, RecoveryDoesNotCreateCommit,
  CommittedNeverExceedsAllocated.
- **Transition invariants:** MonotonicCommittedTid, MonotonicVisibleTid,
  CommittedRecordNeverMutates.
- **Bounds:** 2 logical operations, 1 reset, 1 lost acknowledgement, 1
  outstanding operation, TID bound 5.

Operation identity differs between the models. In A it is the request id. In B
it is the caller's sequence number. For an honest B caller, which maps one
payload to one sequence number, the payload must also commit at most once, and
the model checks that too.

## Results

The numbers below come from CI run 36049623019 (`durable-tid model check (#89)`
step). Re-run them with `nu bin/durable-tid-model.nu`.

| Model | Caller | States | Transitions | Depth | Violations |
|---|---|---:|---:|---:|---|
| A0 | honest | 60 | 109 | 15 | DuplicateRequestCommitsAtMostOnce |
| A0 | adversarial | 326 | 811 | 15 | DuplicateRequestCommitsAtMostOnce |
| A1 | honest | 48 | 79 | 14 | none |
| A1 | adversarial | 278 | 843 | 16 | none |
| B | honest | 48 | 79 | 14 | none |
| B | adversarial | 3852 | 16565 | 23 | none |

The shortest A0 counterexample needs no bug, only a reset:

```
submit r1 -> allocate tid=1 ; write ; flush ; reset+recover ;
submit r1 -> allocate tid=2 ; write ; flush        # r1 committed twice
```

The record was durable but never acknowledged. The caller retried correctly,
and the allocator handed out a fresh TID. The same thing happens after a lost
or delayed acknowledgement.

## Comparison

| Dimension | A1: allocator plus dedup | B: caller sequence |
|---|---|---|
| Safety under the modeled faults | holds | holds |
| Fixed trusted bits (design inventory, not synthesized) | 227 | 163 |
| Trusted state that grows with the retry window | 192 bits per entry (`request_id` 128 + `tid` 64). Must survive reset, so it is a media-backed index or CAM | none |
| Honest-caller state space | 48 states | 48 states, the same behaviour |
| Recovery | rebuild `next_tid` and the dedup index from media | rebuild `durable_seq` from media |
| Replay/duplicate handling | index lookup on every submit | one comparison with `durable_seq`, plus a payload compare for re-acks |
| Host obligations | supply a stable request id | one sequence source per stream; retries reuse the sequence number; persist the next sequence with the caller's durable state |
| Trust | the request id is caller-supplied anyway, so the allocator adds no trust | a buggy or malicious caller can only be rejected (gap or conflict). It cannot reorder, reuse a committed TID, or make uncommitted work visible |

The host obligations under B are existing binding constraints: "ordering has
one source" and "retries reuse logical operation identity". B moves no new
responsibility to the host. It deletes a hardware structure that duplicated
one.

## Not modeled (follow-ups)

- Liveness and fairness.
- More than one outstanding operation. Revisit if #86 shows that
  one-outstanding throughput is the bottleneck.
- Stale-epoch descriptors that reach hardware after a reset.
- Malformed descriptors, and torn or corrupted durable records (#88 fault
  list).
- RTL resource use. The bit counts above are a register inventory, not
  synthesis results. #87 should measure them.

## Consequence for #87

FPGA v0 state becomes `epoch`, `durable_seq`, `visible_seq`, the FSM state,
`error`, and the progress/reset counters, with no allocator. `request_seq` is
the caller's. The v0 gate only enforces `seq == durable_seq + 1` and
`TRUSTED_COMPLETE(N) => PERSISTENT(N)`.
