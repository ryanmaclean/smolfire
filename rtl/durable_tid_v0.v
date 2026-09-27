// SPDX-License-Identifier: Apache-2.0
// durable_tid_v0.v -- Verilog-2001/2005 port of durable_tid_v0.sv.
//
// Mechanical port for Gowin/Yosys flows: `logic` -> reg/wire, untyped
// params/localparams, non-ANSI function header, block-scoped temps hoisted
// to module scope. The `.sv` original stays canonical for the Quartus path.
// Behavior, register map, CRC order, and COMMIT_LATENCY semantics identical.
// durable_tid_v0.sv -- register-only durable completion gate (issue #87, v0).
//
// Smallest FPGA experiment: a monotonic TID allocator + commit FSM that
// enforces the invariant
//
//    TRUSTED_COMPLETE(N) => PERSISTENT(N)
//
// i.e. the trusted-complete signal for sequence N is asserted only after N
// has reached the persistent (durable) register set, and the committed /
// visible watermarks never regress.
//
// v0 EXCLUSIONS (per #87; do NOT add): BRAM queue, DMA engine, SHA,
// RISC-V softcore, NVMe stack, filesystem, networking, generic ring.
// Integrity uses CRC-32 (IEEE 802.3), never SHA.
//
// ---------------------------------------------------------------------------
// Memory-mapped slave interface (32-bit Avalon-MM-style, single-cycle, for
// the Cyclone V HPS lwhps2fpga lightweight bridge).
//
// Signals:
//   input  clk                 -- fabric clock (HPS-provided, e.g. 50 MHz)
//   input  reset_n             -- global async-assert / sync-release reset
//   input  fsm_reset_i         -- explicit synchronous soft-reset input
//                                (HPS fault-injection / recovery; hold
//                                exactly 1 clk cycle). Preserves EPOCH,
//                                DURABLE, VISIBLE and the TID allocator;
//                                drops in-flight work, increments RESET_CNT,
//                                flags ERROR.RESET_MIDCOMMIT if asserted in
//                                SUBMIT/COMMIT.
//   input  [11:0] avs_address     -- byte address within the 4 KB window
//                                    (word-aligned; low 2 bits ignored)
//   input  [31:0] avs_writedata
//   output [31:0] avs_readdata    -- registered read data (2-cycle latency:
//                                    stage 1 registers address+read, the
//                                    mux selects, stage 2 registers the word)
//   input         avs_read
//   input         avs_write
//   input  [3:0]  avs_byteenable  -- partial-write mask (merged, not ignored)
//   output        avs_waitrequest  -- tied 0 (always ready, single cycle)
//   output        avs_readdatavalid-- registered: avs_read delayed 2 cycles
//   output        trusted_complete_o -- 1-cycle pulse in COMPLETE state
//   output [63:0] durable_tid_o   -- persistent watermark (observation)
//   output        busy_o           -- FSM not in IDLE (backpressure)
//
// 4 KB base-offset map (concrete offsets; replaces MISTER-DUT-PLAN TBDs).
// All offsets are byte offsets from OUR peripheral base. Unlisted words:
// reads return 0, writes are ignored.
//   +0x000 EPOCH        (rw)  current epoch, HPS-set on recovery; sticky
//                             across soft reset; part of CRC descriptor.
//   +0x004 REQ_LO       (rw)  requested sequence, low  32 bits.
//   +0x008 PENDING_LO   (ro)  accepted-op count incl. in-flight
//                             (= highest accepted TID + 1; parked at DURABLE
//                             on soft reset), low 32.
//   +0x00C DURABLE_LO   (ro)  TRUSTED_COMPLETE watermark as a COUNT of durable
//                             ops (= highest durable TID + 1; 0 when empty).
//                             Monotonic.
//   +0x010 VISIBLE_LO   (ro)  completion/visible count (= highest visible
//                             TID + 1). Never regresses.
//   +0x014 FSM_STATE    (ro)  commit-FSM encoding (low 3 bits).
//   +0x018 ERROR        (rw1c) sticky error bits, write-1-to-clear:
//                             [0] CRC_ERR          descriptor CRC mismatch
//                             [1] DUP_SEQ          duplicate/replay (req<=durable
//                                                  or in-flight replay)
//                             [2] GAP_SEQ          req ahead of allocator
//                             [3] MALFORMED        submit-while-busy/pending,
//                                                  reserved CTRL bits, or
//                                                  REQ_HI mismatch
//                             [4] RESET_MIDCOMMIT  soft reset hit SUBMIT/COMMIT
//                             [5] OVERFLOW         TID allocator wrapped
//                             [31:6] reserved (read 0).
//   +0x01C PROGRESS_CNT (ro)  accepted-and-completed ops counter.
//   +0x020 RESET_CNT    (ro)  soft-reset counter.
//   +0x024 CTRL         (rw)  [0] SUBMIT  write-1 to submit latched descriptor
//                                   (auto-cleared on accept or reject)
//                             [1] SOFT_RST write-1 = 1-cycle soft reset
//                                   (auto-cleared)
//                             [2] RECOVER write-1 clears COMPLETE_STICKY
//                                   (auto-cleared)
//                             [31:3] reserved: write-1 => ERROR.MALFORMED.
//   +0x028 STATUS       (ro)  [0] BUSY (= FSM != IDLE)
//                             [1] COMPLETE_STICKY (a commit completed since
//                                 last RECOVER; the TRUSTED_COMPLETE history)
//                             [2] CRC_OK_LAST (last SUBMIT validation result)
//                             [3] BACKPRESSURE (live mirror of BUSY).
//   +0x02C DESC0        (rw)  descriptor payload word 0.
//   +0x030 DESC1        (rw)  descriptor payload word 1.
//   +0x034 DESC_CRC     (rw)  expected CRC-32/IEEE over the 16 bytes
//                             {EPOCH, REQ_LO, DESC1, DESC0}, byte0 = DESC0[7:0].
//   +0x038 CRC_CALC     (ro)  locally computed CRC-32 (debug compare).
//   +0x03C TID_LO       (ro)  last committed TID, low 32.
//   +0x040 TID_HI       (ro)  last committed TID, high 32.
//   +0x044 REQ_HI       (rw)  requested sequence, high 32 bits (must equal
//                             allocator high half; else MALFORMED).
//   +0x048 DURABLE_HI   (ro)  durable watermark (count), high 32.
//   +0x04C VISIBLE_HI   (ro)  visible watermark (count), high 32.
//   +0x050 PENDING_HI   (ro)  pending watermark (count), high 32.
//   +0x054 MAGIC        (ro)  0x44555230 ("DUR0").
//   +0x058 VERSION      (ro)  0x00000000 (v0).
//
// Submit protocol (HPS side): write DESC0/DESC1/REQ_LO/REQ_HI/DESC_CRC, then
// write CTRL.SUBMIT=1. Poll STATUS.BUSY==0, then read DURABLE/VISIBLE/ERROR.
// A submit issued while BUSY (or while a previous submit is still pending)
// is rejected and flags ERROR.MALFORMED; the in-flight op is unaffected.
//
// Reset semantics: hard reset (reset_n) zeroes everything. Soft reset
// (fsm_reset_i or CTRL.SOFT_RST) parks the FSM in IDLE, sets
// PENDING=DURABLE (in-flight dropped, never surfaced as durable), preserves
// EPOCH/DURABLE/VISIBLE, and REVOKES the uncommitted TID (tid_next - 1):
// the allocator had already handed that TID out at accept time, but since
// the op never reached DURABLE the TID is returned so that resubmitting
// the interrupted descriptor commits under the SAME TID (recovery
// consistency, same-TID resubmit). No-op while IDLE/COMPLETE (no TID
// outstanding there).
// ---------------------------------------------------------------------------

`timescale 1ns / 1ps

module durable_tid_v0 #(
  parameter COMMIT_LATENCY = 2  // cycles spent in COMMIT (persistence
                                        // barrier model; also the HPS fault-
                                        // injection window for reset mid-commit)
) (
  input                clk,
  input                reset_n,
  input                fsm_reset_i,
  input         [11:0] avs_address,
  input         [31:0] avs_writedata,
  output reg    [31:0] avs_readdata,
  input                avs_read,
  input                avs_write,
  input         [3:0]  avs_byteenable,
  output               avs_waitrequest,
  output               avs_readdatavalid,
  output               trusted_complete_o,
  output        [63:0] durable_tid_o,
  output               busy_o
);

  // Word indices (byte offset >> 2).
  localparam W_EPOCH    = 12'h000 >> 2;
  localparam W_REQ_LO   = 12'h004 >> 2;
  localparam W_PEND_LO  = 12'h008 >> 2;
  localparam W_DUR_LO   = 12'h00C >> 2;
  localparam W_VIS_LO   = 12'h010 >> 2;
  localparam W_FSM      = 12'h014 >> 2;
  localparam W_ERROR    = 12'h018 >> 2;
  localparam W_PROG     = 12'h01C >> 2;
  localparam W_RSTCNT   = 12'h020 >> 2;
  localparam W_CTRL     = 12'h024 >> 2;
  localparam W_STATUS   = 12'h028 >> 2;
  localparam W_DESC0    = 12'h02C >> 2;
  localparam W_DESC1    = 12'h030 >> 2;
  localparam W_DESC_CRC = 12'h034 >> 2;
  localparam W_CRC_CALC = 12'h038 >> 2;
  localparam W_TID_LO   = 12'h03C >> 2;
  localparam W_TID_HI   = 12'h040 >> 2;
  localparam W_REQ_HI   = 12'h044 >> 2;
  localparam W_DUR_HI   = 12'h048 >> 2;
  localparam W_VIS_HI   = 12'h04C >> 2;
  localparam W_PEND_HI  = 12'h050 >> 2;
  localparam W_MAGIC    = 12'h054 >> 2;
  localparam W_VERSION  = 12'h058 >> 2;

  localparam [31:0] MAGIC_VAL   = 32'h44555230; // "DUR0"
  localparam [31:0] VERSION_VAL = 32'h00000000; // v0

  // FSM encoding (3 bits: S_CRC added 2026-09-25 for the pipelined
  // CRC -- stage 1 registers the first-half CRC in S_SUBMIT, stage 2
  // chains bytes 8..15 and gates in S_CRC. Exposed in FSM_STATE low 3
  // bits; IDLE is still 0 so idle/busy checks are unchanged.)
  localparam [2:0] S_IDLE     = 3'd0;
  localparam [2:0] S_SUBMIT   = 3'd1;
  localparam [2:0] S_CRC      = 3'd2;
  localparam [2:0] S_COMMIT   = 3'd3;
  localparam [2:0] S_COMPLETE = 3'd4;

  // ERROR bit positions.
  localparam E_CRC    = 0;
  localparam E_DUP    = 1;
  localparam E_GAP    = 2;
  localparam E_MALF   = 3;
  localparam E_RSTMID = 4;
  localparam E_OVF    = 5;

  // State.
  reg [31:0] epoch;
  reg [31:0] req_lo, req_hi;
  reg [63:0] tid_next;    // monotonic allocator: next TID to hand out
  reg [63:0] pending;     // accepted but not yet durable
  reg [63:0] durable;     // PERSISTENT watermark (monotonic)
  reg [63:0] visible;     // completion/visible watermark (never regresses)
  reg [63:0] tid_last;    // last committed TID
  reg [2:0]  state;       // 3 bits: S_CRC added for the pipelined CRC
  reg [31:0] error;       // sticky, only low 6 bits used
  reg [31:0] progress_cnt;
  reg [31:0] reset_cnt;
  reg [31:0] ctrl;        // only low 3 bits used
  reg        complete_sticky;
  reg        crc_ok_last;
  reg [31:0] desc0, desc1, desc_crc;
  reg [31:0] crc_calc;
  reg [31:0] crc_mid_q;   // registered CRC over descriptor bytes 0..7
  reg [1:0]  commit_hold; // COMMIT latency countdown
  // Read pipeline: stage 1 registers address+read; the mux below
  // selects from the STABLE stage-1 address; stage 2 (clocked block)
  // registers the word into avs_readdata with readdatavalid delayed to
  // match. Reads complete 2 cycles after the request (host polls at ms
  // scale; see rtl/README.md).
  reg [9:0]  rd_addr_q;
  reg        rd_en_q;
  reg        readdatavalid_q;
  reg        trusted_q;

  // Latched submit image validated in SUBMIT/S_CRC.
  reg [31:0] lat_d0, lat_d1, lat_req, lat_ep, lat_crc;
  reg [63:0] lat_tid;

  // Next-state temps: combinational D-input muxes (`d = en ? new : q`).
  // The clocked block assigns every register UNCONDITIONALLY from its
  // *_n temp, so the flow infers plain DFFs (no CE pins) on this
  // datapath and the enable/cloud logic stays in LUTs ahead of D.
  // (Timing closure, 2026-09-25: an ALU-carry + wide mux cloud sinking
  // at a DFFCE CE input was the 50 MHz critical path; see README.)
  reg [31:0] epoch_n, req_lo_n, req_hi_n;
  reg [63:0] tid_next_n, pending_n, durable_n, visible_n, tid_last_n;
  reg [2:0]  state_n;
  reg [31:0] ctrl_n;
  reg [31:0] err_n;
  reg [63:0] req_full;
  reg [31:0] progress_cnt_n, reset_cnt_n;
  reg        complete_sticky_n, crc_ok_last_n;
  reg [31:0] desc0_n, desc1_n, desc_crc_n, crc_calc_n, crc_mid_n;
  reg [1:0]  commit_hold_n;
  reg [31:0] readdata_n, rd_mux;
  reg [9:0]  rd_addr_n;
  reg        rd_en_n, readdatavalid_n, trusted_n;
  reg [31:0] lat_d0_n, lat_d1_n, lat_req_n, lat_ep_n, lat_crc_n;
  reg [63:0] lat_tid_n;
  reg        soft_rst;

  // Byte-enable expanded to a 32-bit write mask.
  reg [31:0] wmask;
  always @(*) begin
    wmask = 32'h00000000;
    if (avs_byteenable[0]) wmask[7:0]   = 8'hFF;
    if (avs_byteenable[1]) wmask[15:8]  = 8'hFF;
    if (avs_byteenable[2]) wmask[23:16] = 8'hFF;
    if (avs_byteenable[3]) wmask[31:24] = 8'hFF;
  end

  wire [9:0] widx     = avs_address[11:2];
  wire       wr_en    = avs_write; // waitrequest tied 0: every write takes
  wire       wr_ctrl  = wr_en && (widx[9:0] == W_CTRL[9:0]);
  // A new SUBMIT arrives on this cycle only if the write actually sets bit 0.
  wire       wr_ctrl0 = wr_ctrl && wmask[0] && avs_writedata[0];

  assign avs_waitrequest   = 1'b0;
  assign avs_readdatavalid = readdatavalid_q;
  assign trusted_complete_o = trusted_q;
  assign durable_tid_o     = durable;
  assign busy_o            = (state != S_IDLE);

  // CRC-32 (IEEE 802.3): poly 0x04C11DB7 reflected (0xEDB88320),
  // init 0xFFFFFFFF, refin/refout, xorout 0xFFFFFFFF. No SHA anywhere.
  //
  // Pipelined over 2 stages for 50 MHz timing closure (2026-09-25):
  // crc32_blk processes one 8-byte half with no init/invert; S_SUBMIT
  // registers the first half (bytes 0..7 = {DESC1,DESC0}) into
  // crc_mid_q, S_CRC chains the second half (bytes 8..15 =
  // {EPOCH,REQ_LO}) and compares ~result against DESC_CRC. Chained
  // halves are bit-identical to the single 16-byte pass (same
  // polynomial, same LSB-first byte order); only the commit latency
  // grows by 1 cycle (see rtl/README.md).
  function [31:0] crc32_blk;
    input [31:0] crc_in;
    input [63:0] data;
    reg [31:0] crc;
    integer i, j;
    begin
      crc = crc_in;
      for (i = 0; i < 8; i = i + 1) begin
        crc = crc ^ {24'h000000, data[i*8 +: 8]};
        for (j = 0; j < 8; j = j + 1) begin
          if (crc[0])
            crc = (crc >> 1) ^ 32'hEDB88320;
          else
            crc = (crc >> 1);
        end
      end
      crc32_blk = crc;
    end
  endfunction

  wire [31:0] crc_mid_comb = crc32_blk(32'hFFFFFFFF, {lat_d1, lat_d0});
  wire [31:0] crc_fin_comb = crc32_blk(crc_mid_q, {lat_ep, lat_req});

  localparam [1:0] COMMIT_HOLD_INIT = COMMIT_LATENCY;

  // Read datapath, registered in 2 stages (timing closure,
  // 2026-09-25): stage 1 (clocked block) registers address+read; the
  // mux below selects from the STABLE stage-1 address; stage 2
  // registers the selected word into avs_readdata with
  // avs_readdatavalid delayed to match. Map, byte order, and values
  // are unchanged -- only the latency grows (2 cycles after request).
  always @(*) begin
    case (rd_addr_q)
      W_EPOCH:    rd_mux = epoch;
      W_REQ_LO:   rd_mux = req_lo;
      W_PEND_LO:  rd_mux = pending[31:0];
      W_DUR_LO:   rd_mux = durable[31:0];
      W_VIS_LO:   rd_mux = visible[31:0];
      W_FSM:      rd_mux = {29'd0, state};
      W_ERROR:    rd_mux = error;
      W_PROG:     rd_mux = progress_cnt;
      W_RSTCNT:   rd_mux = reset_cnt;
      W_CTRL:     rd_mux = ctrl;
      W_STATUS:   rd_mux = {28'h0000000, busy_o, crc_ok_last,
                            complete_sticky, busy_o};
      W_DESC0:    rd_mux = desc0;
      W_DESC1:    rd_mux = desc1;
      W_DESC_CRC: rd_mux = desc_crc;
      W_CRC_CALC: rd_mux = crc_calc;
      W_TID_LO:   rd_mux = tid_last[31:0];
      W_TID_HI:   rd_mux = tid_last[63:32];
      W_REQ_HI:   rd_mux = req_hi;
      W_DUR_HI:   rd_mux = durable[63:32];
      W_VIS_HI:   rd_mux = visible[63:32];
      W_PEND_HI:  rd_mux = pending[63:32];
      W_MAGIC:    rd_mux = MAGIC_VAL;
      W_VERSION:  rd_mux = VERSION_VAL;
      default:    rd_mux = 32'h00000000;
    endcase
  end

  // Next-state block: every *_n temp defaults to HOLD (`d = q`),
  // then write/FSM logic overrides with new values (`d = new_val`).
  // Single-assignment temps for registers driven from both the write
  // decoder and the FSM (ctrl_n / err_n as before, extended to all).
  always @(*) begin
    epoch_n           = epoch;
    req_lo_n          = req_lo;
    req_hi_n          = req_hi;
    tid_next_n        = tid_next;
    pending_n         = pending;
    durable_n         = durable;
    visible_n         = visible;
    tid_last_n        = tid_last;
    state_n           = state;
    ctrl_n            = ctrl;
    err_n             = error;
    req_full          = {req_hi, req_lo};
    progress_cnt_n    = progress_cnt;
    reset_cnt_n       = reset_cnt;
    complete_sticky_n = complete_sticky;
    crc_ok_last_n     = crc_ok_last;
    desc0_n           = desc0;
    desc1_n           = desc1;
    desc_crc_n        = desc_crc;
    crc_calc_n        = crc_calc;
    crc_mid_n         = crc_mid_q;
    commit_hold_n     = commit_hold;
    readdata_n        = avs_readdata;
    rd_addr_n         = rd_addr_q;
    rd_en_n           = rd_en_q;
    readdatavalid_n   = readdatavalid_q;
    trusted_n         = trusted_q;
    lat_d0_n          = lat_d0;
    lat_d1_n          = lat_d1;
    lat_req_n         = lat_req;
    lat_ep_n          = lat_ep;
    lat_crc_n         = lat_crc;
    lat_tid_n         = lat_tid;

    soft_rst = fsm_reset_i || (ctrl[1] && !wr_ctrl);

    if (soft_rst) begin
      // --- soft reset: park FSM, drop in-flight, keep history --------
      // (second term: previously written CTRL.SOFT_RST bit still set).
      // The read pipeline and pulse outputs HOLD (untouched, as before:
      // the old clocked branch assigned nothing to them here either).
      state_n       = S_IDLE;
      ctrl_n        = 32'h00000000;
      pending_n     = durable; // in-flight never surfaces as durable
      reset_cnt_n   = reset_cnt + 32'h00000001;
      commit_hold_n = 2'd0;
      if (state == S_SUBMIT || state == S_CRC || state == S_COMMIT) begin
        err_n[E_RSTMID] = 1'b1;
        // Revoke the uncommitted TID handed out at accept time so a
        // resubmit of the dropped descriptor is accepted under the SAME
        // TID (recovery consistency). No underflow: SUBMIT/S_CRC/COMMIT
        // are reachable only after an accept, implying tid_next >= 1.
        tid_next_n = tid_next - 64'h0000000000000001;
      end
    end else begin
      // --- read pipeline advances (frozen under soft reset above) ----
      rd_addr_n       = widx;
      rd_en_n         = avs_read;
      readdata_n      = rd_mux;
      readdatavalid_n = rd_en_q;
      trusted_n       = 1'b0; // default: pulse only in COMPLETE

      // --- register writes -------------------------------------------
      if (wr_en) begin
        case (widx)
          W_EPOCH:    epoch_n    = (epoch    & ~wmask) | (avs_writedata & wmask);
          W_REQ_LO:   req_lo_n   = (req_lo   & ~wmask) | (avs_writedata & wmask);
          W_REQ_HI:   req_hi_n   = (req_hi   & ~wmask) | (avs_writedata & wmask);
          W_DESC0:    desc0_n    = (desc0    & ~wmask) | (avs_writedata & wmask);
          W_DESC1:    desc1_n    = (desc1    & ~wmask) | (avs_writedata & wmask);
          W_DESC_CRC: desc_crc_n = (desc_crc & ~wmask) | (avs_writedata & wmask);
          W_CTRL: begin
            // Reserved bits never stick in the register (masked to the
            // low 3), but setting them flags MALFORMED.
            ctrl_n = ((ctrl_n & ~wmask) | (avs_writedata & wmask))
                     & 32'h00000007;
            if (|(avs_writedata & wmask & 32'hFFFFFFF8))
              err_n[E_MALF] = 1'b1; // reserved CTRL bits written
          end
          W_ERROR:    err_n = err_n & ~(avs_writedata & wmask); // rw1c
          default: begin
            // read-only / unmapped: writes ignored, no side effect.
          end
        endcase
        // NOTE: no same-cycle REQ fixup here on purpose. The HPS protocol
        // (descriptor words first, CTRL.SUBMIT after) guarantees settled
        // registers at accept time, and one Avalon write per cycle makes
        // a same-cycle REQ+SUBMIT collision impossible. Validating the
        // settled {req_hi,req_lo} keeps a colliding second submit from
        // corrupting the accept check for the pending op.
      end

      // --- RECOVER strobe ---------------------------------------------
      if (ctrl_n[2]) begin
        complete_sticky_n = 1'b0;
        ctrl_n[2]         = 1'b0;
      end

      // --- commit FSM ---------------------------------------------------
      case (state)
        S_IDLE: begin
          if (ctrl[0] || wr_ctrl0) begin
            // A submit is pending (previously latched) and/or arriving
            // on this very cycle. Accept at most one; a collision is
            // queue-full backpressure: accept the pending op, flag the
            // redundant arrival, in-flight work unaffected.
            ctrl_n[0] = 1'b0;
            if (ctrl[0] && wr_ctrl0)
              err_n[E_MALF] = 1'b1;
            if (req_hi != tid_next[63:32]) begin
              err_n[E_MALF] = 1'b1;  // high-half jump: malformed, not gap
            end else if (req_full != tid_next) begin
              if (req_full <= durable)
                err_n[E_DUP] = 1'b1;  // duplicate / replay
              else if (req_full > tid_next)
                err_n[E_GAP] = 1'b1;  // same high half, ahead of allocator
              else
                err_n[E_DUP] = 1'b1;  // in-flight replay
            end else if (&tid_next) begin
              err_n[E_OVF] = 1'b1;    // allocator would wrap
            end else begin
              // Latch the submit image; validate in SUBMIT/S_CRC.
              lat_d0_n  = desc0;
              lat_d1_n  = desc1;
              lat_req_n = req_lo;
              lat_ep_n  = epoch;
              lat_crc_n = desc_crc;
              lat_tid_n = tid_next;
              state_n   = S_SUBMIT;
            end
          end
        end
        S_SUBMIT: begin
          // CRC stage 1: register the first-half CRC over bytes 0..7;
          // the gate completes in S_CRC.
          crc_mid_n = crc_mid_comb;
          state_n   = S_CRC;
          if (ctrl_n[0]) begin
            ctrl_n[0]     = 1'b0;
            err_n[E_MALF] = 1'b1; // submit-while-busy: rejected
          end
        end
        S_CRC: begin
          // CRC stage 2: chain bytes 8..15 and gate on the full CRC.
          crc_calc_n = ~crc_fin_comb;
          if (ctrl_n[0]) begin
            ctrl_n[0]     = 1'b0;
            err_n[E_MALF] = 1'b1; // submit-while-busy: rejected
          end
          if (~crc_fin_comb == lat_crc) begin
            crc_ok_last_n = 1'b1;
            // Watermarks are COUNTS (highest durable TID + 1): the accepted
            // TID lat_tid surfaces as lat_tid+1 in PENDING/DURABLE/VISIBLE,
            // matching what the HPS harness oracle compares (count of
            // committed ops). tid_last keeps the 0-based TID (see COMPLETE).
            pending_n     = lat_tid + 64'h0000000000000001;
            tid_next_n    = tid_next + 64'h0000000000000001;
            commit_hold_n = COMMIT_HOLD_INIT;
            state_n       = S_COMMIT;
          end else begin
            crc_ok_last_n = 1'b0;
            err_n[E_CRC]  = 1'b1;
            state_n       = S_IDLE;
          end
        end
        S_COMMIT: begin
          // Persistence barrier model. DURABLE advances here and only
          // here; a soft reset in this state drops the op instead.
          if (commit_hold == 2'd0) begin
            durable_n = pending; // PERSISTENT(N) established
            state_n   = S_COMPLETE;
          end else begin
            commit_hold_n = commit_hold - 2'd1;
          end
          if (ctrl_n[0]) begin
            ctrl_n[0]     = 1'b0;
            err_n[E_MALF] = 1'b1; // submit-while-busy: rejected
          end
        end
        S_COMPLETE: begin
          // TRUSTED_COMPLETE(N) asserted only with DURABLE == N already
          // persistent (written in S_COMMIT the previous cycle(s)).
          visible_n         = durable;
          tid_last_n        = lat_tid; // 0-based TID; watermarks hold +1
          complete_sticky_n = 1'b1;
          progress_cnt_n    = progress_cnt + 32'h00000001;
          trusted_n         = 1'b1;
          state_n           = S_IDLE;
          if (ctrl_n[0]) begin
            ctrl_n[0]     = 1'b0;
            err_n[E_MALF] = 1'b1; // submit-while-busy: rejected
          end
        end
        default: begin
          state_n = S_IDLE;
        end
      endcase
    end
  end

  // Clocked block: unconditional D-mux loads ONLY (no inferred CE).
  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      epoch           <= 32'h00000000;
      req_lo          <= 32'h00000000;
      req_hi          <= 32'h00000000;
      tid_next        <= 64'h0000000000000000;
      pending         <= 64'h0000000000000000;
      durable         <= 64'h0000000000000000;
      visible         <= 64'h0000000000000000;
      tid_last        <= 64'h0000000000000000;
      state           <= S_IDLE;
      error           <= 32'h00000000;
      progress_cnt    <= 32'h00000000;
      reset_cnt       <= 32'h00000000;
      ctrl            <= 32'h00000000;
      complete_sticky <= 1'b0;
      crc_ok_last     <= 1'b0;
      desc0           <= 32'h00000000;
      desc1           <= 32'h00000000;
      desc_crc        <= 32'h00000000;
      crc_calc        <= 32'h00000000;
      crc_mid_q       <= 32'h00000000;
      commit_hold     <= 2'd0;
      avs_readdata    <= 32'h00000000;
      rd_addr_q       <= 10'h000;
      rd_en_q         <= 1'b0;
      readdatavalid_q <= 1'b0;
      trusted_q       <= 1'b0;
      lat_d0          <= 32'h00000000;
      lat_d1          <= 32'h00000000;
      lat_req         <= 32'h00000000;
      lat_ep          <= 32'h00000000;
      lat_crc         <= 32'h00000000;
      lat_tid         <= 64'h0000000000000000;
    end else begin
      epoch           <= epoch_n;
      req_lo          <= req_lo_n;
      req_hi          <= req_hi_n;
      tid_next        <= tid_next_n;
      pending         <= pending_n;
      durable         <= durable_n;
      visible         <= visible_n;
      tid_last        <= tid_last_n;
      state           <= state_n;
      error           <= err_n & 32'h0000003F; // reserved bits read 0
      progress_cnt    <= progress_cnt_n;
      reset_cnt       <= reset_cnt_n;
      ctrl            <= ctrl_n;
      complete_sticky <= complete_sticky_n;
      crc_ok_last     <= crc_ok_last_n;
      desc0           <= desc0_n;
      desc1           <= desc1_n;
      desc_crc        <= desc_crc_n;
      crc_calc        <= crc_calc_n;
      crc_mid_q       <= crc_mid_n;
      commit_hold     <= commit_hold_n;
      avs_readdata    <= readdata_n;
      rd_addr_q       <= rd_addr_n;
      rd_en_q         <= rd_en_n;
      readdatavalid_q <= readdatavalid_n;
      trusted_q       <= trusted_n;
      lat_d0          <= lat_d0_n;
      lat_d1          <= lat_d1_n;
      lat_req         <= lat_req_n;
      lat_ep          <= lat_ep_n;
      lat_crc         <= lat_crc_n;
      lat_tid         <= lat_tid_n;
    end
  end

endmodule
