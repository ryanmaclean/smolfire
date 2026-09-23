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
