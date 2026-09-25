// SPDX-License-Identifier: Apache-2.0
// rtl/dut_top_uart.v -- wrap (don't modify) durable_tid_v0 with dut_uart.
//
// Top for the Tang Console / Mega 138K SOM host-harness path: the DUT file
// itself is UNTOUCHED; this file only instantiates + wires.
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
  parameter CLK_HZ         = 50000000, // must match the board clock (V22)
  parameter BAUD           = 115200,   // host harness baud, 8-N-1
  parameter COMMIT_LATENCY = 2         // passthrough to durable_tid_v0
) (
  input         clk,               // board pin V22 (50 MHz)
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
    .clk                (clk),
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
    .CLK_HZ (CLK_HZ),
    .BAUD   (BAUD)
  ) u_uart (
    .clk            (clk),
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
