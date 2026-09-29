<!-- SPDX-License-Identifier: Apache-2.0 -->
# #87 caller-supplied sequence source slice

This isolated candidate removes the 64-bit `tid_next` allocator register
from both RTL variants. It keeps the existing Avalon map and UART frame
bytes: `REQ_{HI,LO}` is a 0-based TID; `PENDING`, `DURABLE`, and `VISIBLE`
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
The 16-byte descriptor CRC covers the low request word and payload as in
the existing frame; the full-width equality check against durable count
keeps an altered high word from being accepted as the next request.

The source-only testbench adds reset in SUBMIT and CRC, full-width gap,
and terminal overflow controls; its existing COMMIT reset, duplicate,
gap, CRC and monotonicity controls remain. It can be compiled with either
RTL variant, but no simulator was run under the current MIT/BSD/Apache-only
tool policy. No resource/timing result or bitstream is implied.
