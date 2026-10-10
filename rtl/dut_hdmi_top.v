// SPDX-License-Identifier: Apache-2.0
// rtl/dut_hdmi_top.v -- DUT + UART host path + 640x480 HDMI status display.
//
// Single-clock design: EVERYTHING runs on pix_clk (25.175 MHz), the fabric
// /5 of the 125.875 MHz MS5351 CLK2 input. Wraps (does NOT modify)
// durable_tid_v0 + dut_uart with the dut_top_uart wiring pattern (UART
// divisor now for 25.175 MHz: exact average rate via the bridge's Bresenham
// accumulators -- see dut_uart.v), plus the display poller (same clock, so
// NO clock-domain crossing anywhere on the status path) and the HDMI pipe
// (timing + text + TMDS + shift/ODDR/ELVDS_OBUF, DVI mode).
//
// Clocking:
//   hdmi_clk (V10, 125.875 MHz MS5351 CLK2, LVCMOS33, PULL_MODE=NONE -
//            AC-coupled): the flow's single global buffer carries it to the
//            2-bit DDR shift registers + ODDR.CLK; a fabric /5 (registered,
//            glitch-free, tool-promoted like E1) makes pix_clk 25.175 MHz
//            for all logic + OSER... i.e. ODDR-pair timing + TMDS word load.
//   V22 (50 MHz board osc) is UNUSED by this top (dut_top_uart keeps it).
// Why single-clock: himbaechel-gowin GW5AST-138C models exactly ONE
// placeable BUFG (two pin clocks already fail), and CLKDIV/DCE/rPLL have no
// placeable BELs while OSER10's FCLK/PCLK pins are unreachable from
// general-pin clocks -- so the serial rate comes straight from MS5351 and
// everything else shares the fabric /5 (see rtl/README.md for the
// experiment log: T1/T5/T6/T10/T13/T15/E1/E2).
// MS5351 programming is a LOAD-WAVE step (`pll_clk O2=125875K` on the BL616
// console); this RTL only consumes the clock. See rtl/dut_hdmi.cst +
// rtl/README.md (V10 routing is UNCONFIRMED -- single-source prior recon).
//
// Verilog-2001 only.

`timescale 1ns / 1ps

module dut_hdmi_top #(
  parameter PIX_HZ         = 25175000, // 125.875 MHz / 5 (MS5351 CLK2)
  parameter BAUD           = 115200,   // host harness baud, 8-N-1
  parameter COMMIT_LATENCY = 2         // passthrough to durable_tid_v0
) (
  input         hdmi_clk,          // MS5351 CLK2 pin V10 (125.875 MHz)
  input         reset_n,           // async assert, sync release (board E3)
  input         uart_rxd,          // board pin V14 (from debugger TX)
  output        uart_txd,          // board pin U15 (to debugger RX)
  output [2:0]  tmds_d_p,          // HDMI data pairs (G15/G16 clk, J14/H14 D0,
  output [2:0]  tmds_d_n,          //   J15/H15 D1, K17/J17 D2 -- see .cst)
  output        tmds_clk_p,
  output        tmds_clk_n,
  output        trusted_complete_o,// observation (DUT pulse, pix domain)
  output        busy_o              // observation (DUT busy, pix domain)
);

  // DUT durable watermark (internal only -- shown on the display and
  // readable via UART; NOT pinned out. Pinning all 64 bits scatters
  // placement across the package and worsens pix-clock skew for zero
  // functional gain. dut_top_uart keeps the full observation bus.)
  wire [63:0] durable_tid_o;

  // Pin-name documentation (placement lives in dut_hdmi.cst on the build
  // host, same convention as dut_top_uart.v).
  localparam UART_RX_PIN = "V14";
  localparam UART_TX_PIN = "U15";
  localparam HDMI_CLK_PIN = "V10";

  // Pixel clock: fabric /5 inside u_out (single global buffer holds
  // hdmi_clk; pix is tool-promoted -- see header).
  wire pix_clk;
  wire pix_rst_n;
  reg [1:0] rst_pix_sync;
  always @(posedge pix_clk or negedge reset_n) begin
    if (!reset_n)
      rst_pix_sync <= 2'b00;
    else
      rst_pix_sync <= {rst_pix_sync[0], 1'b1};
  end
  assign pix_rst_n = rst_pix_sync[1];
  wire pix_rst = ~pix_rst_n;

  // ------------------------------------------------- pix domain: DUT+UART
  // Avalon-MM link: UART bridge (priority master) + display poller share
  // the single DUT slave through the change-detecting mux below.
  wire [11:0] u_address;
  wire [31:0] u_writedata;
  wire [31:0] u_readdata;   // common slave read bus (each side own sample)
  wire        u_read;
  wire        u_write;
  wire [3:0]  u_byteenable;
  wire        u_reset;
  wire        u_busy;          // bridge protocol-active (see dut_uart.v)

  wire [11:0] d_address;
  wire [31:0] d_writedata;
  wire [31:0] d_readdata;
  wire        d_read;
  wire        d_write;
  wire [3:0]  d_byteenable;
  wire        d_reset;
  wire        d_readdatavalid;
  wire        d_waitrequest;

  durable_tid_v0 #(
    .COMMIT_LATENCY (COMMIT_LATENCY)
  ) u_dut (
    .clk                (pix_clk),
    .reset_n            (pix_rst_n),
    .fsm_reset_i        (d_reset),
    .avs_address        (d_address),
    .avs_writedata      (d_writedata),
    .avs_readdata       (d_readdata),
    .avs_read           (d_read),
    .avs_write          (d_write),
    .avs_byteenable     (d_byteenable),
    .avs_waitrequest    (d_waitrequest),
    .avs_readdatavalid  (d_readdatavalid),
    .trusted_complete_o (trusted_complete_o),
    .durable_tid_o      (durable_tid_o),
    .busy_o             (busy_o)
  );

  dut_uart #(
    .CLK_HZ (PIX_HZ),
    .BAUD   (BAUD)
  ) u_uart (
    .clk            (pix_clk),
    .reset_n        (pix_rst_n),
    .uart_rxd       (uart_rxd),
    .uart_txd       (uart_txd),
    .avr_address    (u_address),
    .avr_writedata  (u_writedata),
    .avr_readdata   (u_readdata),
    .avr_read       (u_read),
    .avr_write      (u_write),
    .avr_byteenable (u_byteenable),
    .avr_reset_o    (u_reset),
    .avr_busy_o     (u_busy)
  );

  // --------------------------------------- transparent display-poll mux ---
  // Borrow grant: the bridge is protocol-idle AND its address has been
  // parked AND the bus saw no activity for 4 cycles. The busy term is the
  // load-bearing one: the bridge stages its address a cycle before
  // asserting (always inside a busy window -- mid-frame, RX-active, or
  // execute/TX), so a same-address consecutive read (no visible address
  // change) still revokes the grant in time. quiet + addr_stable are
  // defense in depth. Capture only windows where the grant never drops;
  // the UART is never delayed. (Proven by the U1..U5 TB checks under
  // back-to-back polling; the first mux generation corrupted host reads
  // and was root-caused to the bridge's stage-before-assert convention.)
  localparam [7:0] P_VIS_LO = 8'h10;
  localparam [7:0] P_VIS_HI = 8'h4C;
  localparam [7:0] P_ERROR  = 8'h18;
  localparam [7:0] P_VERS   = 8'h58;

  localparam [2:0] PS_IDLE  = 3'd0;
  localparam [2:0] PS_ISSUE = 3'd1;
  localparam [2:0] PS_W0    = 3'd2;
  localparam [2:0] PS_W1    = 3'd3;
  localparam [2:0] PS_CAP   = 3'd4;

  reg [2:0]  ps_state;
  reg [1:0]  ps_idx;          // 0..3 -> VIS_LO, VIS_HI, ERROR, VERSION
  reg [19:0] ps_timer;        // poll interval (~20 ms at 25.175 MHz)
  reg [11:0] ps_addr;
  reg        ps_read;         // poll read request (1 cycle)
  reg        ps_g0, ps_g1, ps_g2; // grant held at T,T+1,T+2 of the window
  reg [11:0] u_addr_d1, u_addr_d2, u_addr_d3; // bridge address history
  reg [3:0]  quiet_sh;        // ~uart_act history (4 cycles)
  // Snapshot registers for the display (same clock -- no CDC).
  reg [31:0] snap_vis_lo, snap_vis_hi, snap_err, snap_ver;
  reg        snap_toggle;     // toggles per completed 4-read round

  wire uart_act = u_read | u_write;
  wire addr_stable = (u_address == u_addr_d1) && (u_address == u_addr_d2)
                  && (u_address == u_addr_d3);
  wire poll_grant = (quiet_sh == 4'b1111) && addr_stable && !u_busy;

  // Mux: the bridge's bundle flows whenever it is active OR the poller has
  // no grant; the poller drives address+read only under a held grant.
  assign d_address    = poll_grant ? ps_addr : u_address;
  assign d_writedata  = u_writedata;   // poller never writes
  assign d_byteenable = u_byteenable;  // poller never writes
  assign d_read       = u_read | (ps_read & poll_grant);
  assign d_write      = u_write;       // poller never writes
  assign d_reset      = u_reset;       // poller never resets
  assign u_readdata   = d_readdata;

  always @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
      ps_state   <= PS_IDLE;
      ps_idx     <= 2'd0;
      ps_timer   <= 20'd0;
      ps_addr    <= 12'h000;
      ps_read    <= 1'b0;
      ps_g0      <= 1'b0;
      ps_g1      <= 1'b0;
      ps_g2      <= 1'b0;
      u_addr_d1  <= 12'h000;
      u_addr_d2  <= 12'h000;
      u_addr_d3  <= 12'h000;
      quiet_sh   <= 4'b0000;
      snap_vis_lo <= 32'h00000000;
      snap_vis_hi <= 32'h00000000;
      snap_err    <= 32'h00000000;
      snap_ver    <= 32'h00000000;
      snap_toggle <= 1'b0;
    end else begin
      u_addr_d1 <= u_address;
      u_addr_d2 <= u_addr_d1;
      u_addr_d3 <= u_addr_d2;
      quiet_sh  <= {quiet_sh[2:0], ~uart_act};
      ps_read <= 1'b0; // default: single-cycle pulse in ISSUE only
      case (ps_state)
        PS_IDLE: begin
          if (ps_timer == 20'd503499) begin
            ps_timer <= 20'd0;
            // Stage the address early (same convention as the UART
            // bridge); it reaches the bus only under a held grant.
            case (ps_idx)
              2'd0: ps_addr <= {4'h0, P_VIS_LO};
              2'd1: ps_addr <= {4'h0, P_VIS_HI};
              2'd2: ps_addr <= {4'h0, P_ERROR};
              default: ps_addr <= {4'h0, P_VERS};
            endcase
            ps_state <= PS_ISSUE;
          end else begin
            ps_timer <= ps_timer + 20'd1;
          end
        end
        PS_ISSUE: begin
          // Issue only under a held grant; else wait (timer stays 0 so
          // we retry every cycle -- the UART is never delayed).
          if (poll_grant) begin
            ps_read <= 1'b1;
            ps_g0   <= poll_grant;
            ps_state <= PS_W0;
          end
        end
        PS_W0: begin
          ps_g1 <= poll_grant;
          ps_state <= PS_W1;
        end
        PS_W1: begin
          ps_g2 <= poll_grant;
          ps_state <= PS_CAP;
        end
        PS_CAP: begin
          // Capture iff the slave answered AND the grant held across the
          // whole sample window (issue + 2 latency cycles).
          if (d_readdatavalid && ps_g0 && ps_g1 && ps_g2 && poll_grant) begin
            case (ps_idx)
              2'd0: snap_vis_lo <= d_readdata;
              2'd1: snap_vis_hi <= d_readdata;
              2'd2: snap_err    <= d_readdata;
              default: snap_ver <= d_readdata;
            endcase
            if (ps_idx == 2'd3) begin
              ps_idx      <= 2'd0;
              snap_toggle <= ~snap_toggle;
            end else begin
              ps_idx <= ps_idx + 2'd1;
            end
            ps_state <= PS_IDLE;
          end else begin
            // No capture: grant dropped mid-window (bridge staged or
            // asserted) or the read never landed -- retry via ISSUE
            // (address still staged). The UART is never delayed.
            ps_state <= PS_ISSUE;
          end
        end
        default: ps_state <= PS_IDLE;
      endcase
    end
  end

  // Trusted-complete pulse stretch (~0.5 s at 25.175 MHz) for the TC digit.
  reg [23:0] tc_hold;
  always @(posedge pix_clk or negedge pix_rst_n) begin
    if (!pix_rst_n) begin
      tc_hold <= 24'd0;
    end else if (trusted_complete_o) begin
      tc_hold <= 24'd12587500; // ~0.5 s
    end else if (tc_hold != 24'd0) begin
      tc_hold <= tc_hold - 24'd1;
    end
  end
  wire tc_lit = (tc_hold != 24'd0);

  // ------------------------------------------------------ HDMI video pipe
  // (Same pix_clk throughout: timing + text + encoders are plain logic.)
  wire hsync, vsync, vde;
  wire [9:0] px, py;

  hdmi_timing_640x480 u_timing (
    .clk_pixel (pix_clk),
    .rst       (pix_rst),
    .hsync     (hsync),
    .vsync     (vsync),
    .de        (vde),
    .x         (px),
    .y         (py)
  );

  wire [7:0] pr, pg, pb;
  dut_status_text u_text (
    .x       (px),
    .y       (py),
    .de      (vde),
    .durable (durable_tid_o),
    .visible ({snap_vis_hi, snap_vis_lo}),
    .error   (snap_err),
    .version (snap_ver),
    .busy    (busy_o),
    .tc      (tc_lit),
    .r       (pr),
    .g       (pg),
    .b       (pb)
  );

  wire [9:0] tmds0, tmds1, tmds2;
  hdmi_tmds_encode u_enc0 (
    .clk_pixel (pix_clk), .rst (pix_rst),
    .video_data (pb), .control_data ({vsync, hsync}), .de (vde), .tmds (tmds0)
  );
  hdmi_tmds_encode u_enc1 (
    .clk_pixel (pix_clk), .rst (pix_rst),
    .video_data (pg), .control_data (2'b00), .de (vde), .tmds (tmds1)
  );
  hdmi_tmds_encode u_enc2 (
    .clk_pixel (pix_clk), .rst (pix_rst),
    .video_data (pr), .control_data (2'b00), .de (vde), .tmds (tmds2)
  );

  hdmi_gowin_out u_out (
    .hdmi_clk  (hdmi_clk),
    .rst_n     (reset_n),
    .tmds0     (tmds0),
    .tmds1     (tmds1),
    .tmds2     (tmds2),
    .pix_clk   (pix_clk),
    .tmds_d_p  (tmds_d_p),
    .tmds_d_n  (tmds_d_n),
    .tmds_clk_p(tmds_clk_p),
    .tmds_clk_n(tmds_clk_n)
  );

endmodule
