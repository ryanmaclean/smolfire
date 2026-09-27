// SPDX-License-Identifier: Apache-2.0
// rtl/dut_uart_burst_tb.sv -- burst-submit (CMD_BURST_SUBMIT 0x05) tests.
//
// Drives the DUT exclusively through the UART front-end, same 50 MHz /
// 115200 hardware operating point as dut_uart_tb.sv (which is UNTOUCHED:
// the 43-check single-submit suite must keep its exact banner). Covers:
//   B0 burst N=1 (single good entry)
//   B1 burst N=2 (two good entries)
//   B2 mid-burst DUP (commit, dup-reject, commit -- no cascade)
//   B3 mid-burst CRC-bad (commit, crc-reject, commit -- no cascade)
//   B4 mid-burst GAP (commit, gap-reject)
//   B5 N=64 max-length frame, all good (1029-byte CMD, 77-byte RSP)
//   B6 malformed bursts (COUNT=0, bad CHK -> silent drop, link alive)
// Always-on monitors: TRUSTED_COMPLETE(N) => PERSISTENT(N), watermarks
// never regress (same as both existing suites).
//
//   iverilog -g2012 -o sim_burst dut_top_uart.v dut_uart.v \
//     durable_tid_v0.v dut_uart_burst_tb.sv && ./sim_burst

`timescale 1ns / 1ps

module dut_uart_burst_tb;

  localparam CLK_HZ = 50000000;
  localparam BAUD   = 115200;
  localparam BITC   = CLK_HZ / BAUD;
  localparam BITB   = BITC;

  // Protocol constants (must match rtl/dut_uart.v).
  localparam [7:0] M0 = 8'h44;
  localparam [7:0] M1 = 8'h55;
  localparam [7:0] CMD_WRITE = 8'h01;
  localparam [7:0] CMD_READ  = 8'h02;
  localparam [7:0] CMD_BURST = 8'h05;
  localparam [7:0] RSP_WRITE = 8'h81;
  localparam [7:0] RSP_READ  = 8'h82;
  localparam [7:0] RSP_BURST = 8'h85;

  // DUT byte offsets (must match rtl/durable_tid_v0.v header map).
  localparam [7:0] A_EPOCH = 8'h00;
  localparam [7:0] A_DUR_LO = 8'h0C;
  localparam [7:0] A_DUR_HI = 8'h48;
  localparam [7:0] A_VIS_LO = 8'h10;
  localparam [7:0] A_ERROR = 8'h18;
  localparam [7:0] A_FSM = 8'h14;
  localparam [7:0] A_CTRL = 8'h24;
  localparam [7:0] A_STATUS = 8'h28;

  // ERROR bits (must match DUT).
  localparam E_CRC = 0, E_DUP = 1, E_GAP = 2, E_MALF = 3;

  // Expected result bytes: {3'b0, CODE[2:0], REJECT, COMMITTED}.
  localparam [7:0] R_COMMIT = 8'h01;
  localparam [7:0] R_CRC    = 8'h06; // CODE 1
  localparam [7:0] R_DUP    = 8'h0A; // CODE 2
  localparam [7:0] R_GAP    = 8'h0E; // CODE 3

  reg         clk;
  reg         reset_n;
  reg         uart_rxd;
  wire        uart_txd;
  wire        trusted_complete_o;
  wire [63:0] durable_tid_o;
  wire        busy_o;

  dut_top_uart #(
    .CLK_HZ         (CLK_HZ),
    .BAUD           (BAUD),
    .COMMIT_LATENCY (2)
  ) top (
    .clk                (clk),
    .reset_n            (reset_n),
    .uart_rxd           (uart_rxd),
    .uart_txd           (uart_txd),
    .trusted_complete_o (trusted_complete_o),
    .durable_tid_o      (durable_tid_o),
    .busy_o             (busy_o)
  );

  initial clk = 1'b0;
  always #10 clk = ~clk;

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

  // --- scoreboard + monitors -----------------------------------------------
  integer checks_passed;
  integer checks_failed;
  integer mon_trusted_cnt;
  reg [63:0] mon_last_d;
  reg [63:0] mon_last_v;
  reg         mon_armed;
  reg         mon_tc_prev;

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
  task uart_put(input [7:0] b);
    integer i;
    begin
      uart_rxd = 1'b0;
      repeat (BITB) @(posedge clk);
      for (i = 0; i < 8; i = i + 1) begin
        uart_rxd = b[i];
        repeat (BITB) @(posedge clk);
      end
      uart_rxd = 1'b1;
      repeat (BITB) @(posedge clk);
    end
  endtask

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
        repeat (BITB/2) @(posedge clk);
        for (i = 0; i < 8; i = i + 1) begin
          repeat (BITB) @(posedge clk);
          b[i] = uart_txd;
        end
        repeat (BITB) @(posedge clk);
        if (uart_txd === 1'b1)
          ok = 1'b1;
      end
    end
  endtask

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
      sum = rsp + b0 + b1 + b2 + b3;
      if (m0 == M0 && m1 == M1 && sum[7:0] == chk)
        ok = 1'b1;
    end
  endtask

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

  task u_ping(output ok);
    reg [7:0] rsp;
    reg [31:0] ver;
    reg rok;
    begin
      fork
        host_cmd(8'h04, 8'h00, 32'h00000000);
        host_resp(rsp, ver, rok);
      join
      ok = rok && (rsp == 8'h84) && (ver == 32'h00000000);
    end
  endtask

  // --- burst driver ----------------------------------------------------------
  // Entry vectors (module scope): host fills b_req/b_d0/b_d1 for n entries,
  // sets badmask bit i to corrupt entry i's CRC, then calls burst_xfer.
  reg [31:0] b_req [0:63];
  reg [31:0] b_d0 [0:63];
  reg [31:0] b_d1 [0:63];
  reg [7:0]  b_res [0:63]; // RSP result bytes land here

  // Send one BURST frame (5+16*n bytes), then receive the BURST-RSP.
  // ok=1 iff RSP magic+code+count+checksum all verify; watermark in b_dur.
  task burst_xfer(input [6:0] n, input [63:0] badmask, input [31:0] ep,
                  output [63:0] b_dur, output ok);
    reg [31:0] crc;
    reg [7:0] chk;
    reg [7:0] m0, m1, rsp, cnt, b, c0, c1, c2, c3, c4, c5, c6, c7, rchk;
    reg [7:0] sum;
    reg o0, o1, o2, o3, o4;
    reg [31:0] lo, hi;
    integer i;
    begin : bx
      ok = 1'b0;
      b_dur = 64'h0;
      chk = CMD_BURST + {1'b0, n};
      uart_put(M0);
      uart_put(M1);
      uart_put(CMD_BURST);
      uart_put({1'b0, n});
      for (i = 0; i < n; i = i + 1) begin
        crc = tb_crc32({ep, b_req[i], b_d1[i], b_d0[i]});
        if (badmask[i])
          crc = ~crc;
        uart_put(b_req[i][7:0]);
        uart_put(b_req[i][15:8]);
        uart_put(b_req[i][23:16]);
        uart_put(b_req[i][31:24]);
        uart_put(b_d0[i][7:0]);
        uart_put(b_d0[i][15:8]);
        uart_put(b_d0[i][23:16]);
        uart_put(b_d0[i][31:24]);
        uart_put(b_d1[i][7:0]);
        uart_put(b_d1[i][15:8]);
        uart_put(b_d1[i][23:16]);
        uart_put(b_d1[i][31:24]);
        uart_put(crc[7:0]);
        uart_put(crc[15:8]);
        uart_put(crc[23:16]);
        uart_put(crc[31:24]);
        chk = chk + b_req[i][7:0] + b_req[i][15:8]
                  + b_req[i][23:16] + b_req[i][31:24]
                  + b_d0[i][7:0] + b_d0[i][15:8]
                  + b_d0[i][23:16] + b_d0[i][31:24]
                  + b_d1[i][7:0] + b_d1[i][15:8]
                  + b_d1[i][23:16] + b_d1[i][31:24]
                  + crc[7:0] + crc[15:8] + crc[23:16] + crc[31:24];
      end
      uart_put(chk);
      // RSP: magic + RSP_BURST + COUNT + N results + 8 watermark + CHK.
      uart_get(m0, o0);
      if (!o0) disable bx;
      uart_get(m1, o1);
      if (!o1) disable bx;
      uart_get(rsp, o2);
      if (!o2) disable bx;
      uart_get(cnt, o3);
      if (!o3) disable bx;
      if (m0 != M0 || m1 != M1 || rsp != RSP_BURST || cnt != {1'b0, n})
        disable bx;
      sum = rsp + cnt;
      for (i = 0; i < n; i = i + 1) begin
        uart_get(b, o4);
        if (!o4) disable bx;
        b_res[i] = b;
        sum = sum + b;
      end
      uart_get(c0, o0);
      if (!o0) disable bx;
      uart_get(c1, o1);
      if (!o1) disable bx;
      uart_get(c2, o2);
      if (!o2) disable bx;
      uart_get(c3, o3);
      if (!o3) disable bx;
      uart_get(c4, o4);
      if (!o4) disable bx;
      uart_get(c5, o0);
      if (!o0) disable bx;
      uart_get(c6, o1);
      if (!o1) disable bx;
      uart_get(c7, o2);
      if (!o2) disable bx;
      uart_get(rchk, o3);
      if (!o3) disable bx;
      lo = {c3, c2, c1, c0};
      hi = {c7, c6, c5, c4};
      sum = sum + c0 + c1 + c2 + c3 + c4 + c5 + c6 + c7;
      if (sum[7:0] != rchk) disable bx;
      b_dur = {hi, lo};
      ok = 1'b1;
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

  task clear_errors_uart(output ok);
    reg wok;
    begin
      u_write(A_ERROR, 32'h0000003F, wok);
      ok = wok;
    end
  endtask

  // Test temporaries (module scope for portability).
  reg [63:0] t_dur, t_rdur;
  reg [31:0] t_rdata, t_err;
  reg         t_ok, t_ok2;
  integer     i, k;
  integer     pulses_before;

  initial begin
    checks_passed   = 0;
    checks_failed   = 0;
    mon_trusted_cnt = 0;
    mon_last_d      = 64'h0;
    mon_last_v      = 64'h0;
    mon_armed       = 1'b0;
    mon_tc_prev     = 1'b0;
    uart_rxd        = 1'b1;

    reset_n = 1'b0;
    repeat (4) @(posedge clk);
    reset_n = 1'b1;
    repeat (2) @(posedge clk);
    mon_armed = 1'b1;

    // Setup: link alive, EPOCH=1, errors clear.
    u_ping(t_ok);
    check("BSET ping round trip", t_ok == 1'b1);
    u_write(A_EPOCH, 32'h00000001, t_ok);
    check("BSET epoch write ACKs", t_ok == 1'b1);
    clear_errors_uart(t_ok);
    check("BSET errors clear", t_ok == 1'b1);

    // B0: N=1 single good entry (req 0).
    b_req[0] = 32'h00000000;
    b_d0[0]  = 32'hA0000000;
    b_d1[0]  = 32'hB0000000;
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd1, 64'h0, 32'h00000001, t_dur, t_ok);
    check("B0 N=1 RSP verifies", t_ok == 1'b1);
    check("B0 R0 committed", b_res[0] == R_COMMIT);
    check("B0 watermark == 1", t_dur == 64'h1);
    check("B0 one trusted pulse", mon_trusted_cnt == pulses_before + 1);

    // B1: N=2 both good (reqs 1,2).
    for (k = 0; k < 2; k = k + 1) begin
      b_req[k] = 32'h00000001 + k[31:0];
      b_d0[k]  = 32'hA0000001 + k[31:0];
      b_d1[k]  = 32'hB0000001 + k[31:0];
    end
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd2, 64'h0, 32'h00000001, t_dur, t_ok);
    check("B1 N=2 RSP verifies", t_ok == 1'b1);
    check("B1 both committed", b_res[0] == R_COMMIT && b_res[1] == R_COMMIT);
    check("B1 watermark == 3", t_dur == 64'h3);
    check("B1 two trusted pulses", mon_trusted_cnt == pulses_before + 2);

    // B2: mid-burst DUP -- [req3 good][req1 replay -> DUP][req4 good].
    // Entry 2 uses the LIVE tid_next (4), proving no index cascade.
    b_req[0] = 32'h00000003;
    b_d0[0]  = 32'hC0000003;
    b_d1[0]  = 32'hD0000003;
    b_req[1] = 32'h00000001; // replay of a durable seq -> DUP
    b_d0[1]  = 32'hA0000001;
    b_d1[1]  = 32'hB0000001;
    b_req[2] = 32'h00000004;
    b_d0[2]  = 32'hC0000004;
    b_d1[2]  = 32'hD0000004;
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd3, 64'h0, 32'h00000001, t_dur, t_ok);
    check("B2 RSP verifies", t_ok == 1'b1);
    check("B2 results C/DUP/C",
          b_res[0] == R_COMMIT && b_res[1] == R_DUP && b_res[2] == R_COMMIT);
    check("B2 watermark == 5 (no cascade)", t_dur == 64'h5);
    check("B2 two trusted pulses", mon_trusted_cnt == pulses_before + 2);
    u_read(A_ERROR, t_err, t_ok);
    check("B2 entry errors cleared by engine", t_ok && t_err == 32'h0);
    clear_errors_uart(t_ok);

    // B3: mid-burst CRC-bad -- [req5 good][req6 bad CRC][req6 good].
    b_req[0] = 32'h00000005;
    b_d0[0]  = 32'hE0000005;
    b_d1[0]  = 32'hF0000005;
    b_req[1] = 32'h00000006;
    b_d0[1]  = 32'hE0000006;
    b_d1[1]  = 32'hF0000006;
    b_req[2] = 32'h00000006; // same REQ retried clean: commits (no cascade)
    b_d0[2]  = 32'hE0000006;
    b_d1[2]  = 32'hF0000006;
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd3, 64'h2, 32'h00000001, t_dur, t_ok); // badmask bit1
    check("B3 RSP verifies", t_ok == 1'b1);
    check("B3 results C/CRC/C",
          b_res[0] == R_COMMIT && b_res[1] == R_CRC && b_res[2] == R_COMMIT);
    check("B3 watermark == 7 (no cascade)", t_dur == 64'h7);
    check("B3 two trusted pulses", mon_trusted_cnt == pulses_before + 2);
    u_read(A_ERROR, t_err, t_ok);
    check("B3 entry errors cleared by engine", t_ok && t_err == 32'h0);
    clear_errors_uart(t_ok);

    // B4: mid-burst GAP -- [req7 good][req12 ahead -> GAP].
    b_req[0] = 32'h00000007;
    b_d0[0]  = 32'h11111107;
    b_d1[0]  = 32'h22222207;
    b_req[1] = 32'h0000000C; // ahead of allocator -> GAP
    b_d0[1]  = 32'h1111110C;
    b_d1[1]  = 32'h2222220C;
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd2, 64'h0, 32'h00000001, t_dur, t_ok);
    check("B4 RSP verifies", t_ok == 1'b1);
    check("B4 results C/GAP",
          b_res[0] == R_COMMIT && b_res[1] == R_GAP);
    check("B4 watermark == 8", t_dur == 64'h8);
    check("B4 one trusted pulse", mon_trusted_cnt == pulses_before + 1);
    u_read(A_ERROR, t_err, t_ok);
    check("B4 entry errors cleared by engine", t_ok && t_err == 32'h0);
    clear_errors_uart(t_ok);

    // B4b: pre-existing sticky bits SURVIVE a burst (err_base isolation).
    // Reserved CTRL bits set MALFORMED without touching watermarks.
    u_write(A_CTRL, 32'hFFFFFFF8, t_ok);
    check("B4b MALFORMED planted", t_ok == 1'b1);
    u_read(A_ERROR, t_err, t_ok2);
    check("B4b MALFORMED sticky set", t_ok2 && t_err[E_MALF] == 1'b1);

    // B5: N=64 max-length frame, all good (reqs 8..71).
    for (k = 0; k < 64; k = k + 1) begin
      b_req[k] = 32'h00000008 + k[31:0];
      b_d0[k]  = k[31:0] ^ 32'hAAAAAAAA;
      b_d1[k]  = k[31:0] ^ 32'h55555555;
    end
    pulses_before = mon_trusted_cnt;
    burst_xfer(7'd64, 64'h0, 32'h00000001, t_dur, t_ok);
    check("B5 max frame RSP verifies", t_ok == 1'b1);
    begin
      reg allc;
      allc = 1'b1;
      for (i = 0; i < 64; i = i + 1)
        if (b_res[i] != R_COMMIT)
          allc = 1'b0;
      check("B5 all 64 committed", allc == 1'b1);
    end
    check("B5 watermark == 72", t_dur == 64'h48);
    check("B5 64 trusted pulses", mon_trusted_cnt == pulses_before + 64);
    read_durable_uart(t_rdur, t_ok2);
    check("B5 register durable == 72", t_ok2 && t_rdur == 64'h48);
    u_read(A_ERROR, t_err, t_ok);
    check("B5 pre-existing MALFORMED preserved", t_ok && t_err == 32'h8);
    clear_errors_uart(t_ok);

    // B6: malformed bursts are dropped with NO response.
    begin
      reg [7:0] rsp;
      reg [31:0] rdata;
      reg rok;
      reg [31:0] crc;
      reg [7:0] badchk;
      // B6a: COUNT=0 (CHK = 0x05+0x00 = 0x05).
      uart_put(M0);
      uart_put(M1);
      uart_put(CMD_BURST);
      uart_put(8'h00);
      uart_put(8'h05);
      host_resp(rsp, rdata, rok);
      check("B6a COUNT=0 gets no response", rok == 1'b0);
      // Resync: the rejected frame's trailing CHK byte lingers as a
      // partial-frame prefix (the DUT cannot know an invalid frame's
      // length). The host flushes it with 8 dummy bytes -- completing a
      // 9-byte legacy attempt that fails magic and drops -- then pings.
      for (k = 0; k < 8; k = k + 1)
        uart_put(8'h00);
      u_ping(t_ok);
      check("B6a flush resyncs link", t_ok == 1'b1);
      // B6b: N=1 frame with corrupt trailing CHK (payload itself valid).
      // The correct CHK is computed and then corrupted deterministically
      // (a hardcoded wrong byte could alias to valid 1/256 of the time).
      crc = tb_crc32({32'h00000001, 32'h00000048,
                      32'hDEADBEEF, 32'hCAFEF00D});
      begin
        reg [7:0] goodchk;
        goodchk = CMD_BURST + 8'h01
                + 8'h48 + 8'h00 + 8'h00 + 8'h00
                + 8'h0D + 8'hF0 + 8'hFE + 8'hCA
                + 8'hEF + 8'hBE + 8'hAD + 8'hDE
                + crc[7:0] + crc[15:8] + crc[23:16] + crc[31:24];
        badchk = goodchk + 8'h01; // deterministic corruption, never valid
      end
      uart_put(M0);
      uart_put(M1);
      uart_put(CMD_BURST);
      uart_put(8'h01);
      uart_put(8'h48);
      uart_put(8'h00);
      uart_put(8'h00);
      uart_put(8'h00);
      uart_put(8'h0D);
      uart_put(8'hF0);
      uart_put(8'hFE);
      uart_put(8'hCA);
      uart_put(8'hEF);
      uart_put(8'hBE);
      uart_put(8'hAD);
      uart_put(8'hDE);
      uart_put(crc[7:0]);
      uart_put(crc[15:8]);
      uart_put(crc[23:16]);
      uart_put(crc[31:24]);
      uart_put(badchk); // wrong CHK (deterministic, never valid)
      host_resp(rsp, rdata, rok);
      check("B6b bad-CHK burst gets no response", rok == 1'b0);
    end
    read_durable_uart(t_rdur, t_ok);
    check("B6c durable still 72 after drops", t_ok && t_rdur == 64'h48);
    u_ping(t_ok);
    check("B6d ping alive after drops", t_ok == 1'b1);

    // Final: error register clear, FSM idle, visible == durable.
    u_read(A_ERROR, t_err, t_ok);
    check("B7 error register clear", t_ok && t_err == 32'h0);
    u_read(A_FSM, t_rdata, t_ok);
    check("B7 FSM back in IDLE", t_ok && t_rdata[1:0] == 2'd0);
    u_read(A_VIS_LO, t_rdata, t_ok2);
    check("B7 visible == durable (72)", t_ok && t_ok2 && t_rdata == 32'h48);

    $display("----------------------------------------");
    $display("checks passed: %0d  failed: %0d", checks_passed, checks_failed);
    if (checks_failed == 0)
      $display("PASS");
    else
      $display("FAIL");
    $finish;
  end

endmodule
