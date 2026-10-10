// SPDX-License-Identifier: Apache-2.0
// rtl/hdmi_gowin_out.v -- Gowin GW5A-138 output stage for the HDMI DVI signal.
//
//   hdmi_clk (125.875 MHz, MS5351 CLK2 single-ended into V10)
//     -> fabric /5 (registered, glitch-free) -> pix_clk (25.175 MHz)
//   TMDS words (pixel domain) -> per-channel 10-bit shift register,
//   2 bits per hdmi_clk cycle -> ODDR (DDR, D0 on rising) -> ELVDS_OBUF
//   -> tmds_d_p/n[2:0]; the TMDS clock pair carries a 50 %-duty 25.175 MHz
//   square wave through a fourth shift+ODDR (a fabric 40/60 net would sit
//   exactly on the TMDS clock duty limit).
//
// WHY THIS SHAPE (all verified 2026-10-10 on 7950x4090pop, OSS flow,
// himbaechel-gowin GW5AST-138C -- see rtl/README.md for the full logs):
//   * The device DB models exactly ONE placeable BUFG, so at most one
//     pin clock may need a global buffer: hdmi_clk takes it. (Two plain
//     input clocks already need 2 BUFGs and fail.)
//   * CLKDIV / DCE / rPLL have no placeable BELs (HCLK placer places 0;
//     "no BELs remaining"), so the /5 must be a fabric net. Fabric clocks
//     place, route, and MEET TIMING in this flow (E1 experiment: 414 MHz
//     achieved on a fabric clock) -- the Sept 2026 hold lesson belonged to
//     the old apicula/nextpnr-gowin flow.
//   * OSER10 packs but its FCLK/PCLK pins are unreachable from general-pin
//     clocks ("Failed to route ... to FCLKA using dedicated routing", then
//     a router crash on the fallback) -- HCLK-only pins fed by unplaceable
//     HCLK cells. ODDR + ELVDS_OBUF place, route, and meet timing (T15:
//     766 MHz achieved on the 125.875 domain) with 1 BUFG total.
//   * The shift-plus-DDR structure is the same "IP-less implementation"
//     fallback nestang ships in src/hdmi2/serializer.sv for unknown
//     platforms (independent expression here, Verilog-2001).
//
// Bit order: W[0] first on the rising edge, W[1] on the falling edge, ...,
// W[9] last -- LSB-first, matching the hardware-proven OSER10 wiring
// (D0 = tmds[0]) used by nestang's GW_IDE path and hamsterworks' Xilinx
// DVI demos. ASSUMPTIONS flagged for the load wave: ODDR Q0 carries D0 on
// the rising edge / D1 on the falling edge, and TX=1 enables the driver
// (LiteX Gowin DDROutput convention); a swapped/dead pair on first light
// means exactly one of these two one-line fixes.
//
// V10 input MUST be PULL_MODE=NONE (AC-coupled MS5351); see rtl/dut_hdmi.cst.

`timescale 1ns / 1ps

module hdmi_gowin_out (
  input        hdmi_clk,      // 125.875 MHz serial clock (pin V10)
  input        rst_n,         // async assert (board reset_n)
  input  [9:0] tmds0,
  input  [9:0] tmds1,
  input  [9:0] tmds2,
  output       pix_clk,       // 25.175 MHz fabric pixel clock
  output [2:0] tmds_d_p,
  output [2:0] tmds_d_n,
  output       tmds_clk_p,
  output       tmds_clk_n
);

  // Sync-release reset in the hdmi domain (async assert would join the
  // board-wide async CLEAR tree; sync keeps this block out of the reset
  // removal checks entirely -- release metastability settles within the
  // multi-cycle pixel period, invisible downstream).
  reg [1:0] h_rel_sync;
  always @(posedge hdmi_clk or negedge rst_n) begin
    if (!rst_n)
      h_rel_sync <= 2'b00;
    else
      h_rel_sync <= {h_rel_sync[0], 1'b1};
  end
  wire h_rel_n = h_rel_sync[1];

  // Fabric /5: pix_r high 2 of every 5 serial cycles (registered,
  // glitch-free). The PnR tool promotes it onto the clock network
  // (E1-proven); no BUFG/CLKDIV primitive exists for it in this flow.
  reg [2:0] div_cnt;
  reg       pix_r;
  always @(posedge hdmi_clk) begin
    if (!h_rel_n) begin
      div_cnt <= 3'd0;
      pix_r   <= 1'b0;
    end else if (div_cnt == 3'd4) begin
      div_cnt <= 3'd0;
      pix_r   <= 1'b1;
    end else begin
      div_cnt <= div_cnt + 3'd1;
      pix_r   <= (div_cnt < 3'd1);
    end
  end
  assign pix_clk = pix_r;

  // Word-load pulse: pix rising edge detected in the hdmi domain. The TMDS
  // words are stable for the whole 5-cycle pixel period (encoder registers
  // update on pix_clk), so sampling 2 cycles after the edge is safe.
  reg [1:0] pix_sync;
  always @(posedge hdmi_clk) begin
    if (!h_rel_n)
      pix_sync <= 2'b00;
    else
      pix_sync <= {pix_sync[0], pix_r};
  end
  wire load_w = pix_sync[0] & ~pix_sync[1];
  reg  load_d;
  always @(posedge hdmi_clk) begin
    if (!h_rel_n)
      load_d <= 1'b0;
    else
      load_d <= load_w;
  end

  // One 10-bit shift channel: load the word, then shift 2 bits per serial
  // cycle into the ODDR. Steady-state phase is constant (both clocks from
  // the same source); 5 shifts x 2 bits = the full word per pixel period.
  // (Three explicit channels: Verilog-2001 has no unpacked array ports.)
  wire [2:0] ser;

  reg [9:0] sr0, sr1, sr2;
  always @(posedge hdmi_clk) begin
    if (!h_rel_n) begin
      sr0 <= 10'd0;
      sr1 <= 10'd0;
      sr2 <= 10'd0;
    end else if (load_d) begin
      sr0 <= tmds0;
      sr1 <= tmds1;
      sr2 <= tmds2;
    end else begin
      sr0 <= {2'b00, sr0[9:2]};
      sr1 <= {2'b00, sr1[9:2]};
      sr2 <= {2'b00, sr2[9:2]};
    end
  end

  ODDR u_oddr0 (.D0(sr0[0]), .D1(sr0[1]), .TX(1'b1), .CLK(hdmi_clk),
                .Q0(ser[0]), .Q1());
  ODDR u_oddr1 (.D0(sr1[0]), .D1(sr1[1]), .TX(1'b1), .CLK(hdmi_clk),
                .Q0(ser[1]), .Q1());
  ODDR u_oddr2 (.D0(sr2[0]), .D1(sr2[1]), .TX(1'b1), .CLK(hdmi_clk),
                .Q0(ser[2]), .Q1());

  // TMDS clock channel: 50 %-duty 25.175 MHz square wave through its own
  // shift + ODDR (a fabric 40/60 %-duty net would sit exactly on the TMDS
  // clock duty limit; 5 samples/pixel cannot make 50 % single-ended, but
  // 10 DDR samples can: 11111_00000 per pixel period).
  reg [9:0] sr3;
  wire      ser_clk;
  always @(posedge hdmi_clk) begin
    if (!h_rel_n)
      sr3 <= 10'd0;
    else if (load_d)
      sr3 <= 10'b1111100000;
    else
      sr3 <= {2'b00, sr3[9:2]};
  end
  ODDR u_oddr3 (.D0(sr3[0]), .D1(sr3[1]), .TX(1'b1), .CLK(hdmi_clk),
                .Q0(ser_clk), .Q1());

  // Single-ended serial streams -> differential pairs (data + 50 %-duty
  // TMDS clock, DVI convention).
  ELVDS_OBUF u_obuf_clk (.I(ser_clk), .O(tmds_clk_p), .OB(tmds_clk_n));
  ELVDS_OBUF u_obuf_0   (.I(ser[0]), .O(tmds_d_p[0]), .OB(tmds_d_n[0]));
  ELVDS_OBUF u_obuf_1   (.I(ser[1]), .O(tmds_d_p[1]), .OB(tmds_d_n[1]));
  ELVDS_OBUF u_obuf_2   (.I(ser[2]), .O(tmds_d_p[2]), .OB(tmds_d_n[2]));

endmodule
