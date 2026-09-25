<!-- SPDX-License-Identifier: Apache-2.0 -->
# MiSTer FPGA DUT plan (issue #87 execution draft)

How the register-only durable completion gate (#87) maps onto the
DE10-Nano / Cyclone V SoC in the MiSTer at `10.0.2.61`.

Companion: `docs/SUPERSTATION-PRE-ASIC-PLAN.md` (SS1-B FPGA DUT section).
The pre-ASIC plan names SuperStation One as the validation path; the MiSTer
is the available fit-check platform for the same RTL until SS1-B lands.

> Status 2026-09-25: open question #1 (Quartus build host) is DECIDED —
> see below. RTL sim status lives on `exp/fpga-v0-rtl` (48 checks PASS,
> icarus); harness syntax status is a separate lane, unknown to this task.

## 1. Recon snapshot (2026-09-24, read-only, no anomalies)

| Item | Value |
|------|-------|
| Kernel | `Linux MiSTer 5.15.1-MiSTer armv7l` (HPS Cortex-A9) |
| MiSTer binary | 1018244 bytes, 2025-04-06, `md5 ef2741a4…`, PID 527 |
| Loaded core | `MENU` (idle — no game running, ideal window) |
| Disk `/media/fat` | 117G, 52% used (healthy, <90%) |
| Disk `/tmp` | tmpfs 247M, 5% used |
| `fpga_manager/fpga0` | `Altera SOCFPGA FPGA Manager`, state `operating` |
| `br0` | `lwhps2fpga` @ `0xFF400000`, enabled |
| `br1` | `hps2fpga` @ `0xFF500000`, enabled |
| `br2` | `fpga2hps` @ `0xFF600000`, enabled |
| Memory | 492 MiB total DDR3, ~387 MiB available |
| Quartus on device | none (`which quartus_map` empty — builds happen off-device) |
| dmesg | no FPGA errors (eth IRQ lines are normal for this platform) |
| Processes | MiSTer menu + fleet `ii-agent` only — nothing unfamiliar |

SAFETY: the `0xFF200000` lwhps2fpga bridge-control window bricks the FPGA
on write. All DUT work stays inside OUR peripheral region (offsets TBD,
section 4). Gaming SD `/media/fat` is read-only `ls`/`df` only.

## 2. #87 mapping onto DE10-Nano

#87 v0 state (epoch, request_seq/pending_seq, durable_seq,
visible_seq/completion_seq, FSM state, error, progress/reset counters)
fits in a handful of 32-bit control/status registers — no BRAM, no DMA:

- HPS harness: small C or POSIX-sh program on the armv7l Linux side that
  memory-maps OUR region via `/dev/mem` (offset-gated helper, never raw
  `0xFF200000`), submits sequence ops, and polls completion registers.
- RTL: one Qsys/Platform-Designer peripheral on the lightweight HPS-to-FPGA
  bridge exposing the #87 register file plus the `TRUSTED_COMPLETE(N) =>
  PERSISTENT(N)` gating FSM.
- Bitstream delivery: synthesize with Quartus Lite off-device, ship the
  `.rbf`, load via `/sys/class/fpga_manager/fpga0/firmware` (needs deploy
  approval, see Open Questions) or via a MiSTer menu-core slot — TBD.
- Debug registers from day one per #87: every v0 state element readable
  from HPS so the differential harness needs no JTAG.

## 3. What stays OUT (v0 exclusions, per #87)

Gaming setup untouched (`/media/fat` cores, `MiSTer.ini`, SD layout).
No SHA-256, no DMA engine, no RISC-V soft-CPU, no NVMe stack, no
filesystem, no networking, no generic ring, no BRAM queue. HPS/FPGA
interfaces used only for control/status of the gate itself.

## 4. Bridge / register-map sketch (offsets TBD pending RTL)

```
HPS view (offsets relative to OUR peripheral base — TBD after Qsys build):
  +0x00  EPOCH            (rw)  current epoch, HPS-set on recovery
  +0x04  REQUEST_SEQ      (rw)  next submittable sequence number
  +0x08  PENDING_SEQ      (ro)  highest accepted-but-undurable seq
  +0x0C  DURABLE_SEQ      (ro)  TRUSTED_COMPLETE watermark, monotonic
  +0x10  VISIBLE_SEQ      (ro)  completion/visible seq, never regresses
  +0x14  FSM_STATE        (ro)  commit-FSM encoding
  +0x18  ERROR            (rw1c) sticky error bits
  +0x1C  PROGRESS_CNT     (ro)  accepted ops counter
  +0x20  RESET_CNT        (ro)  HPS-driven reset counter
```

All addresses TBD until the Qsys system assigns the peripheral span.
`0xFF200000` (bridge control) is NEVER mapped, NEVER written.

## 5. Fault-injection hook point (#88)

SS1-C style injection is HPS-driven through the same register file, OUR
region only: reset at every FSM boundary (write EPOCH/RESET), duplicate
submit (repeat REQUEST_SEQ write), replay (re-drive a prior seq), malformed
descriptor (reserved-bit writes to a future SUBMIT register), queue-full
(v0 has no queue — backpressure bit TBD if the FSM gains one). No bridge
reconfiguration, no bitstream reload, no reboot — injection is register
writes plus HPS-side crash of the harness process to test recovery reads.

## 6. Acceptance sketch (validation ladder rung 5)

10M+ operation differential run against the SS1-A software oracle:
`software.last_tid == fpga.last_tid` after every batch, every committed
record matching by TID and payload/hash. Harness logs (seq, durable,
visible, error) per N ops to `/tmp` on the HPS side, ferried off-device
for comparison — nothing persisted on the gaming SD. Gate: zero
divergence, zero ERROR-sticky events unexplained, monotonicity assertions
(DURABLE_SEQ and VISIBLE_SEQ never regress) holding across HPS-harness
restarts. Result feeds the ASIC decision gate (beat CPU on latency,
cycles, determinism, power, or layer elimination — else no tapeout).

## OPEN QUESTIONS

1. Quartus build host: DECIDED — `7950x4090pop` (`10.0.2.42`): 32 threads,
   125GB RAM, 361GB free, Pop!_OS 24.04 x86-64, passwordless sudo present,
   i386 compat libs present, SSH works. Ruled out: this Mac (ARM + ~3GB
   free), FreeBSD hosts (Linux-only toolchain), ARM Pis.
   Target files: `QuartusLiteSetup-25.1std.0.1129-linux.run` (~2GB) +
   `cyclonev-25.1std.0.1129.qdz` (~1.3GB) -> `studio@10.0.2.42:~/quartus-dl/`
   (exists, empty). Integrity anchors (Intel page + nixpkgs +
   container_builder cross-validated): installer SHA1
   `ce0773469eacab5b7035c175484625f4ec3737d1`, cyclonev SHA1
   `a7225ec1bd36ccfd6826ea6273df5d21dd95633b`.
   BLOCKER: Intel/Altera edge requires a logged-in session (anonymous 403
   verified from 2 hosts); no trustworthy mirror exists (archive.org stale,
   UW Windows-only 17.0, nix/AUR point at the walled CDN, torrents
   excluded). Awaiting one human browser download.
2. Bitstream deploy path: `fpga_manager` firmware load vs menu-core slot —
   needs explicit owner approval before any `.rbf` touches the device.
3. HPS kernel driver: is a minimal UIO/`/dev/mem`-gated helper enough, or
   does the harness need a real kernel driver for the peripheral?
4. Qsys peripheral base address: assign during RTL build; update section 4
   offsets from TBD to concrete values.
5. SS1-B handoff: at what RTL maturity does the DUT move from MiSTer to
   SuperStation One hardware (2× units incoming)?
