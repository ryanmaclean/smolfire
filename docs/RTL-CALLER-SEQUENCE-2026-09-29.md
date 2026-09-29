<!-- SPDX-License-Identifier: Apache-2.0 -->
# #87 caller-supplied sequence source slice

This isolated candidate removes the 64-bit `tid_next` allocator register
from both RTL variants. It keeps the existing Avalon map and UART frame
layout, but increments the register `VERSION` and UART PONG value from 0
to 1 so the HPS harness rejects an old allocator-based bitstream before
differential runs. `MAGIC` remains `DUR0`. `REQ_{HI,LO}` is a 0-based TID;
`PENDING`, `DURABLE`, and `VISIBLE`
are counts (highest committed 0-based TID + 1). The first valid request is
0. After durable count N, the next valid request is N. The HPS software
oracle's 1-based `seq=N+1` maps to RTL request `seq-1=N`.

At IDLE, request below durable count is `DUP_SEQ` and request above it is
`GAP_SEQ`; both leave all watermarks unchanged. A matching request is
latched. CRC failure leaves watermarks unchanged. CRC success sets pending
to request+1. COMMIT is the only state that advances durable. COMPLETE
publishes visible and emits trusted completion. A soft reset in SUBMIT,
CRC, or COMMIT parks pending at durable with no allocation to revoke;
the same request can be retried. At durable count 2^64-1, the matching
request is rejected as `OVERFLOW` before request+1 could wrap.

The model-B duplicate rule has a separate persistent-media obligation:
the host must compare an old request's payload to the durable record
before re-acknowledging it. This DUT has no persisted payload index or
read path, so it only returns `DUP_SEQ` with no new commit. A `DUP_SEQ`
bit **alone must not be reported as a successful idempotent re-ack**.
The HPS UART harness has no durable-media read interface: its duplicate
vector deliberately changes the descriptor and treats `DUP_SEQ` as a
successful *negative test*, never an application ACK. The separate #86
software log writes internally generated records and is not bound to the
FPGA descriptor, epoch, or commit pulse. Comparing that log to a retry
would not prove the submitted operation was durably stored. Safe re-ack
requires a storage record indexed by the same request TID and epoch,
the persisted payload (or collision-resistant digest), and an authenticated
read after recovery before any ACK decision. Those interfaces do not exist
in this register-only v0 slice, so conflicting and identical old requests
both remain fail-closed `DUP_SEQ` without a trusted completion pulse.
The 16-byte descriptor CRC covers the low request word and payload as in
the existing frame; the full-width equality check against durable count
keeps an altered high word from being accepted as the next request.
The UART single-submit and burst paths still pin `REQ_HI=0`, and the HPS
oracle uses a 32-bit request value. The high-half acceptance and low-word
carry cases are exercised only through the Avalon register testbench.

The source-only testbench adds reset in SUBMIT and CRC, full-width gap,
terminal overflow, conflicting-payload duplicate rejection, and forced-state
high-half/carry arithmetic controls;
it retains the merged PR113 SUBMIT/S_CRC zero/one-count reset controls,
adapted to durable-count semantics, as well as COMMIT reset, duplicate,
gap, CRC and monotonicity controls. It can be compiled with either
RTL variant, but no simulator was run under the current MIT/BSD/Apache-only
tool policy. No resource/timing result or bitstream is implied.
