// SPDX-License-Identifier: Apache-2.0
// durable_tid_v0_tb.sv -- self-checking testbench for durable_tid_v0.
//
// Covers: N good submits, duplicate, replay of an old seq, gap seq,
// malformed vectors (bad CRC, reserved CTRL bits, REQ_HI mismatch),
// submit-while-busy backpressure, reset mid-commit (in COMMIT hold window),
// reset while idle, and recovery resubmit under the same TID.
//
// Always-on monitors assert the two load-bearing properties:
//   (1) TRUSTED_COMPLETE(N) => PERSISTENT(N): on every trusted_complete_o
//       pulse, durable_tid_o equals the just-committed TID.
//   (2) Monotonicity: durable and visible never regress.
//
// Style is a conservative SystemVerilog-2012 subset (no classes, mailboxes,
// break/continue, or string type) so it runs on ANY simulator. Reference:
//   iverilog -g2012 -o sim durable_tid_v0.sv durable_tid_v0_tb.sv && ./sim
// Exit banner is `$display PASS/FAIL` + `$finish`.
//
// NOTE: this TB assumes the default COMMIT_LATENCY=2 for the reset
// mid-commit injection window (see TEST 6).

`timescale 1ns / 1ps

module durable_tid_v0_tb;

  // Byte offsets (must match rtl/durable_tid_v0.sv header map).
  localparam [11:0] A_EPOCH    = 12'h000;
  localparam [11:0] A_REQ_LO   = 12'h004;
  localparam [11:0] A_PEND_LO  = 12'h008;
  localparam [11:0] A_DUR_LO   = 12'h00C;
  localparam [11:0] A_VIS_LO   = 12'h010;
  localparam [11:0] A_FSM      = 12'h014;
  localparam [11:0] A_ERROR    = 12'h018;
  localparam [11:0] A_PROG     = 12'h01C;
  localparam [11:0] A_RSTCNT   = 12'h020;
  localparam [11:0] A_CTRL     = 12'h024;
  localparam [11:0] A_STATUS   = 12'h028;
  localparam [11:0] A_DESC0    = 12'h02C;
  localparam [11:0] A_DESC1    = 12'h030;
  localparam [11:0] A_DESC_CRC = 12'h034;
  localparam [11:0] A_CRC_CALC = 12'h038;
  localparam [11:0] A_TID_LO   = 12'h03C;
  localparam [11:0] A_TID_HI   = 12'h040;
  localparam [11:0] A_REQ_HI   = 12'h044;
  localparam [11:0] A_DUR_HI   = 12'h048;
  localparam [11:0] A_VIS_HI   = 12'h04C;
  localparam [11:0] A_PEND_HI  = 12'h050;

  localparam CTRL_SUBMIT  = 32'h00000001;
  localparam CTRL_RECOVER = 32'h00000004;

  // ERROR bits (must match DUT).
  localparam E_CRC = 0, E_DUP = 1, E_GAP = 2, E_MALF = 3, E_RSTMID = 4;

  reg         clk;
  reg         reset_n;
  reg         fsm_reset_i;
  reg  [11:0] avs_address;
  reg  [31:0] avs_writedata;
  wire [31:0] avs_readdata;
  reg         avs_read;
  reg         avs_write;
  reg  [3:0]  avs_byteenable;
  wire        avs_waitrequest;
  wire        avs_readdatavalid;
  wire        trusted_complete_o;
  wire [63:0] durable_tid_o;
  wire        busy_o;

  durable_tid_v0 dut (
    .clk                (clk),
    .reset_n            (reset_n),
    .fsm_reset_i        (fsm_reset_i),
    .avs_address        (avs_address),
    .avs_writedata      (avs_writedata),
    .avs_readdata       (avs_readdata),
    .avs_read           (avs_read),
    .avs_write          (avs_write),
    .avs_byteenable     (avs_byteenable),
    .avs_waitrequest    (avs_waitrequest),
    .avs_readdatavalid  (avs_readdatavalid),
    .trusted_complete_o (trusted_complete_o),
    .durable_tid_o      (durable_tid_o),
    .busy_o             (busy_o)
  );

  // 100 MHz clock.
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Same CRC-32/IEEE algorithm as the DUT (intentional duplication: the
  // differential cross-check against an INDEPENDENT implementation, e.g. a
  // software oracle, happens in hps/harness.c, not here).
  function [31:0] tb_crc32(input [127:0] data);
    reg [31:0] crc;
    integer i, j;
    begin
      crc = 32'hFFFFFFFF;
      for (i = 0; i < 16; i = i + 1) begin
        crc = crc ^ {24'h000000, data[i*8 +: 8]};
        for (j = 0; j < 8; j = j + 1) begin
          if (crc[0])
            crc = (crc >> 1) ^ 32'hEDB88320;
          else
            crc = (crc >> 1);
        end
      end
      tb_crc32 = ~crc;
    end
  endfunction

  // Scoreboard.
  integer checks_passed;
  integer checks_failed;
  integer mon_trusted_cnt;
  reg [63:0] mon_last_d;
  reg [63:0] mon_last_v;
  reg         mon_armed;

  task check(input [8*56-1:0] name, input cond);
    begin
      if (cond) begin
        checks_passed = checks_passed + 1;
        $display("[PASS] %0s", name);
      end else begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] %0s", name);
      end
    end
  endtask

  // Always-on property monitors.
  // (1) TRUSTED_COMPLETE(N) => PERSISTENT(N).
  // (2) durable / visible never regress.
  always @(posedge clk) begin
    if (mon_armed) begin
      if (trusted_complete_o) begin
        mon_trusted_cnt = mon_trusted_cnt + 1;
        if (durable_tid_o !== dut.tid_last) begin
          checks_failed = checks_failed + 1;
          $display("[FAIL] invariant TRUSTED_COMPLETE=>PERSISTENT violated: durable=%h tid_last=%h",
                   durable_tid_o, dut.tid_last);
        end
      end
      if (dut.durable < mon_last_d) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: durable regressed %h -> %h",
                 mon_last_d, dut.durable);
      end
      if (dut.visible < mon_last_v) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: visible regressed %h -> %h",
                 mon_last_v, dut.visible);
      end
      mon_last_d = dut.durable;
      mon_last_v = dut.visible;
    end
  end

  // Avalon-MM single-cycle helpers (drive on negedge, DUT samples posedge).
  task mm_write(input [11:0] addr, input [31:0] data);
    begin
      @(negedge clk);
      avs_address    = addr;
      avs_writedata  = data;
      avs_byteenable = 4'hF;
      avs_write      = 1'b1;
      @(negedge clk);
      avs_write      = 1'b0;
    end
  endtask

  task mm_read(input [11:0] addr, output [31:0] data);
    begin
      @(negedge clk);
      avs_address = addr;
      avs_read    = 1'b1;
      @(negedge clk);
      avs_read    = 1'b0;
      data        = avs_readdata; // mux is combinational; addr still held
    end
  endtask

  // Poll STATUS.BUSY==0. ok=1 on success, ok=0 on 100-poll timeout.
  task wait_idle(output ok);
    reg [31:0] st;
    integer i;
    begin : poll
      ok = 1'b0;
      for (i = 0; i < 100; i = i + 1) begin
        mm_read(A_STATUS, st);
        if (!st[0]) begin
          ok = 1'b1;
          disable poll;
        end
      end
    end
  endtask

  // Read the 64-bit durable watermark.
  task read_durable(output [63:0] d);
    reg [31:0] lo, hi;
    begin
      mm_read(A_DUR_LO, lo);
      mm_read(A_DUR_HI, hi);
      d = {hi, lo};
    end
  endtask

  task read_visible(output [63:0] v);
    reg [31:0] lo, hi;
    begin
      mm_read(A_VIS_LO, lo);
      mm_read(A_VIS_HI, hi);
      v = {hi, lo};
    end
  endtask

  // Submit one well-formed descriptor for sequence req with epoch ep.
  // bad_crc=1 corrupts the CRC word (malformed vector).
  task submit_one(input [31:0] req, input [31:0] d0, input [31:0] d1,
                  input [31:0] ep, input bad_crc);
    reg [31:0] crc;
    begin
      crc = tb_crc32({ep, req, d1, d0});
      if (bad_crc)
        crc = ~crc;
      mm_write(A_DESC0, d0);
      mm_write(A_DESC1, d1);
      mm_write(A_REQ_LO, req);
      mm_write(A_REQ_HI, 32'h00000000);
      mm_write(A_DESC_CRC, crc);
      mm_write(A_CTRL, CTRL_SUBMIT);
    end
  endtask

  task clear_errors;
    begin
      mm_write(A_ERROR, 32'h0000003F); // rw1c: clear all defined bits
    end
  endtask

  // Test temporaries (module scope: tasks cannot declare them portably).
  reg [31:0] t_lo, t_hi, t_err, t_st, t_fsm, t_magic, t_ver, t_crc;
  reg [63:0] t_d, t_v;
  reg         t_ok;
  integer     k;
  integer     pulses_before;

  initial begin
    checks_passed   = 0;
    checks_failed   = 0;
    mon_trusted_cnt = 0;
    mon_last_d      = 64'h0;
    mon_last_v      = 64'h0;
    mon_armed       = 1'b0;
    avs_address     = 12'h0;
    avs_writedata   = 32'h0;
    avs_read        = 1'b0;
    avs_write       = 1'b0;
    avs_byteenable  = 4'hF;
    fsm_reset_i     = 1'b0;

    // Global reset.
    reset_n = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);
    mon_armed = 1'b1;

    // TEST 0: identity / post-reset state.
    mm_read(A_MAGIC, t_magic);
    check("T0 magic reads DUR0", t_magic == 32'h44555230);
    mm_read(A_VERSION, t_ver);
    check("T0 version is v0", t_ver == 32'h00000000);
    read_durable(t_d);
    check("T0 durable zero after reset", t_d == 64'h0);
    mm_read(A_ERROR, t_err);
    check("T0 no errors after reset", t_err == 32'h0);

    // TEST 1: set epoch, submit N=8 good descriptors; durable tracks 1:1.
    mm_write(A_EPOCH, 32'h00000001);
    mm_read(A_EPOCH, t_lo);
    check("T1 epoch readback", t_lo == 32'h00000001);
    for (k = 0; k < 8; k = k + 1) begin
      submit_one(k[31:0], 32'hA0000000 + k[31:0], 32'hB0000000 + k[31:0],
                 32'h00000001, 1'b0);
      wait_idle(t_ok);
      if (!t_ok) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] T1 op %0d timed out waiting idle", k);
      end
      read_durable(t_d);
      if (t_d != (k + 1)) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] T1 op %0d durable=%h expected %h", k, t_d, k + 1);
      end
      read_visible(t_v);
      if (t_v != t_d) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] T1 op %0d visible=%h durable=%h", k, t_v, t_d);
      end
    end
    mm_read(A_PROG, t_lo);
    check("T1 progress == 8", t_lo == 32'h00000008);
    mm_read(A_ERROR, t_err);
    check("T1 no errors on good submits", t_err == 32'h0);
    mm_read(A_STATUS, t_st);
    check("T1 complete_sticky set", t_st[1] == 1'b1);
    mm_write(A_CTRL, CTRL_RECOVER);
    mm_read(A_STATUS, t_st);
    check("T1 recover clears sticky", t_st[1] == 1'b0);
    check("T1 8 trusted pulses observed", mon_trusted_cnt == 8);

    // TEST 2: duplicate submit (same seq 7 again) -> DUP, durable held.
    pulses_before = mon_trusted_cnt;
    submit_one(32'h00000007, 32'hA0000007, 32'hB0000007, 32'h00000001, 1'b0);
    wait_idle(t_ok);
    check("T2 dup wait idle ok", t_ok == 1'b1);
    mm_read(A_ERROR, t_err);
    check("T2 DUP flagged", t_err[E_DUP] == 1'b1);
    read_durable(t_d);
    check("T2 durable held at 8", t_d == 64'h8);
    check("T2 no new trusted pulse", mon_trusted_cnt == pulses_before);
    clear_errors;

    // TEST 3: replay of an old seq (5) -> DUP, durable held.
    submit_one(32'h00000005, 32'hA0000005, 32'hB0000005, 32'h00000001, 1'b0);
    wait_idle(t_ok);
    mm_read(A_ERROR, t_err);
    check("T3 replay flagged DUP", t_err[E_DUP] == 1'b1);
    read_durable(t_d);
    check("T3 durable held at 8", t_d == 64'h8);
    clear_errors;

    // TEST 4: gap seq (durable+5 = 13) -> GAP, durable held.
    submit_one(32'h0000000D, 32'hDEADBEEF, 32'hCAFED00D, 32'h00000001, 1'b0);
    wait_idle(t_ok);
    mm_read(A_ERROR, t_err);
    check("T4 gap flagged GAP", t_err[E_GAP] == 1'b1);
    read_durable(t_d);
    check("T4 durable held at 8", t_d == 64'h8);
    clear_errors;

    // TEST 5a: bad CRC on next seq (8) -> CRC_ERR, durable held.
    submit_one(32'h00000008, 32'h11111111, 32'h22222222, 32'h00000001, 1'b1);
    wait_idle(t_ok);
    mm_read(A_ERROR, t_err);
    check("T5a bad CRC flagged", t_err[E_CRC] == 1'b1);
    read_durable(t_d);
    check("T5a durable held at 8", t_d == 64'h8);
    mm_read(A_STATUS, t_st);
    check("T5a crc_ok_last clear", t_st[2] == 1'b0);
    clear_errors;

    // TEST 5b: reserved CTRL bits -> MALFORMED.
    mm_write(A_CTRL, 32'hFFFFFFF8);
    mm_read(A_ERROR, t_err);
    check("T5b reserved CTRL bits flagged MALFORMED", t_err[E_MALF] == 1'b1);
    read_durable(t_d);
    check("T5b durable held at 8", t_d == 64'h8);
    clear_errors;

    // TEST 5c: REQ_HI mismatch -> MALFORMED.
    mm_write(A_REQ_LO, 32'h00000008);
    mm_write(A_REQ_HI, 32'hDEADBEEF);
    mm_write(A_DESC0, 32'h11111111);
    mm_write(A_DESC1, 32'h22222222);
    mm_write(A_DESC_CRC, tb_crc32({32'h00000001, 32'h00000008,
                                   32'h22222222, 32'h11111111}));
    mm_write(A_CTRL, CTRL_SUBMIT);
    wait_idle(t_ok);
    mm_read(A_ERROR, t_err);
    check("T5c REQ_HI mismatch flagged MALFORMED", t_err[E_MALF] == 1'b1);
    read_durable(t_d);
    check("T5c durable held at 8", t_d == 64'h8);
    clear_errors;

    // TEST 5d: good submit of seq 8 still works after malformed vectors.
    submit_one(32'h00000008, 32'h11111111, 32'h22222222, 32'h00000001, 1'b0);
    wait_idle(t_ok);
    read_durable(t_d);
    check("T5d durable advanced to 9", t_d == 64'h9);
    mm_read(A_ERROR, t_err);
    check("T5d no errors", t_err == 32'h0);

    // TEST 6: reset mid-commit. Submit seq 9, then hit fsm_reset_i for
    // exactly 1 cycle while the FSM sits in the COMMIT hold window
    // (COMMIT_LATENCY=2). The op must NOT become durable; the allocator
    // must be preserved so a resubmit commits under the same TID.
    begin
      reg [31:0] crc9;
      crc9 = tb_crc32({32'h00000001, 32'h00000009, 32'hB0000009, 32'hA0000009});
      mm_write(A_DESC0, 32'hA0000009);
      mm_write(A_DESC1, 32'hB0000009);
      mm_write(A_REQ_LO, 32'h00000009);
      mm_write(A_REQ_HI, 32'h00000000);
      mm_write(A_DESC_CRC, crc9);
      mm_write(A_CTRL, CTRL_SUBMIT);
      // Two posedges after the submit write returns: SUBMIT entry, then
      // COMMIT entry. Assert reset across the next posedge (COMMIT hold).
      @(posedge clk);
      @(posedge clk);
      fsm_reset_i = 1'b1;
      @(posedge clk);
      fsm_reset_i = 1'b0;
      wait_idle(t_ok);
      check("T6 wait idle ok after mid-commit reset", t_ok == 1'b1);
      mm_read(A_ERROR, t_err);
      check("T6 RESET_MIDCOMMIT flagged", t_err[E_RSTMID] == 1'b1);
      read_durable(t_d);
      check("T6 durable held at 9 (op dropped)", t_d == 64'h9);
      mm_read(A_PEND_LO, t_lo);
      mm_read(A_PEND_HI, t_hi);
      check("T6 pending parked at durable", {t_hi, t_lo} == 64'h9);
      mm_read(A_RSTCNT, t_lo);
      check("T6 reset counter incremented", t_lo == 32'h00000001);
      clear_errors;
      // Recovery: resubmit the identical descriptor; it must commit as
      // TID 9 (allocator preserved across soft reset).
      mm_write(A_DESC0, 32'hA0000009);
      mm_write(A_DESC1, 32'hB0000009);
      mm_write(A_REQ_LO, 32'h00000009);
      mm_write(A_REQ_HI, 32'h00000000);
      mm_write(A_DESC_CRC, crc9);
      mm_write(A_CTRL, CTRL_SUBMIT);
      wait_idle(t_ok);
      read_durable(t_d);
      check("T6 resubmit commits same TID (durable 10)", t_d == 64'hA);
      mm_read(A_TID_LO, t_lo);
      check("T6 tid_last == 9", t_lo == 32'h00000009);
      mm_read(A_ERROR, t_err);
      check("T6 no errors on resubmit", t_err == 32'h0);
    end

    // TEST 7: reset while idle. No RSTMID flag, counter++, history kept.
    fsm_reset_i = 1'b1;
    @(posedge clk);
    fsm_reset_i = 1'b0;
    repeat (2) @(posedge clk);
    mm_read(A_ERROR, t_err);
    check("T7 no RSTMID on idle reset", t_err[E_RSTMID] == 1'b0);
    mm_read(A_RSTCNT, t_lo);
    check("T7 reset counter == 2", t_lo == 32'h00000002);
    read_durable(t_d);
    check("T7 durable preserved (10)", t_d == 64'hA);
    mm_read(A_EPOCH, t_lo);
    check("T7 epoch preserved (1)", t_lo == 32'h00000001);
    clear_errors;

    // TEST 8: backpressure. Two submits on consecutive cycles: A must
    // commit, B (arriving while busy/pending) must be rejected + MALFORMED.
    begin
      mm_write(A_DESC0, 32'hA000000A);
      mm_write(A_DESC1, 32'hB000000A);
      mm_write(A_REQ_LO, 32'h0000000A);
      mm_write(A_REQ_HI, 32'h00000000);
      mm_write(A_DESC_CRC, tb_crc32({32'h00000001, 32'h0000000A,
                                     32'hB000000A, 32'hA000000A}));
      mm_write(A_CTRL, CTRL_SUBMIT); // op A
      mm_write(A_CTRL, CTRL_SUBMIT); // op B: collides at accept -> rejected
      wait_idle(t_ok);
      check("T8 wait idle ok", t_ok == 1'b1);
      read_durable(t_d);
      check("T8 exactly one commit (durable 11)", t_d == 64'hB);
      mm_read(A_ERROR, t_err);
      check("T8 MALFORMED flagged for B", t_err[E_MALF] == 1'b1);
      check("T8 no DUP/GAP/CRC side effects",
            (t_err & 32'h00000007) == 32'h00000000);
      clear_errors;
    end

    // TEST 9: monotonicity across a final burst + error-bit clearing.
    for (k = 11; k < 15; k = k + 1) begin
      submit_one(k[31:0], k[31:0] ^ 32'hAAAAAAAA, k[31:0] ^ 32'h55555555,
                 32'h00000001, 1'b0);
      wait_idle(t_ok);
    end
    read_durable(t_d);
    check("T9 durable == 15 after burst", t_d == 64'hF);
    read_visible(t_v);
    check("T9 visible == durable", t_v == t_d);
    mm_read(A_ERROR, t_err);
    check("T9 error register clearable and clear", t_err == 32'h0);
    mm_read(A_FSM, t_fsm);
    check("T9 FSM back in IDLE", t_fsm[1:0] == 2'd0);
    check("T9 trusted pulse count == completed ops",
          mon_trusted_cnt == 15);

    $display("----------------------------------------");
    $display("checks passed: %0d  failed: %0d", checks_passed, checks_failed);
    if (checks_failed == 0)
      $display("PASS");
    else
      $display("FAIL");
    $finish;
  end

endmodule
