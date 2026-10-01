<!-- SPDX-License-Identifier: Apache-2.0 -->
# Media receipt and replay ABI v2 (proposal)

**Status: proposed, unimplemented.** This document defines the contract needed to connect caller-supplied TIDs in the register DUT to a real HPS media log. It is not a claim that the current RTL, UART bridge, HPS harness, filesystem or board satisfies the contract. Register offsets, UART frame bytes, physical record placement and backend choice are not frozen. The v1 DUT continues to reject historical TIDs; its local COMMIT timer is a model, not evidence of a media barrier.

This design follows the one-outstanding caller-sequence model in [DURABLE-TID-SEQ-VS-ALLOC.md](DURABLE-TID-SEQ-VS-ALLOC.md) and the current [caller-sequence source slice](RTL-CALLER-SEQUENCE-2026-09-29.md). It addresses the separate storage obligation: `TRUSTED_COMPLETE` must imply that the exact request has survived the selected media barrier under a stated failure model. The HPS log is the one source of persistent order and payload equality; FPGA registers are a disposable projection of its recovered prefix. This adds no hardware TID allocator, orchestration database, persistent FPGA index or general queue.

## Preconditions before any production receipt

The HPS/storage owner must choose and test a target BSD filesystem/device configuration, including mount and controller-cache behavior, exact data and metadata barrier calls, and the physical write/failure unit. Logical record bytes alone do not determine a safe physical stride. Slots must be isolated so a later append cannot rewrite a sector or other failure unit containing an acknowledged predecessor, or an equivalent journal/copy-on-write rule must be proved on the target. A 56-byte logical record is not a safe default physical stride: record 9 begins at byte 504 and crosses a 512-byte sector. Padding to 4096 bytes is only a candidate until real allocation and power-cut behavior is measured.

The storage authority also needs a durable acknowledged-prefix witness `W` and a monotonic recovery generation `G`. `W` advances for **every** new media commit before the corresponding receipt; `G` advances and is durably fenced before every READY session. Their versioned control transaction needs an atomic or recoverably ordered update with checked barriers. Independently retained `W` can detect acknowledged data-prefix rollback; a separately proved external acknowledged lower-bound anchor can also detect some data rollback. Excluding old-session receipts after control rollback additionally requires an independently retained monotonic `G` or a separately specified and tested boot-nonce protocol. A control file on the same failing medium can roll back with the log; a CRC cannot detect that. Without these authorities, the durable-completion and stale-receipt claims remain unavailable. A backend where sync reports success but an acknowledged record later disappears is not eligible merely because it satisfies the software call order; the [SuperStation fault-injection results](SUPERSTATION-FAULT-INJECTION-2026-09-25.md) contain such a counterexample.

## Identity and logical record

One writer owns a persistent `store_id` (128 bits) and immutable `stream_epoch` (64 bits). A caller supplies a zero-based `request_tid` (64 bits) and retries with the same identity and exact eight descriptor bytes (`DESC0`, `DESC1`). The operation key is `(store_id, stream_epoch, request_tid)`. Recovery generation is a transport/session fence, **not** part of the operation key, so reboot does not create a new operation. `durable_count=n` means records `[0,n)` form the validated, witnessed contiguous prefix; new requests must use TID `n`. Checked arithmetic rejects `u64` count/offset overflow before I/O.

The proposed logical data record has 56 bytes, explicitly little-endian rather than a native C struct: magic `u32`, version `u16=2`, length `u16=56`, store ID `[u8;16]`, stream epoch `u64`, request TID `u64`, DESC0 `u32`, DESC1 `u32`, zero reserved `u32`, and CRC32 `u32` over the preceding 52 bytes. This layout is a review candidate, not a frozen disk or UART format. CRC detects accidental corruption under the tested fault model; it is neither a cryptographic identity nor a substitute for full historical-byte comparison. A versioned control record binds store/stream identity, `W`, `G` and control version. Old versions fail closed until an explicit migration is designed.

## HPS outcomes and receipt order

The HPS API returns typed outcomes: `Committed`, `Replayed`, `Conflict`, `Gap`, `Busy`, `StaleGeneration`, `StorageError` or `UnknownOutcome`. Only the first two may produce an RTL completion receipt. A timeout, failed/uncertain barrier or lost transport response is `UnknownOutcome`; it fences new admission until recovery/lookup determines the result. A failed partial write may leave bytes, and a lost receipt may follow a fully committed append. The enforceable rule is one committed logical record per key, not “no bytes written on error.”

For new TID `n`, the HPS writes the exact canonical record into an isolated slot, completes the checked data barrier, durably publishes `W=n+1` with a checked control/metadata barrier, then and only then emits `MEDIA_COMMITTED` bound to the live session and request tuple. Failure or uncertainty at either barrier emits no trusted receipt. For historical TID `k<n`, HPS reads the retained record and compares the complete identity and eight payload bytes. Exact equality emits `REPLAY_VERIFIED` without append, witness update or count increment. Changed bytes, even with the same CRC, are `Conflict`; missing/corrupt/unreadable history is `StorageError`, not a watermark-based ACK. The promised replay horizon must retain the bytes needed for comparison.

The current independent benchmark log and UART harness do not implement this API: the benchmark generates its own payload, and the harness has no media read/write path. The benchmark recovery scanner must not be promoted as-is; a trusted decoder checks lengths before CRC, distinguishes EOF from short/torn read and I/O error, and scans the entire suffix before any adoption.

## Boot recovery and generation fence

Hard or soft reset invalidates every in-flight request and receipt tag and leaves RTL `NOT_READY`; counts are not authoritative while NOT_READY. The sole HPS owner quiesces old transport, reads the latest validated independent control state, scans the log, and faults if the witnessed prefix is missing/corrupt or below a separately proved acknowledged lower bound. It validates the whole suffix before adopting anything:

- `W=n` permits at most **one** complete candidate record above the witness, at TID `n`, under the one-pending rule. Two valid records `n` and `n+1` are FAULT, not an opportunity to advance twice.
- One valid `n` followed by **any non-padding torn/partial attempted `n+1`** is also FAULT. A second candidate violates the one-pending/witness-order assumptions even if it is incomplete.
- A full-length CRC-bad final candidate is indeterminate FAULT unless a separately proved protocol distinguishes it from an acknowledged record damaged after the fact. A short/torn suffix is repairable only if trustworthy `W` and physical placement prove no acknowledged unit is affected; repair must be flushed before READY. Interior corruption or read error is FAULT.
- A single valid record `n` above `W` may be adopted only after a checked recovery data barrier and witness update. The caller's old ACK delivery remains unknown and requires exact replay on retry.

After recovery, HPS increments `G` with overflow check and durably publishes `(G+1,W,store_id,stream_epoch,control_version)` **before** staging/installing READY. An uncertain control update leaves NOT_READY; the next attempt reads the highest validated durable `G` and advances again, never guessing that the write failed. A reset after READY consumes a fresh generation. Delayed prior-session receipts are rejected by generation and request tag. This fence is conditional on the independently retained, honest-barrier control authority; a rolled-back same-medium counter can be reused and would invalidate the claim.

## Versioned RTL and UART boundary

Version 2 must negotiate explicitly; a v1 frame or bitstream cannot set READY or deliver a media receipt. HPS has exclusive MMIO ownership. A session `BEGIN` invalidates staging fields and yields a fresh transaction tag; each indexed field is written once with that tag; a full valid-mask and independently computed expected tuple are checked with exact readback before INSTALL. A doorbell alone cannot detect plausible mixed multiword writes. Unexpected second writer or bypass of exclusive MMIO ownership is a trust-boundary failure. Request/receipt staging uses the same tag and complete tuple binding.

The RTL latches both new and historical well-formed TIDs. A new request waits for `MEDIA_COMMITTED`; a historical candidate waits for `REPLAY_VERIFIED`. A receipt binds store/stream, live `G`, full 64-bit TID, both descriptor words, request tag and outcome kind. Wrong/stale/partial receipt cannot change counts or pulse completion. `DURABLE` and `VISIBLE` represent **eligible prefix counts**, not proof that an external client received an ACK. Successful recovery installs both at `n`; new media receipt advances DURABLE then new-complete makes it VISIBLE. Replay emits a distinct historical-TID completion without changing either count or new-commit progress. A commit whose receipt or client ACK was lost is discovered at boot as eligible, but boot does not synthesize delivered ACK history; the caller retries the same key.

The UART v2 frame must carry full 64-bit identity/generation/TID and explicit length/byte order. The current low-32-only burst path, its `COMMITTED` result bit, and WRITE-ACK must not be interpreted as media completion. Both Verilog variants, UART bridge, HPS codec and testbench must change together. Exact register offsets and frame bytes should be frozen only after the storage authority and independent paired tests exist.

## Acceptance vectors and proof limits

| Fault or request | Required outcome |
|---|---|
| New TID `n`, exact payload, successful data then witness barriers | One logical record and `MEDIA_COMMITTED`; new completion advances eligible count to `n+1`. |
| Historical exact retry after lost client ACK or reset before RTL receipt | `REPLAY_VERIFIED`; no append, count or new-progress increment; distinct replay completion. |
| Wrong store/stream, generation, request tag, high TID half, descriptor byte, or receipt kind | Reject without trusted completion or watermark change. Include same-CRC/different-payload retry. |
| Interrupted or duplicate indexed session writes under exclusive MMIO ownership, missing field, delayed old-generation response | Reject or remain NOT_READY; test plausible full mixed tuple as well as partial staging. A second writer bypassing exclusive ownership is an out-of-contract trust-boundary failure, not a tuple-detection guarantee. |
| Short write, data-barrier failure, witness-barrier failure or timeout | No trusted receipt, admission fenced; recover/lookup same key before any retry. Bytes may exist. |
| Crash at each control-write byte/barrier/READY point | Recover highest validated `G`, advance and fence before READY; stale receipt rejected. |
| Witness `W=n`, one valid `n` above it | Adopt only after checked recovery barrier and witness update; caller delivery remains unknown. |
| Witness `W=n`, two valid records or valid `n` plus partial attempted `n+1` | FAULT; no adoption, witness advance or READY. |
| Missing/corrupt record below W, full-length corrupt final candidate, interior error, or shorter log than independent acknowledged lower bound | FAULT; no silent truncate or reset-to-zero. |
| Same-medium data and control rollback after ACK | Undetectable without independent retention/anchor; reject backend for this claim. |
| Unsupported v1 frame/record or overflow | Fail closed before admission/I/O. |

Source/model tests can check parser, identity and state transitions. RTL simulation can check tuple gates, reset and pulse behavior. Neither proves an honest target barrier, independent witness retention, physical slot isolation, exact FPGA package/pins, fit/timing, or HPS↔RTL board behavior. Target filesystem/device remount and power-cut tests plus same-board capture are required before calling this a durable completion implementation. Until then PR121's timer path is a model and this document is only a proposal.
