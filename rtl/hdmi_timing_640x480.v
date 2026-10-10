// SPDX-License-Identifier: Apache-2.0
// rtl/hdmi_timing_640x480.v -- 640x480@60Hz video timing (VESA DMT, VId 1).
//
// Pixel clock 25.175 MHz (59.94 Hz) or 25.2 MHz (60 Hz); both lie within any
// sane monitor tolerance. Our pixel clock is 125.875/5 = 25.175 MHz.
//   H: 640 visible + 16 front + 96 sync + 48 back  = 800
//   V: 480 visible + 10 front + 2 sync + 33 back   = 525
// Syncs are active-low. de = display enable (visible area); x/y valid iff de.

`timescale 1ns / 1ps

module hdmi_timing_640x480 (
  input        clk_pixel,
  input        rst,            // synchronous, active high
  output reg   hsync,
  output reg   vsync,
  output reg   de,
  output reg [9:0] x,          // 0..639 while de
  output reg [9:0] y           // 0..479 while de
);

  localparam H_VIS = 640;
  localparam H_FP  = 16;
  localparam H_SYN = 96;
  localparam H_BP  = 48;
  localparam H_TOT = 800;
  localparam V_VIS = 480;
  localparam V_FP  = 10;
  localparam V_SYN = 2;
  localparam V_BP  = 33;
  localparam V_TOT = 525;

  reg [9:0] h;
  reg [9:0] v;

  always @(posedge clk_pixel) begin
    if (rst) begin
      h <= 10'd0;
      v <= 10'd0;
    end else if (h == H_TOT - 1) begin
      h <= 10'd0;
      if (v == V_TOT - 1)
        v <= 10'd0;
      else
        v <= v + 10'd1;
    end else begin
      h <= h + 10'd1;
    end
  end

  always @(*) begin
    hsync = ~((h >= H_VIS + H_FP) && (h < H_VIS + H_FP + H_SYN));
    vsync = ~((v >= V_VIS + V_FP) && (v < V_VIS + V_FP + V_SYN));
    de    = (h < H_VIS) && (v < V_VIS);
    x     = h;
    y     = v;
  end

endmodule
