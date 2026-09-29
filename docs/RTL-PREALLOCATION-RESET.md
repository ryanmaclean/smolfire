# Soft reset before allocation

> Historical PR113 allocator fix. The caller-supplied sequence candidate in
> [RTL-CALLER-SEQUENCE-2026-09-29.md](RTL-CALLER-SEQUENCE-2026-09-29.md)
> removes `tid_next` entirely. Its testbench retains the zero/one-count
> SUBMIT/S_CRC reset controls with the next request derived from durable count.

Source review found that soft reset decremented `tid_next` in SUBMIT, CRC and
COMMIT, although allocation advances only on a successful CRC edge into COMMIT.
Before that edge, decrementing retreats an existing ID; the first operation
underflows zero to the maximum 64-bit value and prevents its normal retry.

Both Verilog and SystemVerilog variants now revoke an ID only in COMMIT.
RSTMID still records interrupted SUBMIT, CRC and COMMIT work. Durable/visible
history, pending reset, and IDLE/COMPLETE behavior are unchanged. This is a
bounded correction to the existing allocator, not the model-B allocator-removal
implementation.

| Reset phase | Allocation before reset | Correct action |
|---|---|---|
| SUBMIT | not advanced | preserve next ID |
| CRC | not advanced | preserve next ID |
| COMMIT | advanced, not durable | revoke one ID |
| COMPLETE | durable | preserve next ID/history |
| IDLE | no in-flight allocation | preserve next ID/history |

The existing testbench adds SUBMIT and CRC cases at both next ID zero and one.
Each locates the actual phase with a bounded wait, checks preserved watermarks,
pending state, reset count and RSTMID, rejects premature completion, and retries
the same descriptor to require exactly one commit. Existing COMMIT revoke/retry
and IDLE reset tests remain intact; always-on monitors remain armed through each
tested soft reset.

Validation status: source review and diff checks only. The new testbench has
**not been executed**. Repository instructions currently use Icarus/Quartus;
no simulator or synthesis tool with an approved dependency/license closure was
available for this task. Required next gate: run the full existing and extended
testbench against each RTL variant on an approved toolchain, then obtain the
appropriate hardware evidence before accepting a new bitstream. Prior hardware
traces and bitstreams are preserved and do not certify this change.
