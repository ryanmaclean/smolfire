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

## UART front-end for the host harness path (`exp/fpga-v0-rtl`)

Gives the running DUT a host-reachable 115200-8-N-1 serial port so the
future harness can talk to it over the Tang Console / Mega 138K SOM
debugger UART (USB tty on the host, BL616 debugger on the board). The DUT
file itself is UNTOUCHED (wrapped, not modified).

### New files

| File | What it is |
|------|------------|
| `rtl/dut_uart.v` | Verilog-2001 UART RX/TX (parameterized `CLK_HZ` + `BAUD`, default 50 MHz / 115200) + command-protocol FSM + Avalon-MM-style master bridge into the DUT slave (`avr_*` signals) + 1-cycle soft-reset pulse. |
| `rtl/dut_top_uart.v` | Top wrapper instantiating `durable_tid_v0` + `dut_uart` (no DUT changes). Divide-by-2: 50 MHz board clock (V22) → 25 MHz fabric via a toggle FF feeding a Gowin `BUFG` global buffer (clock network, not fabric routing — see hold note below); UART divisor uses the fabric rate. Carries the pin localparams + source comments and the CST snippet for the build host. |
| `rtl/dut_uart_tb.sv` | Self-checking testbench driving the DUT *exclusively* through the UART (behavioral host-driver tasks). 43 checks, always-on invariant + monotonicity monitors. See scope note below. |

### Clocking: why a toggle-FF divider failed and BUFG fixes it

The 25 MHz fabric clock is BOARD_CLK/2. The first attempt (commit
`4289a5a`) divided with a reset-aware toggle FF in fabric logic. That
closed SETUP but failed HOLD with 10 violations: a flip-flop output
used as a clock is routed on general interconnect, so the fabric clock
arrived with ~1.8 ns skew against ~0.85 ns of logic delay — and HOLD
IS FREQUENCY-INDEPENDENT, so no divider ratio or target frequency
fixes it. Only a dedicated clock resource fixes it. The second attempt
(commits `296c9ff`/`1b264b2`) used the Gowin `CLKDIV` primitive, but
`CLKDIV` has zero BELs in the OSS (apicula) chipdb and is unplaceable.
`dut_top_uart.v` now feeds a reset-aware toggle FF into a Gowin `BUFG`
global buffer (UG286: `BUFG (O, I)`; BEL census confirms `BUFGx1`
exists): `clk25` fans out on the global clock network, which collapses
the clock skew and clears the hold violations. Sim portability: icarus
has no `BUFG` model, so the primitive compiles only under `` `ifdef
SYNTHESIS `` (also selected by `__YOSYS__`); simulation uses a
behavioral divide-by-2 with identical phase/timing, and both sim
suites reproduce byte-identical PASS banners (48 + 43).

### Pin table (GW5AST-LV138PG484A, package PBG484A)

| Signal | FPGA pin | Dir | IO | Evidence |
|--------|----------|-----|----|----------|
| `uart_rxd` | V14 | in (FPGA RX, from BL616 TX) | LVCMOS33, PULL UP | `ddr3_1v4_hs.cst` + `top.v` (`input uart_rx`) |
| `uart_txd` | U15 | out (FPGA TX, to BL616 RX) | LVCMOS33, PULL UP, DRIVE 8 | `ddr3_1v4_hs.cst` + `top.v` (`output uart_tx`) |
| `clk` | V22 | in, 50 MHz onboard osc | LVCMOS33 | `hdmi.cst` + `gowin_pll.mod` (`fclkin 50`) + `uart_top.v` (`CLK_FRE 50`) |

No TBDs: pins FOUND. Sources checked 2026-09-25:
- <https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k.html>
  (chip `GW5AST-LV138PG484AC1/I0`, SOM debug interface `JTAG + UART JST SH1.0 8-pins`)
- <https://wiki.sipeed.com/hardware/en/tang/tang-console/mega-console.html>
  (Console uses the same Mega 138K SOM, so SOM-level FPGA pins hold)
- <https://github.com/sipeed/TangMega-138K-example> —
  `ddr_memory/ddr_memory_test_uart/src/ddr3_1v4_hs.cst`
  (`IO_LOC "uart_tx" U15; IO_LOC "uart_rx" V14; IO_LOC "clk" V22;`),
  `.../src/top.v` (port directions), `.../src/uart/uart_top.v`
  (`CLK_FRE 50, BAUD_RATE 115200`), `hdmi_colorbar/eda_proj/src/hdmi.cst`
  + `gowin_pll/gowin_pll.mod` (50 MHz clock evidence).
- Baud-divisor error at defaults: 50000000/115200 = 434.03 → 434
  cycles/bit; RX 16x tick truncates 434/16 → 27 (≈115740 baud, +0.47 %).
  At the divided 25 MHz fabric: 25000000/115200 = 217.01 → 217
  cycles/bit; RX tick truncates 217/16 → 13 (verified in sim).

### Protocol spec (all multi-byte values little-endian)

CMD frame, host → FPGA, 9 bytes:
`[MAGIC0=0x44 'D'][MAGIC1=0x55 'U'][CMD][ADDR][D0..D3 LE][CHK]`,
`CHK = (CMD + ADDR + D0 + D1 + D2 + D3) mod 256`.
`CMD`: `0x01` WRITE-REG | `0x02` READ-REG | `0x03` RESET | `0x04` PING.
`ADDR`: byte offset in the DUT 4 KB window (map tops at `0x058`).

RSP frame, FPGA → host, 8 bytes:
`[0x44][0x55][RSP][D0..D3 LE][CHK]`, `CHK = (RSP + D0..D3) mod 256`.
`RSP`: `0x81` WRITE-ACK (echo of written value) |
`0x82` READ-DATA (register value) |
`0x83` RESET-DONE (RESET_CNT after the pulse) |
`0x84` PONG (VERSION `0x00000000`).
Malformed frames (bad magic/checksum/unknown CMD, framing errors) are
dropped SILENTLY, no response; strict request-response (one RSP per CMD).
WRITE-REG ACKs after the write cycle (does NOT wait for commit — the host
polls `STATUS.BUSY` via READ-REG). RESET pulses `fsm_reset_i` 1 cycle,
then reads back `RESET_CNT`.

### CST story (build host only — no remote files touched)

`dut.cst` on the Gowin build host must gain exactly these lines
(full port settings included so synthesis cannot infer wrong IO types):

```text
IO_LOC "uart_rxd" V14;
IO_PORT "uart_rxd" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
IO_LOC "uart_txd" U15;
IO_PORT "uart_txd" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
IO_LOC "clk" V22;
IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=NONE BANK_VCCIO=3.3;
```

### UART TB status: PASS (verified 2026-09-25, icarus 13.0)

```sh
cd rtl
iverilog -g2012 -o sim_uart dut_top_uart.v dut_uart.v durable_tid_v0.v dut_uart_tb.sv && ./sim_uart
# checks passed: 43  failed: 0  +  PASS
iverilog -g2012 -Wall ...   # lint-clean, no warnings
```

The TB drives the 50 MHz board clock and runs at the HARDWARE baud
(`BAUD=115200`, divisor 217 cycles/bit at the divided 25 MHz fabric) so
the suite exercises the exact hardware timing, including the RX 16x-tick
truncation (217/16 → 13). It replays the original suite's functional
cases over serial (8 good submits, duplicate, bad-CRC / reserved-CTRL /
REQ_HI malformed vectors, idle reset + post-reset submit) plus
UART-specific coverage (PING/MAGIC+VERSION, WRITE echo, no-response
rejection of bad-checksum / bad-magic / unknown-CMD frames, link-alive
after rejection, repeated-submit).

### Scope note: two fault-injection windows stay parallel-TB-only

Original TEST 6 (reset mid-commit) and TEST 8 (submit while busy) CANNOT
be driven through this UART path, by construction: the DUT busy window is
≤ ~7 fabric cycles (SUBMIT 1 + COMMIT hold + COMPLETE 1; `commit_hold` is a 2-bit
register so `COMMIT_LATENCY` only takes effect for 0..3 — larger values
truncate, found during UART-TB bring-up, DUT untouched) = ≤ 280 ns at
the 25 MHz fabric, while the minimum gap between two executed UART commands is a full
frame round trip (9 + 8 bytes = 170 bit times ≈ 1.5 ms at 115200). The ACK of frame N alone exceeds the busy window by
~2500x. Over serial, a "reset mid-commit" always lands as an idle
reset and a "second submit while busy" always lands idle (demonstrated in
U8: rejected as DUP, never MALFORMED). Those two sub-microsecond windows
remain covered by the parallel 48-check suite (still PASS, DUT untouched).

> [!IMPORTANT]
> **Host-driver language question (owner decision needed).**
> The future host-side harness driver speaks this UART protocol over a USB
> serial tty. Nushell cannot do serial-port I/O (no termios/serial support),
> so the driver will need C (`termios`) or Python (`pyserial`) — an
> AGENTS.md Nushell-only-policy exception, same class as the `hps/harness.c`
> precedent above. No host driver is written on this branch (RTL + docs
> only); owner: please rule C-vs-Python when the harness is scheduled.

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
