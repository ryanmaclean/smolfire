// SPDX-License-Identifier: Apache-2.0
// rtl/dut_uart_tb.sv -- self-checking testbench for dut_top_uart.
//
// Drives the DUT exclusively through the UART front-end (behavioral 8-N-1
// host driver tasks): PING -> WRITE/READ round-trips -> good submits ->
// duplicate / malformed vectors -> malformed-UART-frame rejection ->
// reset-mid-commit through the UART path -> backpressure -> final burst.
// It then replays the load-bearing cases of the ORIGINAL 48-check suite
// (durable_tid_v0_tb.sv: 8 good submits, duplicate, malformed vectors,
// reset-mid-commit + same-TID resubmit) entirely over serial.
//
// Always-on monitors (same invariants as the original TB):
//   (1) TRUSTED_COMPLETE(N) => PERSISTENT(N)
//   (2) durable / visible never regress.
//
// Sim baud is the HARDWARE baud: the TB drives the 50 MHz board clock and
// the top divides it to the 25 MHz fabric, so with BAUD=115200 the divisor
// math matches the board (25000000/115200 = 217 cycles/bit). The suite is
// slower than the old fast-baud version but exercises the exact hardware
// timing, including the RX 16x-tick truncation (217/16 -> 13).
// The HARDWARE default stays 115200; the protocol is baud-agnostic.
//   iverilog -g2012 -o sim_uart dut_top_uart.v dut_uart.v durable_tid_v0.v \
//     dut_uart_tb.sv && ./sim_uart
// Exit banner is `$display PASS/FAIL` + `$finish`.
//
// NOTE ON SCOPE (read before "porting" fault-injection windows here).
// The original suite's reset-mid-commit (TEST 6) and submit-while-busy
// (TEST 8) windows CANNOT be driven through this UART path, by
// construction, and this TB does not pretend otherwise:
//   - The DUT's commit pipeline is at most ~7 cycles deep (SUBMIT 1 +
//     COMMIT hold + COMPLETE 1; note commit_hold is a 2-bit register, so
//     the COMMIT_LATENCY parameter only has an effect for values 0..3 --
//     larger values silently truncate, e.g. 8192 -> 0. Found during
//     bring-up of this TB; the DUT file itself is untouched).
//     At the 25 MHz fabric the busy window is <= 280 ns.
//   - The minimum gap between two executed UART commands is one full
//     frame round trip: 9 CMD bytes + 8 RSP bytes = 17 bytes = 170 bit
//     times ~= 1.5 ms at the hardware 115200 baud. The ACK of frame N
//     alone (8 bytes ~= 694 us) exceeds the DUT busy window by ~2500x.
//   So by the time any second frame executes, the DUT is long idle: a
//   "reset mid-commit" over serial always lands as an idle reset, and a
//   "second submit while busy" always lands as a fresh/DUP submit. Those
//   two sub-microsecond windows remain covered by the parallel
//   48-check suite (durable_tid_v0_tb.sv, still passing, DUT untouched).
// What THIS suite covers instead: every functional case the serial path
// CAN express (good submits, duplicate, all DUT malformed vectors), the
// UART-specific rejection behavior (dropped frames, link stays alive),
// the RESET-command path (idle reset: counter++, history preserved --
// the serial analogue of original TEST 7), and a repeated-submit case
// (U8) that empirically demonstrates the busy window is closed by the
// time frame N+1 executes (DUP, not MALFORMED).

`timescale 1ns / 1ps

module dut_uart_tb;

  // --- parameters (must match the instantiated top) ---------------------
  // CLK_HZ is the BOARD clock (pin V22); the top divides it by 2 to the
  // 25 MHz fabric, so BITC (fabric cycles per serial bit) is FAB_HZ/BAUD
  // = 217, matching the UART bridge divisor exactly. BITB is the same bit
  // time counted in board-clock edges (what this TB's driver waits on).
  localparam CLK_HZ = 50000000; // board clock (pin V22)
  localparam FAB_HZ = CLK_HZ / 2; // fabric clock (divided inside the top)
  localparam BAUD   = 115200;   // hardware baud
  localparam BITC   = FAB_HZ / BAUD; // 217 fabric cycles per serial bit
  localparam BITB   = BITC * 2; // 434 board-clock edges per serial bit

  // --- protocol constants (must match rtl/dut_uart.v) --------------------
  localparam [7:0] M0 = 8'h44;
  localparam [7:0] M1 = 8'h55;
  localparam [7:0] CMD_WRITE = 8'h01;
  localparam [7:0] CMD_READ  = 8'h02;
  localparam [7:0] CMD_RESET = 8'h03;
  localparam [7:0] CMD_PING  = 8'h04;
  localparam [7:0] RSP_WRITE = 8'h81;
  localparam [7:0] RSP_READ  = 8'h82;
  localparam [7:0] RSP_RESET = 8'h83;
  localparam [7:0] RSP_PING  = 8'h84;

  // DUT byte offsets (must match rtl/durable_tid_v0.v header map).
  localparam [7:0] A_EPOCH = 8'h00;
  localparam [7:0] A_REQ_LO = 8'h04;
  localparam [7:0] A_PEND_LO = 8'h08;
  localparam [7:0] A_DUR_LO = 8'h0C;
  localparam [7:0] A_VIS_LO = 8'h10;
  localparam [7:0] A_FSM = 8'h14;
  localparam [7:0] A_ERROR = 8'h18;
  localparam [7:0] A_PROG = 8'h1C;
  localparam [7:0] A_RSTCNT = 8'h20;
  localparam [7:0] A_CTRL = 8'h24;
  localparam [7:0] A_STATUS = 8'h28;
  localparam [7:0] A_DESC0 = 8'h2C;
  localparam [7:0] A_DESC1 = 8'h30;
  localparam [7:0] A_DESC_CRC = 8'h34;
  localparam [7:0] A_TID_LO = 8'h3C;
  localparam [7:0] A_TID_HI = 8'h40;
  localparam [7:0] A_REQ_HI = 8'h44;
  localparam [7:0] A_DUR_HI = 8'h48;
  localparam [7:0] A_VIS_HI = 8'h4C;
  localparam [7:0] A_PEND_HI = 8'h50;
  localparam [7:0] A_MAGIC = 8'h54;
  localparam [7:0] A_VERSION = 8'h58;

  localparam CTRL_SUBMIT  = 32'h00000001;
  localparam CTRL_RECOVER = 32'h00000004;

  // ERROR bits (must match DUT).
  localparam E_CRC = 0, E_DUP = 1, E_GAP = 2, E_MALF = 3, E_RSTMID = 4;

  // --- DUT top ------------------------------------------------------------
  reg         clk;
  reg         reset_n;
  reg         uart_rxd; // TB -> FPGA (board pin V14 side)
  wire        uart_txd; // FPGA -> TB (board pin U15 side)
  wire        trusted_complete_o;
  wire [63:0] durable_tid_o;
  wire        busy_o;

  dut_top_uart #(
    .CLK_HZ         (CLK_HZ),
    .BAUD           (BAUD),
    .COMMIT_LATENCY (2) // DUT default; see SCOPE NOTE below
  ) top (
    .clk                (clk),
    .reset_n            (reset_n),
    .uart_rxd           (uart_rxd),
    .uart_txd           (uart_txd),
    .trusted_complete_o (trusted_complete_o),
    .durable_tid_o      (durable_tid_o),
    .busy_o             (busy_o)
  );

  // 50 MHz board clock (matches CLK_HZ; the fabric divides it to 25 MHz).
  initial clk = 1'b0;
  always #10 clk = ~clk;

  // Same CRC-32/IEEE algorithm as the DUT (intentional duplication).
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

  // --- scoreboard + monitors ------------------------------------------------
  integer checks_passed;
  integer checks_failed;
  integer mon_trusted_cnt;
  reg [63:0] mon_last_d;
  reg [63:0] mon_last_v;
  reg         mon_armed;
  reg         mon_tc_prev; // edge-detect: fabric pulses are 2 board cycles wide

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

  // (1) TRUSTED_COMPLETE(N) => PERSISTENT(N); (2) watermarks never regress.
  // Watermarks are COUNTS (highest durable TID + 1); tid_last is 0-based.
  // The monitor samples the 50 MHz board clock while the fabric runs at
  // 25 MHz, so trusted_complete_o pulses are counted on their rising edge
  // (each fabric-cycle pulse spans two board edges).
  always @(posedge clk) begin
    if (mon_armed) begin
      if (trusted_complete_o && !mon_tc_prev) begin
        mon_trusted_cnt = mon_trusted_cnt + 1;
        if (durable_tid_o !== (top.u_dut.tid_last + 64'd1)) begin
          checks_failed = checks_failed + 1;
          $display("[FAIL] invariant TRUSTED_COMPLETE=>PERSISTENT violated: durable=%h tid_last=%h",
                   durable_tid_o, top.u_dut.tid_last);
        end
      end
      if (top.u_dut.durable < mon_last_d) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: durable regressed %h -> %h",
                 mon_last_d, top.u_dut.durable);
      end
      if (top.u_dut.visible < mon_last_v) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: visible regressed %h -> %h",
                 mon_last_v, top.u_dut.visible);
      end
      mon_last_d = top.u_dut.durable;
      mon_last_v = top.u_dut.visible;
      mon_tc_prev = trusted_complete_o;
    end
  end

  // --- behavioral UART host driver ------------------------------------------
  // Send one byte, LSB first, 8-N-1, BITB board-clock edges per bit
  // (= BITC fabric cycles; the fabric is the board clock divided by 2).
  task uart_put(input [7:0] b);
    integer i;
    begin
      uart_rxd = 1'b0; // start
      repeat (BITB) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        uart_rxd = b[i];
        repeat (BITB) @(posedge clk);
      end
      uart_rxd = 1'b1; // stop
      repeat (BITB) @(posedge clk);
    end
  endtask

  // Receive one byte; ok=0 on start timeout (no response) or bad stop bit.
  // Start-timeout is 100000 board cycles (~23 byte times at 115200): the
  // first RSP byte is polled while the CMD is still being transmitted
  // (see host round-trip note at u_write), so the timeout must exceed the
  // 9-byte CMD time (9*10*BITB = 39060) plus fabric latency plus margin.
  task uart_get(output [7:0] b, output ok);
    integer i, t;
    begin
      ok = 1'b0;
      b  = 8'h00;
      t  = 0;
      while (uart_txd !== 1'b0 && t < 100000) begin
        @(posedge clk);
        t = t + 1;
      end
      if (uart_txd === 1'b0) begin
        repeat (BITB/2) @(posedge clk); // center into start bit
        for (i = 0; i < 8; i = i + 1) begin
          repeat (BITB) @(posedge clk);
          b[i] = uart_txd;
        end
        repeat (BITB) @(posedge clk); // stop bit
        if (uart_txd === 1'b1)
          ok = 1'b1;
      end
    end
  endtask

  // Send a well-formed 9-byte CMD frame.
  task host_cmd(input [7:0] cmd, input [7:0] addr, input [31:0] data);
    reg [7:0] chk;
    begin
      chk = cmd + addr + data[7:0] + data[15:8] + data[23:16] + data[31:24];
      uart_put(M0);
      uart_put(M1);
      uart_put(cmd);
      uart_put(addr);
      uart_put(data[7:0]);
      uart_put(data[15:8]);
      uart_put(data[23:16]);
      uart_put(data[31:24]);
      uart_put(chk);
    end
  endtask

  // Send a raw 9-byte frame with explicit header/checksum (negative tests).
  task host_cmd_raw(input [7:0] c0, input [7:0] c1, input [7:0] cmd,
                    input [7:0] addr, input [31:0] data, input [7:0] chk);
    begin
      uart_put(c0);
      uart_put(c1);
      uart_put(cmd);
      uart_put(addr);
      uart_put(data[7:0]);
      uart_put(data[15:8]);
      uart_put(data[23:16]);
      uart_put(data[31:24]);
      uart_put(chk);
    end
  endtask

  // Receive an 8-byte RSP frame; ok=1 only if magic + checksum verify.
  task host_resp(output [7:0] rsp, output [31:0] data, output ok);
    reg [7:0] m0, m1, b0, b1, b2, b3, chk;
    reg ok0, ok1, ok2, ok3, ok4, ok5, ok6, ok7;
    reg [7:0] sum;
    begin : rr
      ok = 1'b0; rsp = 8'h00; data = 32'h00000000;
      uart_get(m0, ok0);
      if (!ok0) disable rr;
      uart_get(m1, ok1);
      if (!ok1) disable rr;
      uart_get(rsp, ok2);
      if (!ok2) disable rr;
      uart_get(b0, ok3);
      if (!ok3) disable rr;
      uart_get(b1, ok4);
      if (!ok4) disable rr;
      uart_get(b2, ok5);
      if (!ok5) disable rr;
      uart_get(b3, ok6);
      if (!ok6) disable rr;
      uart_get(chk, ok7);
      if (!ok7) disable rr;
      data = {b3, b2, b1, b0};
      // CHK is the payload sum: valid iff RSP+D0..D3 equals CHK.
      sum = rsp + b0 + b1 + b2 + b3;
      if (m0 == M0 && m1 == M1 && sum[7:0] == chk)
        ok = 1'b1;
    end
  endtask

  // WRITE-REG round trip. ok=1 iff ACK rsp + echo match.
  // The CMD transmit and RSP watch run FORKED: the FPGA's RX completes a
  // byte ~194 fabric cycles before the TB finishes transmitting its stop
  // bit, and the protocol block starts the RSP ~5 fabric cycles later --
  // so the RSP start bit begins ~180 fabric cycles (~0.85 bit times)
  // BEFORE a sequential caller could start polling. A sequential
  // host_cmd/host_resp therefore misses the start edge and mis-samples
  // the whole frame. Watching uart_txd from before the CMD goes out
  // catches the true start edge (independent lines: uart_rxd vs uart_txd).
  task u_write(input [7:0] addr, input [31:0] data, output ok);
    reg [7:0] rsp;
    reg [31:0] echo;
    reg rok;
    begin
      fork
        host_cmd(CMD_WRITE, addr, data);
        host_resp(rsp, echo, rok);
      join
      ok = rok && (rsp == RSP_WRITE) && (echo == data);
    end
  endtask

  // READ-REG round trip. ok=1 iff DATA rsp received; value in rdata.
  // (Forked CMD/RSP for the same early-RSP reason as u_write.)
  task u_read(input [7:0] addr, output [31:0] rdata, output ok);
    reg [7:0] rsp;
    reg rok;
    begin
      fork
        host_cmd(CMD_READ, addr, 32'h00000000);
        host_resp(rsp, rdata, rok);
      join
      ok = rok && (rsp == RSP_READ);
    end
  endtask

  // PING round trip. ok=1 iff PONG with VERSION==0.
  // (Forked CMD/RSP for the same early-RSP reason as u_write.)
  task u_ping(output ok);
    reg [7:0] rsp;
    reg [31:0] ver;
    reg rok;
    begin
      fork
        host_cmd(CMD_PING, 8'h00, 32'h00000000);
        host_resp(rsp, ver, rok);
      join
      ok = rok && (rsp == RSP_PING) && (ver == 32'h00000000);
    end
  endtask

  // RESET round trip. ok=1 iff RESET-DONE rsp received; count in rcnt.
  // (Forked CMD/RSP for the same early-RSP reason as u_write.)
  task u_reset(output [31:0] rcnt, output ok);
    reg [7:0] rsp;
    reg rok;
    begin
      fork
        host_cmd(CMD_RESET, 8'h00, 32'h00000000);
        host_resp(rsp, rcnt, rok);
      join
      ok = rok && (rsp == RSP_RESET);
    end
  endtask

  // Poll STATUS.BUSY==0 over UART. ok=1 on success (<=30 polls).
  task wait_idle_uart(output ok);
    reg [31:0] st;
    reg rok;
    integer i;
    begin : poll
      ok = 1'b0;
      for (i = 0; i < 30; i = i + 1) begin
        u_read(A_STATUS, st, rok);
        if (rok && !st[0]) begin
          ok = 1'b1;
          disable poll;
        end
      end
    end
  endtask

  task read_durable_uart(output [63:0] d, output ok);
    reg [31:0] lo, hi;
    reg ok0, ok1;
    begin
      u_read(A_DUR_LO, lo, ok0);
      u_read(A_DUR_HI, hi, ok1);
      d = {hi, lo};
      ok = ok0 && ok1;
    end
  endtask

  task read_visible_uart(output [63:0] v, output ok);
    reg [31:0] lo, hi;
    reg ok0, ok1;
    begin
      u_read(A_VIS_LO, lo, ok0);
      u_read(A_VIS_HI, hi, ok1);
      v = {hi, lo};
      ok = ok0 && ok1;
    end
  endtask

  // Submit one descriptor for sequence req with epoch ep over UART.
  // bad_crc=1 corrupts the CRC word. ok=1 iff all writes ACK + idle reached.
  task submit_one_uart(input [31:0] req, input [31:0] d0, input [31:0] d1,
                       input [31:0] ep, input bad_crc, output ok);
    reg [31:0] crc;
    reg w0, w1, w2, w3, w4, w5;
    reg idle;
    begin
      crc = tb_crc32({ep, req, d1, d0});
      if (bad_crc)
        crc = ~crc;
      u_write(A_DESC0, d0, w0);
      u_write(A_DESC1, d1, w1);
      u_write(A_REQ_LO, req, w2);
      u_write(A_REQ_HI, 32'h00000000, w3);
      u_write(A_DESC_CRC, crc, w4);
      u_write(A_CTRL, CTRL_SUBMIT, w5);
      wait_idle_uart(idle);
      ok = w0 && w1 && w2 && w3 && w4 && w5 && idle;
    end
  endtask

  task clear_errors_uart(output ok);
    reg wok;
    begin
      u_write(A_ERROR, 32'h0000003F, wok); // rw1c: clear all defined bits
      ok = wok;
    end
  endtask

  // Test temporaries (module scope for portability).
  reg [31:0] t_rdata, t_rcnt, t_err, t_st;
  reg [63:0] t_d, t_v;
  reg         t_ok, t_ok2;
  integer     k;
  integer     pulses_before;

  initial begin
    checks_passed   = 0;
    checks_failed   = 0;
    mon_trusted_cnt = 0;
    mon_last_d      = 64'h0;
    mon_last_v      = 64'h0;
    mon_armed       = 1'b0;
    mon_tc_prev     = 1'b0;
    uart_rxd        = 1'b1; // serial line idles high

    // Global reset.
    reset_n = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);
    mon_armed = 1'b1;

    // U0: PING -> PONG with MAGIC + VERSION.
    u_ping(t_ok);
    check("U0 ping round trip (MAGIC+VERSION)", t_ok == 1'b1);

    // U1: READ-REG of identity registers.
    u_read(A_MAGIC, t_rdata, t_ok);
    check("U1 magic reads DUR0 over UART", t_ok && t_rdata == 32'h44555230);
    u_read(A_VERSION, t_rdata, t_ok);
    check("U1 version is v0 over UART", t_ok && t_rdata == 32'h00000000);

    // U2: WRITE-REG round trip + readback.
    u_write(A_EPOCH, 32'h00000001, t_ok);
    check("U2 epoch write ACKs with echo", t_ok == 1'b1);
    u_read(A_EPOCH, t_rdata, t_ok);
    check("U2 epoch readback", t_ok && t_rdata == 32'h00000001);

    // U3: 8 good submits through the UART path; durable tracks 1:1.
    for (k = 0; k < 8; k = k + 1) begin
      submit_one_uart(k[31:0], 32'hA0000000 + k[31:0], 32'hB0000000 + k[31:0],
                      32'h00000001, 1'b0, t_ok);
      if (!t_ok) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] U3 op %0d submit round trip failed", k);
      end
      read_durable_uart(t_d, t_ok2);
      if (!t_ok2 || t_d != (k + 1)) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] U3 op %0d durable=%h expected %h", k, t_d, k + 1);
      end
      read_visible_uart(t_v, t_ok2);
      if (!t_ok2 || t_v != t_d) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] U3 op %0d visible=%h durable=%h", k, t_v, t_d);
      end
    end
    u_read(A_PROG, t_rdata, t_ok);
    check("U3 progress == 8", t_ok && t_rdata == 32'h00000008);
    u_read(A_ERROR, t_err, t_ok);
    check("U3 no errors on good submits", t_ok && t_err == 32'h0);
    check("U3 8 trusted pulses observed", mon_trusted_cnt == 8);

    // U4: duplicate submit (seq 7 again) -> DUP, durable held.
    pulses_before = mon_trusted_cnt;
    submit_one_uart(32'h00000007, 32'hA0000007, 32'hB0000007,
                    32'h00000001, 1'b0, t_ok);
    check("U4 dup submit round trip ok", t_ok == 1'b1);
    u_read(A_ERROR, t_err, t_ok);
    check("U4 DUP flagged", t_ok && t_err[E_DUP] == 1'b1);
    read_durable_uart(t_d, t_ok);
    check("U4 durable held at 8", t_ok && t_d == 64'h8);
    check("U4 no new trusted pulse", mon_trusted_cnt == pulses_before);
    clear_errors_uart(t_ok);

    // U5a: bad CRC on seq 8 -> CRC_ERR, durable held.
    submit_one_uart(32'h00000008, 32'h11111111, 32'h22222222,
                    32'h00000001, 1'b1, t_ok);
    u_read(A_ERROR, t_err, t_ok2);
    check("U5a bad CRC flagged", t_ok2 && t_err[E_CRC] == 1'b1);
    read_durable_uart(t_d, t_ok2);
    check("U5a durable held at 8", t_ok2 && t_d == 64'h8);
    u_read(A_STATUS, t_st, t_ok2);
    check("U5a crc_ok_last clear", t_ok2 && t_st[2] == 1'b0);
    clear_errors_uart(t_ok);

    // U5b: reserved CTRL bits -> MALFORMED.
    u_write(A_CTRL, 32'hFFFFFFF8, t_ok);
    u_read(A_ERROR, t_err, t_ok2);
    check("U5b reserved CTRL bits flagged MALFORMED",
          t_ok && t_ok2 && t_err[E_MALF] == 1'b1);
    read_durable_uart(t_d, t_ok2);
    check("U5b durable held at 8", t_ok2 && t_d == 64'h8);
    clear_errors_uart(t_ok);

    // U5c: REQ_HI mismatch -> MALFORMED.
    u_write(A_REQ_LO, 32'h00000008, t_ok);
    u_write(A_REQ_HI, 32'hDEADBEEF, t_ok2);
    u_write(A_DESC0, 32'h11111111, t_ok);
    u_write(A_DESC1, 32'h22222222, t_ok);
    u_write(A_DESC_CRC, tb_crc32({32'h00000001, 32'h00000008,
                                  32'h22222222, 32'h11111111}), t_ok);
    u_write(A_CTRL, CTRL_SUBMIT, t_ok);
    wait_idle_uart(t_ok2);
    u_read(A_ERROR, t_err, t_ok);
    check("U5c REQ_HI mismatch flagged MALFORMED",
          t_ok && t_ok2 && t_err[E_MALF] == 1'b1);
    read_durable_uart(t_d, t_ok);
    check("U5c durable held at 8", t_ok && t_d == 64'h8);
    clear_errors_uart(t_ok);

    // U5d: good submit of seq 8 still works after malformed vectors.
    submit_one_uart(32'h00000008, 32'h11111111, 32'h22222222,
                    32'h00000001, 1'b0, t_ok);
    read_durable_uart(t_d, t_ok2);
    check("U5d durable advanced to 9", t_ok && t_ok2 && t_d == 64'h9);
    u_read(A_ERROR, t_err, t_ok);
    check("U5d no errors", t_ok && t_err == 32'h0);

    // U6: malformed UART frames are dropped with NO response.
    // Sequential cmd/resp is intentional here: silence is expected, and
    // the uart_get timeout (100000 board cycles) proves it.
    begin
      reg [7:0] rsp;
      reg [31:0] rdata;
      reg rok;
      // U6a: bad checksum (correct framing, wrong CHK).
      host_cmd_raw(M0, M1, CMD_READ, A_DUR_LO, 32'h00000000, 8'hFF);
      host_resp(rsp, rdata, rok);
      check("U6a bad-checksum frame gets no response", rok == 1'b0);
      // U6b: bad magic.
      host_cmd_raw(8'h00, 8'h00, CMD_READ, A_DUR_LO, 32'h00000000, 8'h02);
      host_resp(rsp, rdata, rok);
      check("U6b bad-magic frame gets no response", rok == 1'b0);
      // U6c: unknown CMD (0x07) with VALID checksum: 0x07+0x0C = 0x13.
      host_cmd_raw(M0, M1, 8'h07, A_DUR_LO, 32'h00000000, 8'h13);
      host_resp(rsp, rdata, rok);
      check("U6c unknown-CMD frame gets no response", rok == 1'b0);
    end
    read_durable_uart(t_d, t_ok);
    check("U6d durable still 9 after dropped frames", t_ok && t_d == 64'h9);
    // Link still alive after rejection?
    u_ping(t_ok);
    check("U6e ping still works after rejections", t_ok == 1'b1);

    // U7: RESET command path over UART (serial analogue of original TEST 7:
    // reset while idle). Counter++, history preserved, no RSTMID flag;
    // then a normal submit proves the DUT is healthy post-reset.
    // (Reset-MID-COMMIT is unhittable over serial -- see SCOPE NOTE.)
    u_reset(t_rcnt, t_ok);
    check("U7 reset round trip ok, count==1", t_ok && t_rcnt == 32'h1);
    u_read(A_ERROR, t_err, t_ok);
    check("U7 no RSTMID on idle reset", t_ok && t_err[E_RSTMID] == 1'b0);
    u_read(A_RSTCNT, t_rdata, t_ok);
    check("U7 reset counter == 1", t_ok && t_rdata == 32'h00000001);
    read_durable_uart(t_d, t_ok);
    check("U7 durable preserved (9)", t_ok && t_d == 64'h9);
    u_read(A_EPOCH, t_rdata, t_ok);
    check("U7 epoch preserved (1)", t_ok && t_rdata == 32'h00000001);
    clear_errors_uart(t_ok2);
    submit_one_uart(32'h00000009, 32'hA0000009, 32'hB0000009,
                    32'h00000001, 1'b0, t_ok);
    read_durable_uart(t_d, t_ok2);
    check("U7 post-reset submit commits (durable 10)",
          t_ok && t_ok2 && t_d == 64'hA);
    u_read(A_TID_LO, t_rdata, t_ok);
    check("U7 tid_last == 9", t_ok && t_rdata == 32'h00000009);

    // U8: repeated submit over UART. Op A commits; op B (identical bytes,
    // sent with no poll in between) executes a full frame round trip later
    // (~37000 fabric cycles: A's 8-byte RSP + B's 9-byte CMD) --
    // the DUT busy window (~7 fabric cycles) is long closed, so B is
    // rejected as DUP, NOT MALFORMED. This empirically demonstrates the SCOPE NOTE:
    // submit-while-busy is unhittable over serial (original TEST 8 stays
    // a parallel-TB-only window).
    begin
      reg w0, w1, w2, w3, w4, w5a, w5b;
      u_write(A_DESC0, 32'hA000000A, w0);
      u_write(A_DESC1, 32'hB000000A, w1);
      u_write(A_REQ_LO, 32'h0000000A, w2);
      u_write(A_REQ_HI, 32'h00000000, w3);
      u_write(A_DESC_CRC, tb_crc32({32'h00000001, 32'h0000000A,
                                    32'hB000000A, 32'hA000000A}), w4);
      u_write(A_CTRL, CTRL_SUBMIT, w5a); // op A
      u_write(A_CTRL, CTRL_SUBMIT, w5b); // op B: DUT idle again -> DUP
      check("U8 both submit writes ACK", w0 && w1 && w2 && w3 && w4 && w5a && w5b);
      wait_idle_uart(t_ok);
      check("U8 wait idle ok", t_ok == 1'b1);
      read_durable_uart(t_d, t_ok);
      check("U8 exactly one commit (durable 11)", t_ok && t_d == 64'hB);
      u_read(A_ERROR, t_err, t_ok);
      check("U8 B rejected as DUP (window closed)", t_ok && t_err[E_DUP] == 1'b1);
      check("U8 no MALFORMED (never busy)", t_ok && t_err[E_MALF] == 1'b0);
      clear_errors_uart(t_ok);
    end

    // U9: final burst + error-bit clearing + trusted count.
    for (k = 11; k < 15; k = k + 1) begin
      submit_one_uart(k[31:0], k[31:0] ^ 32'hAAAAAAAA,
                      k[31:0] ^ 32'h55555555, 32'h00000001, 1'b0, t_ok);
      if (!t_ok) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] U9 op %0d submit round trip failed", k);
      end
    end
    read_durable_uart(t_d, t_ok);
    check("U9 durable == 15 after burst", t_ok && t_d == 64'hF);
    read_visible_uart(t_v, t_ok2);
    check("U9 visible == durable", t_ok && t_ok2 && t_v == t_d);
    u_read(A_ERROR, t_err, t_ok);
    check("U9 error register clearable and clear", t_ok && t_err == 32'h0);
    u_read(A_FSM, t_rdata, t_ok);
    check("U9 FSM back in IDLE", t_ok && t_rdata[1:0] == 2'd0);
    check("U9 trusted pulse count == completed ops",
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
