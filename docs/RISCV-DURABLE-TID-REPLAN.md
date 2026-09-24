# RISC-V replan for lower-bound storage/agent runtime research

## Main correction

Do not start by placing a RISC-V CPU in the durable-TID datapath.

The lowest architecture remains:

```
descriptor
 -> deterministic durable-tid RTL
 -> persistence acknowledgement
 -> tid/status completion
```

A RISC-V core is added later as a programmable control plane.

## Preferred open core

lowRISC Ibex:
- Apache-2.0
- small RV32
- active project
- SystemVerilog
- strong verification/formal culture
- FPGA and ASIC configurations

## Reusable open IP

OpenTitan:
- Apache-2.0 by default
- DMA
- SHA/HMAC
- memory/FIFO/integrity primitives

Use these as candidate building blocks before implementing equivalents.

## SuperStation plan

### SS1-A
software semantic oracle

### SS1-B
pure durable-tid RTL first; later Ibex + durable-tid

### SS1-C
fault injector / replay / reset / recovery comparison

## Why RISC-V later

Keeping the CPU out of v0 lets us measure:
- area of the actual primitive
- latency of the actual primitive
- whether firmware is necessary at all
- whether custom instructions buy anything

## Commercial comparison

NVIDIA BlueField demonstrates RISC-V datapath processors adjacent to NVMe/virtio storage offload.

Our research target is smaller:
- no general storage virtualization stack
- no network stack requirement
- formally specified durable commit identity
- open/permissive RTL
- BSD-oriented host/runtime integration

## Decision points

1. Can pure RTL satisfy the protocol?
2. Does adding Ibex simplify recovery/control enough to justify its area?
3. Does DMA remove measurable CPU/data-copy cost?
4. Does custom RISC-V instruction integration beat MMIO?
5. Does capability-aware DMA materially improve safety?
6. Does FPGA beat CPU sufficiently to justify ASIC?
