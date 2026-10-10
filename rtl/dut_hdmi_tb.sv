// SPDX-License-Identifier: Apache-2.0
// rtl/dut_hdmi_tb.sv -- self-checking testbench for dut_hdmi_top.
//
// Single-clock TB (everything on the 25.175 MHz fabric pixel clock derived
// from the 125.875 MHz hdmi_clk input; the TB drives hdmi_clk only).
// Covers, in one run, while the UART host path and the display run together:
//   H0..H5  pixel-clock rate + frame structure + sync timing,
//   T1..T8  text-row spot checks with forced DUT state (incl. DURABLE low
//           half 0x5678EF90 rendering + ODDR-serializer bit order + control
//           codes),
//   U1..U5  UART host path through THIS top (PING/submits/reads) running
//           concurrently with back-to-back display polls (non-interference),
//           plus the always-on TRUSTED=>PERSISTENT + monotonicity monitors.
//
// Gowin primitives (ODDR/ELVDS_OBUF) are yosys built-ins; for icarus this
// file provides behavioral models with identical port lists. The ODDR model
// defines the assumed primitive behavior (Q0 = D0 on rising / D1 on
// falling, TX=1 enabled -- flagged for the load wave, see
// rtl/hdmi_gowin_out.v). These models live ONLY in this TB file, never in
// the synth file list.
//
//   iverilog -g2012 -o sim_hdmi dut_hdmi_top.v dut_uart.v durable_tid_v0.v \
//     hdmi_tmds_encode.v hdmi_timing_640x480.v dut_status_text.v \
//     hdmi_gowin_out.v dut_hdmi_tb.sv && ./sim_hdmi
// Exit banner is `$display PASS/FAIL` + `$finish`.

`timescale 1ns / 1ps

// --- icarus-only behavioral models of the Gowin primitives ---------------
// Port lists match the OSS (yosys cells_xtra_gw5a.v) spellings.
module ODDR (
  input  D0,
  input  D1,
  input  TX,
  input  CLK,
  output reg Q0,
  output Q1
);
  assign Q1 = 1'b0; // second output unused (matches the .Q1() convention)
  always @(posedge CLK) Q0 <= D0; // D0 on the rising edge
  always @(negedge CLK) Q0 <= D1; // D1 on the falling edge
endmodule

module ELVDS_OBUF (
  input  I,
  output O,
  output OB
);
  assign O = I;
  assign OB = ~I;
endmodule

module dut_hdmi_tb;

  // Pixel-domain operating point: 125.875 MHz / 5 = 25.175 MHz exactly.
  localparam CLK_HZ = 25175000;
  localparam BAUD   = 115200;
  // TB driver bit time (flat nominal; bridge is exact-average, margins huge).
  localparam BITB   = 219; // round(25175000/115200) = round(218.53)

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

  localparam [7:0] A_REQ_LO = 8'h04;
  localparam [7:0] A_DUR_LO = 8'h0C;
  localparam [7:0] A_VIS_LO = 8'h10;
  localparam [7:0] A_ERROR  = 8'h18;
  localparam [7:0] A_CTRL   = 8'h24;
  localparam [7:0] A_STATUS = 8'h28;
  localparam [7:0] A_DESC0  = 8'h2C;
  localparam [7:0] A_DESC1  = 8'h30;
  localparam [7:0] A_DESC_CRC = 8'h34;
  localparam [7:0] A_REQ_HI = 8'h44;
  localparam [7:0] A_DUR_HI = 8'h48;
  localparam [7:0] A_VIS_HI = 8'h4C;
  localparam CTRL_SUBMIT = 32'h00000001;

  reg         hdmi_clk;
  reg         reset_n;
  reg         uart_rxd;
  wire        uart_txd;
  wire [2:0]  tmds_d_p, tmds_d_n;
  wire        tmds_clk_p, tmds_clk_n;
  wire        trusted_complete_o;
  wire        busy_o;

  dut_hdmi_top #(
    .PIX_HZ         (CLK_HZ),
    .BAUD           (BAUD),
    .COMMIT_LATENCY (2)
  ) top (
    .hdmi_clk          (hdmi_clk),
    .reset_n           (reset_n),
    .uart_rxd          (uart_rxd),
    .uart_txd          (uart_txd),
    .tmds_d_p          (tmds_d_p),
    .tmds_d_n          (tmds_d_n),
    .tmds_clk_p        (tmds_clk_p),
    .tmds_clk_n        (tmds_clk_n),
    .trusted_complete_o(trusted_complete_o),
    .busy_o            (busy_o)
  );

  initial hdmi_clk = 1'b0;
  always #3.972265 hdmi_clk = ~hdmi_clk; // 125.875 MHz MS5351 CLK2

  wire pix_clk = top.pix_clk;
  wire hs = top.u_timing.hsync;
  wire vs = top.u_timing.vsync;

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

  integer checks_passed;
  integer checks_failed;
  integer mon_trusted_cnt;
  reg [63:0] mon_last_d;
  reg [63:0] mon_last_v;
  reg mon_armed;
  reg mon_tc_prev;

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

  always @(posedge pix_clk) begin
    if (mon_armed) begin
      if (trusted_complete_o && !mon_tc_prev) begin
        mon_trusted_cnt = mon_trusted_cnt + 1;
        if (top.u_dut.durable !== (top.u_dut.tid_last + 64'd1)) begin
          checks_failed = checks_failed + 1;
          $display("[FAIL] invariant TRUSTED_COMPLETE=>PERSISTENT violated");
        end
      end
      if (top.u_dut.durable < mon_last_d) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: durable regressed");
      end
      if (top.u_dut.visible < mon_last_v) begin
        checks_failed = checks_failed + 1;
        $display("[FAIL] monotonicity: visible regressed");
      end
      mon_last_d = top.u_dut.durable;
      mon_last_v = top.u_dut.visible;
      mon_tc_prev = trusted_complete_o;
    end
  end

  task uart_put(input [7:0] b);
    integer i;
    begin
      uart_rxd = 1'b0;
      repeat (BITB) @(posedge pix_clk);
      for (i = 0; i < 8; i = i + 1) begin
        uart_rxd = b[i];
        repeat (BITB) @(posedge pix_clk);
      end
      uart_rxd = 1'b1;
      repeat (BITB) @(posedge pix_clk);
    end
  endtask

  task uart_get(output [7:0] b, output ok);
    integer i, t;
    begin
      ok = 1'b0;
      b  = 8'h00;
      t  = 0;
      while (uart_txd !== 1'b0 && t < 100000) begin
        @(posedge pix_clk);
        t = t + 1;
      end
      if (uart_txd === 1'b0) begin
        repeat (BITB/2) @(posedge pix_clk);
        for (i = 0; i < 8; i = i + 1) begin
          repeat (BITB) @(posedge pix_clk);
          b[i] = uart_txd;
        end
        repeat (BITB) @(posedge pix_clk);
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
        host_cmd(CMD_PING, 8'h00, 32'h00000000);
        host_resp(rsp, ver, rok);
      join
      ok = rok && (rsp == RSP_PING) && (ver == 32'h00000001);
    end
  endtask

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

  // Test temporaries (module scope, Verilog-2001).
  real t1, t2;
  integer n, i, k, ph;
  reg t_ok, t_ok2;
  reg [31:0] t_rdata, t_err;
  reg [9:0] t_w;
  reg [29:0] sercap;
  reg signed [5:0] cnow;
  reg p1_title_on, p1_title_off, p2_dig0, p3_bg, p4_digF, p5_busy;
  reg t6_ser_ok, t8_disp_ok;

  initial begin
    checks_passed   = 0;
    checks_failed   = 0;
    mon_trusted_cnt = 0;
    mon_last_d      = 64'h0;
    mon_last_v      = 64'h0;
    mon_armed       = 1'b0;
    mon_tc_prev     = 1'b0;
    uart_rxd        = 1'b1;
    reset_n         = 1'b0;
    p1_title_on = 1'b0; p1_title_off = 1'b0;
    p2_dig0 = 1'b0; p3_bg = 1'b0; p4_digF = 1'b0; p5_busy = 1'b0;
    t6_ser_ok = 1'b0; t8_disp_ok = 1'b1;

    repeat (10) @(posedge hdmi_clk);
    reset_n = 1'b1;
    repeat (20) @(posedge pix_clk);

    // H0: pixel clock = hdmi/5 -> 39.72265 ns period.
    @(negedge pix_clk);
    t1 = $realtime;
    @(negedge pix_clk);
    t2 = $realtime;
    check("H0 pixclk /5", (t2 - t1 > 39.4) && (t2 - t1 < 40.1));

    // H1: line period = 800 pix = 31778.12 ns nominal. NOTE: icarus rounds
    // the 3.972265 ns hdmi half-period to 1 ps, so the measured line lands
    // ~2 ns low (31776.0); window accordingly. Cycle-exact structure is
    // proven by H5 (de-count) + H0 (rate); this is a consistency cross-check.
    @(negedge hs);
    t1 = $realtime;
    @(negedge hs);
    t2 = $realtime;
    check("H1 line 800pix", (t2 - t1 > 31770.0) && (t2 - t1 < 31786.0));

    // H2: hsync low = 96 pix = 3813.38 ns.
    t1 = $realtime; // still at falling edge
    @(posedge hs);
    t2 = $realtime;
    check("H2 hsync 96pix", (t2 - t1 > 3811.0) && (t2 - t1 < 3816.0));

    // H3: frame = 525 lines = 16.683513 ms.
    @(posedge vs);
    t1 = $realtime;
    @(posedge vs);
    t2 = $realtime;
    check("H3 frame 525lines", (t2 - t1 > 16680000.0) && (t2 - t1 < 16687000.0));

    // H4: vsync low = 2 lines = 63556.24 ns (measured fall to rise).
    @(negedge vs);
    t1 = $realtime;
    @(posedge vs);
    t2 = $realtime;
    check("H4 vsync 2lines", (t2 - t1 > 63500.0) && (t2 - t1 < 63620.0));

    // Force the DUT text state for the T-sweep (monitors off: forced
    // watermarks would trip monotonicity; hard reset before U-group).
    // DURABLE = 0x1234ABCD_5678EF90, VISIBLE = 0x0000000A_0000000B,
    // ERROR = 0, busy via forced COMMIT state.
    force top.u_dut.durable = 64'h1234ABCD5678EF90;
    force top.u_dut.visible = 64'h0000000A0000000B;
    force top.u_dut.error = 32'h00000000;
    force top.u_dut.state = 3'd3;

    // H5: exactly 640*480 = 307200 de pixels per frame + T-sweep.
    @(posedge pix_clk);
    while (!(top.u_timing.v == 10'd0 && top.u_timing.h == 10'd0))
      @(posedge pix_clk);
    n = 0;
    for (i = 0; i < 420000; i = i + 1) begin
      #1;
      if (top.u_timing.de) n = n + 1;
      // T-sweep pixel samples (text outputs are combinational).
      if (top.u_timing.v == 10'd16) begin
        if (top.u_timing.h == 10'd17)
          p1_title_on = (top.u_text.r === 8'hFF
                         && top.u_text.g === 8'hB0
                         && top.u_text.b === 8'h00);
        if (top.u_timing.h == 10'd16)
          p1_title_off = (top.u_text.r === 8'h00
                          && top.u_text.g === 8'h00
                          && top.u_text.b === 8'h00);
      end
      if (top.u_timing.v == 10'd32) begin
        if (top.u_timing.h == 10'd217)
          p2_dig0 = (top.u_text.r === 8'hFF
                     && top.u_text.g === 8'hFF
                     && top.u_text.b === 8'hFF);
        if (top.u_timing.h == 10'd193)
          p4_digF = (top.u_text.r === 8'hFF
                     && top.u_text.g === 8'hFF
                     && top.u_text.b === 8'hFF);
      end
      if (top.u_timing.v == 10'd33 && top.u_timing.h == 10'd4)
        p3_bg = (top.u_text.r === 8'h00
                 && top.u_text.g === 8'h00
                 && top.u_text.b === 8'h00);
      if (top.u_timing.v == 10'd70 && top.u_timing.h == 10'd66)
        p5_busy = (top.u_text.r === 8'hFF
                   && top.u_text.g === 8'hFF
                   && top.u_text.b === 8'hFF);
      // T8: running-disparity stays bounded during active video.
      if (top.u_timing.de) begin
        cnow = top.u_enc0.cnt;
        if (cnow > 6'sd20 || cnow < -6'sd20) t8_disp_ok = 1'b0;
      end
      @(posedge pix_clk);
    end
    check("H5 de-count 307200", n == 307200);
    check("T1 title D amber-on", p1_title_on);
    check("T1 title bg-off", p1_title_off);
    check("T2 DURABLE-lo digit0", p2_dig0);
    check("T3 text background", p3_bg);
    check("T4 DURABLE-lo digitF", p4_digF);
    check("T5 BUSY digit1", p5_busy);
    check("T8 disparity bounded", t8_disp_ok);

    // T6+T7: stable blank (hsync=0, vsync=1) -> ch0 control {1,0} =
    // 10'b0101010100 on the parallel word; the ODDR stream must repeat it
    // LSB-first (phase-free check over 30 hdmi edges = 3 words).
    @(posedge pix_clk);
    while (!(top.u_timing.v == 10'd485 && top.u_timing.h == 10'd660))
      @(posedge pix_clk);
    repeat (4) @(posedge pix_clk);
    #1;
    t_w = top.u_enc0.tmds;
    check("T7 control-code {vs,hs}={1,0}", t_w === 10'b0101010100);
    for (k = 0; k < 30; k = k + 1) begin
      @(hdmi_clk);
      #0.3;
      sercap[k] = top.u_out.ser[0];
    end
    t6_ser_ok = 1'b0;
    for (ph = 0; ph < 10; ph = ph + 1) begin
      n = 1;
      for (k = 0; k < 30; k = k + 1) begin
        if (sercap[k] !== t_w[(k + ph) % 10]) n = 0;
      end
      if (n == 1) t6_ser_ok = 1'b1;
    end
    check("T6 serializer LSB-first x10", t6_ser_ok);
    // OBUF polarity on a settled bit.
    #1;
    check("T6b diff-pair polarity",
          (tmds_d_p[0] === top.u_out.ser[0])
          && (tmds_d_n[0] === ~top.u_out.ser[0]));
    // T6c: TMDS clock pair carries 50 %-duty 25.175 MHz (5/10 ones).
    n = 0;
    for (k = 0; k < 10; k = k + 1) begin
      @(hdmi_clk);
      #0.3;
      if (tmds_clk_p === 1'b1) n = n + 1;
    end
    check("T6c tmds-clk 50pct", n == 5);

    // Release text forces, hard-reset the DUT, arm monitors, and run the
    // UART group on live state with back-to-back display polls.
    release top.u_dut.durable;
    release top.u_dut.visible;
    release top.u_dut.error;
    release top.u_dut.state;
    reset_n = 1'b0;
    repeat (10) @(posedge hdmi_clk);
    reset_n = 1'b1;
    repeat (20) @(posedge pix_clk);
    mon_armed = 1'b1;
    // Continuous back-to-back display polls from here on (max pressure on
    // the shared bus; the UART must stay bit-exact regardless).
    force top.ps_timer = 20'd503499;

    // U1: PING through this top.
    u_ping(t_ok);
    check("U1 PING/PONG", t_ok);

    // U2: one good submit -> durable == 1 + trusted pulse observed.
    n = mon_trusted_cnt;
    submit_one_uart(32'd0, 32'hDEAD_BEEF, 32'h12345678, 32'h0, 1'b0, t_ok);
    check("U2 submit0 ok", t_ok && (top.u_dut.durable == 64'd1));
    check("U2 trusted pulsed", mon_trusted_cnt == n + 1);

    // U3: READ-REG DURABLE_LO through the shared bus under poll load.
    u_read(A_DUR_LO, t_rdata, t_ok);
    check("U3 read DUR_LO==1", t_ok && (t_rdata == 32'd1));

    // U4: two more submits -> durable == 3 (UART exact under max polls).
    submit_one_uart(32'd1, 32'h11111111, 32'h22222222, 32'h0, 1'b0, t_ok);
    submit_one_uart(32'd2, 32'h33333333, 32'h44444444, 32'h0, 1'b0, t_ok2);
    check("U4 submits 1,2 ok", t_ok && t_ok2 && (top.u_dut.durable == 64'd3));

    // U5: poller snapshots converged to the live registers; ERROR clean
    // (poller plants no MALFORMED), VERSION == 1.
    repeat (20000) @(posedge pix_clk); // let several poll rounds complete
    u_read(A_ERROR, t_err, t_ok);
    check("U5 poller vis==3", top.snap_vis_lo == 32'd3
                              && top.snap_vis_hi == 32'd0);
    check("U5 poller ver==1", top.snap_ver == 32'h00000001);
    check("U5 ERROR clean", t_ok && (t_err == 32'h00000000)
                            && (top.snap_err == 32'h00000000));

    $display("checks passed: %0d  failed: %0d", checks_passed, checks_failed);
    if (checks_failed == 0)
      $display("PASS");
    else
      $display("FAIL");
    $finish;
  end

endmodule
