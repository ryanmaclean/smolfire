// SPDX-License-Identifier: Apache-2.0
// rtl/dut_top_uart.v -- wrap (don't modify) durable_tid_v0 with dut_uart.
//
// Top for the Tang Console / Mega 138K SOM host-harness path: the DUT file
// itself is UNTOUCHED; this file only instantiates + wires.
//
// Divide-by-2 fabric via a proper clock resource (timing closure,
// 2026-09-25): dut_top_uart failed timing at the 50 MHz board clock
// (Fmax 31.6, structural), so the whole fabric (DUT + UART) runs at
// 25 MHz. First attempt (commit 4289a5a) used a reset-aware toggle FF
// (clk25) -- that closed SETUP but failed HOLD (10 violations): a FF
// output driving fabric clock rides general interconnect (~1.8 ns skew
// vs 0.85 ns logic delay), and hold is FREQUENCY-INDEPENDENT, so no
// divider ratio fixes it -- only a dedicated clock resource does. This
// uses the Gowin CLKDIV primitive (UG286: CLKOUT = HCLKIN / DIV_MODE on
// the global clock network; DIV_MODE="2" below; GW5A 4-port variant with
// CALIB tied to 1'b0/inactive -- see synthesis-branch note). The UART divisor uses
// the fabric rate (25000000/115200 = 217 cycles/bit); pin clk stays the
// 50 MHz board clock (V22); UART pins, protocol, and frames are unchanged.
//
// Sim portability: icarus has no CLKDIV model, so the primitive is
// selected only under `SYNTHESIS (defined by the Gowin/Yosys synth
// flow; __YOSYS__ added as a belt-and-braces selector in case the flow
// does not predefine SYNTHESIS); simulation takes the behavioral
// divide-by-2 branch, which restarts in phase (held at 0 under reset)
// exactly like the toggle FF it replaces, so TB clock math is unchanged.
//
// Pin map (GW5AST-LV138PG484A, package PBG484A; research 2026-09-25):
//   uart_rxd (in)  -> V14  (FPGA RX, driven by BL616 debugger TX)
//   uart_txd (out) -> U15  (FPGA TX, into BL616 debugger RX)
//   clk      (in)  -> V22  (50 MHz onboard oscillator)
// Pin evidence: Sipeed TangMega-138K-example
//   ddr_memory/ddr_memory_test_uart/src/ddr3_1v4_hs.cst
//     IO_LOC "uart_tx" U15;  IO_LOC "uart_rx" V14;  IO_LOC "clk" V22;
//   with top.v directions `input uart_rx, output uart_tx`, and the 50 MHz
//   assumption from hdmi.cst (clk V22) + gowin_pll.mod (fclkin 50) +
//   uart_top.v (CLK_FRE 50, BAUD_RATE 115200).
// Source URLs (all fetched 2026-09-25):
//   https://wiki.sipeed.com/hardware/en/tang/tang-mega-138k/mega-138k.html
//   https://wiki.sipeed.com/hardware/en/tang/tang-console/mega-console.html
//   https://github.com/sipeed/TangMega-138K-example
// The SOM carries the debugger (SOM params: "Debug Interface JTAG + UART
// JST SH1.0 8-Pins CONN"), so these SOM-level FPGA pins hold for both the
// Mega 138K Dock and the Tang Console carrier.
//
// Gowin CST additions for dut.cst (apply ON THE BUILD HOST; do not edit
// remote files from here -- see rtl/README.md):
//   IO_LOC "uart_rxd" V14;
//   IO_PORT "uart_rxd" IO_TYPE=LVCMOS33 PULL_MODE=UP BANK_VCCIO=3.3;
//   IO_LOC "uart_txd" U15;
//   IO_PORT "uart_txd" IO_TYPE=LVCMOS33 PULL_MODE=UP DRIVE=8 BANK_VCCIO=3.3;
//   IO_LOC "clk" V22;
//   IO_PORT "clk" IO_TYPE=LVCMOS33 PULL_MODE=NONE BANK_VCCIO=3.3;
//
// Verilog-2001 only.

`timescale 1ns / 1ps

module dut_top_uart #(
  parameter CLK_HZ         = 50000000, // board clock on pin V22 (50 MHz)
  parameter BAUD           = 115200,   // host harness baud, 8-N-1
  parameter COMMIT_LATENCY = 2         // passthrough to durable_tid_v0
) (
  input         clk,               // board pin V22 (50 MHz board clock in)
  input         reset_n,           // async assert, sync release
  input         uart_rxd,          // board pin V14 (from debugger TX)
  output        uart_txd,          // board pin U15 (to debugger RX)
  output        trusted_complete_o, // observation (LED / logic probe)
  output [63:0] durable_tid_o,     // observation
  output        busy_o              // observation
);

  // Pin-name documentation (string localparams; NOT placement constraints --
  // placement lives in dut.cst on the Gowin build host, see header above).
  localparam UART_RX_PIN = "V14";
  localparam UART_TX_PIN = "U15";
  localparam CLK_PIN     = "V22";

  // Fabric clock: divide the 50 MHz board clock by 2 on a dedicated
  // clock resource (see header: toggle-FF dividers fail HOLD because
  // hold is frequency-independent; only clock-network routing fixes it).
  // FABRIC_HZ derives the UART divisor: 25000000 at the default board
  // clock (25000000/115200 = 217 cycles/bit).
  localparam FABRIC_HZ = CLK_HZ / 2;

`ifdef SYNTHESIS
`define DUT_TOP_UART_USE_CLKDIV 1
`endif
`ifdef __YOSYS__
`define DUT_TOP_UART_USE_CLKDIV 1
`endif
`ifdef DUT_TOP_UART_USE_CLKDIV
  // Synthesis: Gowin CLKDIV primitive (UG286 clock resource; 4-port GW5A
  // variant HCLKIN/RESETN/CALIB/CLKOUT per YosysHQ/apicula wiki CLKDIV,
  // which documents this primitive as Apicula-supported with DIV_MODE
  // default "2"). CLKOUT drives the global clock network, so fabric
  // clock skew collapses vs general interconnect and the toggle-FF hold
  // violations go away. CALIB is the IOLOGIC phase-adjust input; tied to
  // 1'b0 (inactive) since this design uses plain divide-by-2 fabric
  // clocking with no phase adjustment.
  wire clk25;
  CLKDIV #(
    .DIV_MODE ("2")
  ) u_clkdiv (
    .CALIB  (1'b0),
    .CLKOUT (clk25),
    .HCLKIN (clk),
    .RESETN (reset_n)
  );
`else
  // Simulation (icarus has no CLKDIV): behavioral divide-by-2,
  // reset-aware (held at 0 under reset so the fabric restarts in phase).
  // Produces a clock identical to the synthesis branch for sim purposes.
  reg clk25_r;
  wire clk25;
  assign clk25 = clk25_r;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n)
      clk25_r <= 1'b0;
    else
      clk25_r <= ~clk25_r;
  end
`endif

  // Avalon-MM-style link between the UART bridge (master) and the DUT.
  wire [11:0] avr_address;
  wire [31:0] avr_writedata;
  wire [31:0] avr_readdata;
  wire        avr_read;
  wire        avr_write;
  wire [3:0]  avr_byteenable;
  wire        avr_reset;

  durable_tid_v0 #(
    .COMMIT_LATENCY (COMMIT_LATENCY)
  ) u_dut (
    .clk                (clk25),
    .reset_n            (reset_n),
    .fsm_reset_i        (avr_reset),
    .avs_address        (avr_address),
    .avs_writedata      (avr_writedata),
    .avs_readdata       (avr_readdata),
    .avs_read           (avr_read),
    .avs_write          (avr_write),
    .avs_byteenable     (avr_byteenable),
    .avs_waitrequest    (),
    .avs_readdatavalid  (),
    .trusted_complete_o (trusted_complete_o),
    .durable_tid_o      (durable_tid_o),
    .busy_o             (busy_o)
  );

  dut_uart #(
    .CLK_HZ (FABRIC_HZ), // fabric rate: 25000000 at the default board clock
    .BAUD   (BAUD)
  ) u_uart (
    .clk            (clk25),
    .reset_n        (reset_n),
    .uart_rxd       (uart_rxd),
    .uart_txd       (uart_txd),
    .avr_address    (avr_address),
    .avr_writedata  (avr_writedata),
    .avr_readdata   (avr_readdata),
    .avr_read       (avr_read),
    .avr_write      (avr_write),
    .avr_byteenable (avr_byteenable),
    .avr_reset_o    (avr_reset)
  );

endmodule
