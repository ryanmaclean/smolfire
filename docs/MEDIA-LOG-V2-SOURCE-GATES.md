<!-- SPDX-License-Identifier: Apache-2.0 -->
# Media-log v2 source and execution gates

Status: source correction only; native, RTL, physical media and board acceptance HOLD.

## Record offset contract

ml2_checked_slot_offset treats maximum_offset as an inclusive byte ceiling. A successful result proves both the first byte index*stride and final byte index*stride+55 fit. It first rejects a ceiling below55 and compares index against (ceiling-55)/stride before multiplication. Null output and zero stride fail; failure leaves an existing output value untouched. This helper does not prove physical extent, disjoint failure units, an acceptable stride, or any barrier. A stride below56 remains representable for logical diagnostics and must not be admitted as isolated physical storage.

## No diagnostic-tool exception

The PR124-specific Icarus installation, Bash/mapfile/process-substitution orchestration, Git assertion, coreutils hashing/timeout and artifact-as-PASS path have been removed. tests/pr124-offboard-gate.nu now fails explicitly and launches no external tool. The PR124 Linux CI step also reports HOLD using Nushell; neither general CI success nor old artifact banners replace this gate. The rest of the repository CI is not audited or admitted by this change. Do not execute any route until the complete selected remote tool/dependency graph satisfies the MIT/BSD/Apache-only rule. No simulator replacement or new tool dependency is asserted.

## Regression proposal and missing native interface

New tests/scripts must be Nushell under AGENTS.md. Existing hps/media_log_v2_test.c is preserved unchanged for provenance; its prior execution and language choice are not newly authorized. The existing UART harness comment claims a historical C(termios) ruling, but does not establish approval for a new C media RPC/test harness. No C assertions were moved behind a Nushell wrapper and no parallel decoder was created.

tests/media-log-v2-fixtures.nu exports28 proposed cases and fixed byte vectors. It contains no runner and is not wired into CI. It preserves the existing cases for exact prefix, single unacknowledged candidate, second complete/partial candidate, distinct EOF/I/O/short reads, forged length, CRC corruption, extent-before-I/O checks and exact/changed retries. It adds full-record offset ceilings, zero/null guards, signed/unsigned extremes and unchanged-output failures. Full u64 inputs/outputs are decimal strings. The independent known CRC constant and56-byte fixture remain explicit; generating fixture bytes is not execution of the C decoder.

A future approved binding must invoke the actual C functions, preserve u64 values losslessly, observe callback order/count and output clearing, and compare these expected outcomes in Nushell. Null-pointer and synthetic callback-error cases need an explicitly approved native callable/testing interface; a file-reading CLI alone cannot claim those cases. Until that interface and the full remote tool graph exist, this is a fixture proposal, not a complete replacement for the old C harness. Removal of that harness is deliberately deferred. Native negative-control failure propagation, RTL119/0 vectors and board behavior remain separately unproved.

## HPS/media completion remains unavailable

The actual C UART harness drives the v1 register model; it has no request-bound media reader/writer or durable receipt path. The retained decoder/scanner only classifies caller-declared logical slots. Both RTL variants still use a local COMMIT timer. No source in this change creates READY, advances a witness, installs a generation, or interprets UART WRITE-ACK as media completion.

The unchanged [v2 media receipt proposal](MEDIA-RECEIPT-ABI-V2.md) remains controlling: selected target filesystem/device and physical failure-unit placement; complete trusted extent/suffix; exact checked I/O; data barrier before independently retained W; recoverably ordered control update; highest validated G+1 durably fenced before READY; exact historical-byte replay; and explicitly negotiated full-width request/session/receipt tuple. Same-medium W/G rollback cannot be repaired by a CRC or timer. No backend, fixed stride, filesystem durability promise, MMIO register map or UARTv2 encoding is invented here.

Next substantive implementation requires an actual selected storage/control authority and target contract, then paired HPS/RTL transport integration and admitted native fault/power-cut evidence. Board identity, bitstream provenance, fit/timing and physical fault acceptance remain separate.
