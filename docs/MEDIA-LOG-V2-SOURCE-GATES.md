<!-- SPDX-License-Identifier: Apache-2.0 -->
# Media-log v2 source and execution gates

Status: C/Nu native logical observer, retained C vectors and an Icarus Verilog RTL simulation gate run in PR124 Linux CI (source/model evidence only); physical media, HPS W/G authority and board acceptance HOLD.

## Record offset contract

ml2_checked_slot_offset treats maximum_offset as an inclusive byte ceiling. A successful result proves both the first byte index*stride and final byte index*stride+55 fit. It first rejects a ceiling below55 and compares index against (ceiling-55)/stride before multiplication. Null output and zero stride fail; failure leaves an existing output value untouched. This helper does not prove physical extent, disjoint failure units, an acceptable stride, or any barrier. A stride below56 remains representable for logical diagnostics and must not be admitted as isolated physical storage.

## CI gate and tool approvals

Owner approvals recorded 2026-10-18 on PR124: (1) the retained hps/media_log_v2_test.c is kept as a C test; (2) Icarus Verilog (GPL) is allowed ONLY as a CI/test tool for RTL simulation. It is installed from the runner package manager at CI time, never vendored, shipped or linked. No other GPL tool exception is granted.

tests/pr124-offboard-gate.nu (Nushell; workflow glue is POSIX sh for the apt install only) builds and runs: the retained C vectors plus a deliberate-failure control that must exit 1; the native logical observer (actual ml2_decode_record / ml2_scan / ml2_checked_slot_offset) driven by tests/media-log-v2-observe.nu with 60 cases, 13 malformed requests and six fake-output controls, including wrong-store, wrong-epoch and wrong-TID vectors that must reach ML2_FAULT_IDENTITY / ML2_FAULT_TID with a cleared candidate; and both rtl/durable_tid_v0.sv and .v against durable_tid_v0_tb.sv (119 passed / 0 failed) with a deliberate-failure control per variant that must exit nonzero. A green gate is source/model evidence for these logical and RTL-model checks only.

## Published logical observer

New tests/scripts must be Nushell under AGENTS.md. hps/media_log_v2_test.c is retained with owner approval (above). The UART harness comment claims a historical C(termios) ruling, which is not relied on here. No C assertions were moved behind a Nushell wrapper and no parallel decoder was created. tests/media-log-v2-fixtures.nu exports 28 fixed-vector cases and hps/media_log_observe.c is the callable native seam; expected values and pass/fail logic stay in Nushell.

## HPS/media completion remains unavailable

The actual C UART harness drives the v1 register model; it has no request-bound media reader/writer or durable receipt path. The retained decoder/scanner only classifies caller-declared logical slots. Both RTL variants still use a local COMMIT timer. No source in this change creates READY, advances a witness, installs a generation, or interprets UART WRITE-ACK as media completion.

The unchanged [v2 media receipt proposal](MEDIA-RECEIPT-ABI-V2.md) remains controlling: selected target filesystem/device and physical failure-unit placement; complete trusted extent/suffix; exact checked I/O; data barrier before independently retained W; recoverably ordered control update; highest validated G+1 durably fenced before READY; exact historical-byte replay; and explicitly negotiated full-width request/session/receipt tuple. Same-medium W/G rollback cannot be repaired by a CRC or timer. No backend, fixed stride, filesystem durability promise, MMIO register map or UARTv2 encoding is invented here.

Next substantive implementation requires an actual selected storage/control authority and target contract, then paired HPS/RTL transport integration and admitted native fault/power-cut evidence. Board identity, bitstream provenance, fit/timing and physical fault acceptance remain separate.
