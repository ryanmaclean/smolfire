// SPDX-License-Identifier: Apache-2.0
// rtl/hdmi_tmds_encode.v -- Verilog-2001 TMDS encoder (one channel, DVI mode).
//
// Transition-minimized differential signaling encode per HDMI 1.4a Section
// 5.4.4.1 (video) / 5.4.2 (control), which is identical to DVI 1.0 Section
// 3.2. Original implementation written for this repo; the algorithm is the
// standards-defined procedure. Algorithmic reference (NOT copied -- different
// expression, Verilog-2001, registered-output variant):
//   hdl-util/hdmi (Sameer Puri), dual-licensed MIT OR Apache-2.0,
//   https://github.com/hdl-util/hdmi -- src/hdmi2/tmds_channel.sv in
//   nand2mario/nestang is derived from it, but nestang as a whole is
//   GPLv3 (COPYING), so nothing is copied from nestang; the pinout in
//   nestang src/boards/console.cst is used only as board evidence (see
//   rtl/dut_hdmi.cst + rtl/README.md).
//
// DVI-mode operation only (no TERC4 data islands, no guard bands, no audio):
//   de=1 -> 8-bit video data encoded with running disparity `cnt`.
//   de=0 -> 2-bit control code (ch0 carries {vsync,hsync}; ch1/ch2 tie 0).
// Output is registered (one pixel-clock latency); `cnt` resets on control.
//
// Bit order: tmds[0] is transmitted FIRST (feeds OSER10 D0 -- same wiring as
// the hardware-proven nestang serializer path, see rtl/hdmi_gowin_out.v).

`timescale 1ns / 1ps

module hdmi_tmds_encode (
  input        clk_pixel,
  input        rst,            // synchronous, active high
  input  [7:0] video_data,
  input  [1:0] control_data,
  input        de,             // 1 = video, 0 = control period
  output reg [9:0] tmds
);

  // Population count of 8 bits (0..8).
  function [3:0] ones8;
    input [7:0] v;
    reg [3:0] s;
    begin
      s = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
      ones8 = s;
    end
  endfunction

  // Transition-minimized 9-bit intermediate word.
  reg [8:0] q_m;
  // Ones/zeros in q_m[7:0].
  reg [3:0] n1q;
  reg [3:0] n0q;
  // Code selected for this pixel (combinational), disparity delta.
  reg [9:0] q_out;
  reg signed [5:0] add;
  // Running disparity (signed; bounded to a few units in practice).
  reg signed [5:0] cnt;
  // Ones in the raw video byte.
  reg [3:0] n1d;
  integer i;

  always @(*) begin
    n1d = ones8(video_data);
    // Stage 1: XOR/XNOR chain (DVI 1.0 Fig. 3-5).
    q_m[0] = video_data[0];
    if (n1d > 4'd4 || (n1d == 4'd4 && video_data[0] == 1'b0)) begin
      for (i = 0; i < 7; i = i + 1)
        q_m[i+1] = q_m[i] ~^ video_data[i+1];
      q_m[8] = 1'b0;
    end else begin
      for (i = 0; i < 7; i = i + 1)
        q_m[i+1] = q_m[i] ^ video_data[i+1];
      q_m[8] = 1'b1;
    end
    n1q = ones8(q_m[7:0]);
    n0q = 4'd8 - n1q;
    // Stage 2: disparity management (DVI 1.0 Fig. 3-6).
    if (cnt == 6'sd0 || n1q == 4'd4) begin
      if (q_m[8]) begin
        q_out = {1'b0, 1'b1, q_m[7:0]};
        add   = n1q - n0q;
      end else begin
        q_out = {1'b1, 1'b0, ~q_m[7:0]};
        add   = n0q - n1q;
      end
    end else if ((cnt > 6'sd0 && n1q > n0q) || (cnt < 6'sd0 && n1q < n0q)) begin
      q_out = {1'b1, q_m[8], ~q_m[7:0]};
      add   = (n0q - n1q) + (q_m[8] ? 6'sd2 : 6'sd0);
    end else begin
      q_out = {1'b0, q_m[8], q_m[7:0]};
      add   = (n1q - n0q) - (~q_m[8] ? 6'sd2 : 6'sd0);
    end
  end

  // Control codes (HDMI 1.4a Table 5-2 / DVI 1.0 Table 3-1); same table on
  // all three channels in DVI mode.
  reg [9:0] ctl_code;
  always @(*) begin
    case (control_data)
      2'b00:   ctl_code = 10'b1101010100;
      2'b01:   ctl_code = 10'b0010101011;
      2'b10:   ctl_code = 10'b0101010100;
      default: ctl_code = 10'b1010101011;
    endcase
  end

  always @(posedge clk_pixel) begin
    if (rst) begin
      tmds <= 10'b1101010100;
      cnt  <= 6'sd0;
    end else if (de) begin
      tmds <= q_out;
      cnt  <= cnt + add;
    end else begin
      tmds <= ctl_code;
      cnt  <= 6'sd0;
    end
  end

endmodule
