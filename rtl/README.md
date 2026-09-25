<!-- SPDX-License-Identifier: Apache-2.0 -->
# durable_tid_v0 — register-only durable completion gate (issue #87)

v0 FPGA experiment: monotonic TID allocator + commit FSM enforcing
`TRUSTED_COMPLETE(N) => PERSISTENT(N)`. No BRAM queue, DMA engine, SHA,
RISC-V softcore, NVMe stack, filesystem, networking, or generic ring —
per #87 exclusions. Integrity is CRC-32 (IEEE 802.3).

## Files

| File | What it is |
|------|------------|
| `rtl/durable_tid_v0.sv` | The DUT. SystemVerilog-2012, Quartus-Lite-compatible subset (no vendor IP, no proprietary pragmas). Avalon-MM-style slave for the HPS `lwhps2fpga` bridge; concrete 4 KB offset map is in the file header (replaces the TBDs in `docs/MISTER-DUT-PLAN.md` §4). |
| `rtl/durable_tid_v0_tb.sv` | Self-checking testbench: N good submits, duplicate/replay/gap/malformed vectors, submit-while-busy, reset mid-commit, idle reset, recovery resubmit. Always-on monitors for the invariant + monotonicity. Prints `PASS`/`FAIL` + `$finish`. |
| `hps/harness.c` | HPS-side stimulus / fault-injection skeleton (`/dev/mem` mmap, submit/reset/duplicate/replay/queue-full/recovery-consistency routines, `oracle_compare()` differential hook). **NOT built, NOT run** (see notice below). |

### Filename / language-policy note

SystemVerilog (`.sv`) and C (`.c`) files here are **HDL/firmware**, not
scripts: they are synthesized / cross-compiled for the FPGA + HPS, not
executed as repo tooling. They are outside the scope of the AGENTS.md
Nushell-only policy for "new scripts and tests" (which targets repo
automation and is enforced on `*.py`). No Python was added. The `.sv`
testbench is hardware verification, not a repo test script.

> [!IMPORTANT]
> **HPS harness language exception request (owner approval needed).**
> `hps/harness.c` is written in C because it must `mmap` `/dev/mem` and
> drive 32-bit MMIO registers from the ARM HPS — Nushell cannot do
> volatile physical-memory-mapped I/O. This C file is a **deliberate
> exception request** to the Nushell-only policy, not committed lightly:
> justification is hardware necessity (physical MMIO + `/dev/mem`), and
> scope is confined to `hps/` (device-side firmware). Owner: please
> approve or redirect (e.g. POSIX-sh + `devmem` helper instead).
> Second ask: **Quartus build host** — `quartus_map` exists nowhere yet
> (not on this Mac, not on the MiSTer); the bitstream cannot be built
> until an x86 Linux Quartus Lite host is designated.

## Testbench status: PASS (verified 2026-09-24)

Icarus Verilog 13.0 (`brew install icarus-verilog`, ~7 MB):

```sh
cd rtl
iverilog -g2012 -o sim durable_tid_v0.sv durable_tid_v0_tb.sv && ./sim
# checks passed: 48  failed: 0  +  PASS (stable across repeat runs)
iverilog -g2012 -Wall ...   # lint-clean, no warnings
```

Fixes applied to reach PASS (register map UNCHANGED — offsets, widths,
semantics of the map itself untouched):
- DUT watermarks are counts (highest durable TID + 1), matching the HPS
  harness oracle (`oracle_compare(sw_tid, read_durable())`); `tid_last`
  keeps the 0-based TID.
- Soft reset revokes the uncommitted TID so a resubmit commits under the
  SAME TID (recovery consistency); previously the resubmit was rejected
  as DUP.
- TB: added missing `A_MAGIC`/`A_VERSION`, monitor compares durable to
  `tid_last + 1`, reset pulses are negedge-driven (a posedge-timed
  deassert raced the DUT sample and the idle-reset pulse was missed).

## How the TB runs (once a simulator exists)

```sh
cd rtl
iverilog -g2012 -o sim durable_tid_v0.sv durable_tid_v0_tb.sv && ./sim
# expect: checks passed: <n>  failed: 0  +  PASS
```

The TB assumes the default `COMMIT_LATENCY=2` for the reset-mid-commit
injection window (TEST 6); if the parameter is changed, adjust TEST 6.

## How to compile once Quartus exists (project sketch)

```sh
# on the designated x86 Linux Quartus Lite host:
quartus_map  durable_tid_v0 --source=durable_tid_v0.sv --family="Cyclone V"
quartus_fit  durable_tid_v0 --part=5CSEBA6U23I7   # DE10-Nano SoC
quartus_asm  durable_tid_v0                        # -> .sof
quartus_cpf -c durable_tid_v0.sof durable_tid_v0.rbf
```

Wrap in a Qsys/Platform-Designer system exposing the peripheral on
`lwhps2fpga`, record the assigned base in `hps/harness.c`
(`DUT_REGION_OFFSET`), then load only with explicit deploy approval
(`fpga_manager` firmware load vs menu-core slot — still open per the plan).

## HPS harness build/run (NOT done — for bring-up only)

```sh
# on the HPS (armv7l Linux), after BASE is filled in:
#   gcc -O2 -Wall -o harness harness.c   # NOT built
#   ./harness smoke 1000                 # NOT run
#   ./harness fault duplicate            # NOT run
```
