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

## Non-goals

- No RISC-V CPU in the commit datapath by default.
- No custom ISA/coprocessor interface (e.g. CV-X-IF) before an MMIO-based Ibex integration has been measured.
- No generic SoC design — this stays scoped to the durable-tid primitive.
- No Linux dependency.
- No GPL/LGPL/AGPL dependency anywhere in the stack (repo-wide licensing rule; Ibex and OpenTitan are Apache-2.0, satisfying this by default).
- No fresh CPU/DMA/SHA implementation unless an existing permissive IP block (Ibex, OpenTitan DMA/HMAC/SHA) fails the requirements above.

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

- **NVIDIA BlueField DPA/SNAP** — RISC-V datapath processors adjacent to NVMe/virtio storage offload; full DPU with general storage virtualization and network stack.
- **Intel/Altera IPU** — infrastructure processing unit combining an FPGA/ASIC fabric with a CPU complex for network/storage offload; general-purpose infra target, not a durable-commit-identity primitive.
- **ScaleFlux computational-storage ASIC** — CSD ASIC doing inline compression/transparent compute near flash; proprietary, fixed-function, not formally specified or open.
- **Samsung SmartSSD** — FPGA-augmented SSD for near-storage compute (Xilinx-based); general accelerator platform, no durable ordered-identity contract of its own.

None of these four target our narrower problem directly — a formally specified, open, durable ordered-completion identity primitive. The point of the comparison is not feature parity with any of them: it's confirming the smallest open, formally specified subset of "durable ordering/version identity" is not already solved by a permissively licensed component we could reuse instead of building. As of this survey, none of the four candidates above is open/permissively licensed at the primitive level, so none satisfies the reuse-before-building rule in the Non-goals section.

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
