# SuperStation One pre-ASIC validation plan

## Goal

Use the three available SuperStation One systems as the cheapest hardware validation path for the lower-bound transaction/ordering primitive before considering ASIC.

## Node roles

### SS1-A — software control

Runs the software durable-tid reference implementation.

Purpose:
- canonical behavioural reference
- crash/recovery oracle
- benchmark baseline

### SS1-B — FPGA DUT

Runs the RTL implementation.

Initial design:
- descriptor ingress
- monotonic TID allocator
- commit FSM
- BRAM-backed queue/state
- completion path
- CRC/integrity check

No SHA-256, DMA, VirtIO, NVMe, or soft CPU in v0 unless measurements require them.

### SS1-C — fault injector

Continuously exercises:
- reset at every FSM boundary
- duplicate submit
- replay
- malformed descriptor
- queue-full/backpressure
- interrupted commit
- recovery consistency

## Validation ladder

1. software implementation
2. RTL simulation
3. formal verification
4. FPGA BRAM-only implementation
5. 10M+ operation differential run
6. fault-injection campaign
7. persistent-media integration
8. optional NVMe FUA/flush experiments
9. multi-node causal/order experiment
10. ASIC decision gate

## Comparison

For every accepted hardware revision:

```
software.last_tid == fpga.last_tid
```

and every committed record must match by TID and payload/hash.

## ASIC gate

No tapeout unless hardware beats the CPU implementation on at least one useful dimension:
- latency
- CPU cycles
- determinism
- power
- elimination of software layers

## Related work

- smolFire #73 — FPGA/SmartNIC/NVMe sequencer research
- smolFire #78 — lower-bound runtime umbrella
- smolFire #79 — shared benchmark record
- ryanmaclean/skills RFC 0004
- ryanmaclean/skills scaffold: durable-tid
