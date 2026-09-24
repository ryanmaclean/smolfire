# Formal verification plan for durable-TID hardware work

The hardware branch below smolFire must be model-first.

## Sequence

```
TLA+/PlusCal
→ model checking
→ JS executable oracle
→ RTL
→ SVA/SymbiYosys
→ FPGA
→ fault injection
→ ASIC gate
```

## Required safety properties

- no committed TID reuse
- monotonic committed order
- no completion before durability
- recovery cannot invent committed work
- allocated-but-uncommitted work cannot become visible after reset
- duplicate request identity commits at most once
- committed TID never exceeds allocated TID

## Explicit fault model

Test/model failure after every boundary:
- allocate
- buffer
- issue write
- write complete
- issue flush
- durable ack
- publish completion

## Relationship to SS1 lab

- SS1-A = software oracle
- SS1-B = RTL DUT
- SS1-C = fault injector

Formal counterexamples become hardware regression fixtures.

Related:
- skills RFC 0005
- skills scaffold durable-tid/docs/FORMAL.md
- smolFire #73/#78/#79


## Immutability and determinism

The hardware/storage branch must enforce these additional constraints:

- committed facts are immutable
- replay from committed facts is deterministic
- proposal/execution may be nondeterministic, commit semantics may not
- same ordered committed facts must reconstruct the same durable state
- canonical encoding must be stable across JS, native reference code, RTL, FPGA, and any future ASIC

Evaluate whether trusted hardware can retain only:

```
(epoch, last_tid, root_hash)
```

while external storage retains the immutable history.

## First model-check result (#89)

`bin/durable-tid-model.nu` (bounded explicit-state; CI step `durable-tid model check (#89)`) compares hardware TID allocation with caller-supplied sequence. The allocator alone commits retried requests twice after a reset. The caller-sequence model keeps every invariant above and needs less trusted state. Details are in `docs/DURABLE-TID-SEQ-VS-ALLOC.md`.
