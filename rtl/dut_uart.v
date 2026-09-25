// SPDX-License-Identifier: Apache-2.0
// rtl/dut_uart.v -- host-reachable UART front-end for durable_tid_v0.
//
// Gives the running DUT a 115200-8-N-1 serial command port so a future host
// harness can drive it over the Tang Console / Mega 138K SOM debugger UART
// (USB tty on the host, BL616 debugger on the board). The DUT file itself is
// UNTOUCHED: this module is a pure Avalon-MM-style master wrapper; see
// rtl/dut_top_uart.v for the top that instantiates both.
//
// Board pin evidence (checked 2026-09-25; see rtl/dut_top_uart.v + README
// for full source URLs):
//   - FPGA pin V14 = uart_rxd INPUT  (driven by BL616 debugger TX)
//   - FPGA pin U15 = uart_txd OUTPUT (into BL616 debugger RX)
//     (Sipeed TangMega-138K-example, ddr_memory/ddr_memory_test_uart/
//     src/ddr3_1v4_hs.cst: `IO_LOC "uart_tx" U15;` + `IO_LOC "uart_rx" V14;`
//     with top.v port directions `input uart_rx, output uart_tx`.)
//   - Onboard clock is 50 MHz on pin V22 (hdmi.cst `IO_LOC "clk" V22;` +
//     gowin_pll.mod `fclkin 50` + uart_top.v `CLK_FRE 50`), hence the
//     CLK_HZ=50000000 default below. Baud divisor error at 115200:
//     50000000/115200 = 434.03 -> 434 cycles/bit (0.006 %); RX 16x tick
//     truncates 434/16 = 27.125 -> 27, i.e. 115740 baud (+0.47 %, < 2 % OK).
//
// Protocol (all multi-byte values little-endian, byte0 = bits[7:0]):
//   CMD frame (host -> FPGA), 9 bytes:
//     [0] MAGIC0 = 0x44 ('D')   [1] MAGIC1 = 0x55 ('U')
//     [2] CMD: 0x01 WRITE-REG | 0x02 READ-REG | 0x03 RESET | 0x04 PING
//     [3] ADDR: byte offset within the DUT 4 KB window (map tops at 0x058,
//         so the low 8 bits suffice; upper 4 address bits are zero)
//     [4..7] DATA (32-bit LE; ignored for READ-REG payload/RESET/PING)
//     [8] CHK = (CMD + ADDR + D0 + D1 + D2 + D3) mod 256
//   RSP frame (FPGA -> host), 8 bytes:
//     [0] MAGIC0  [1] MAGIC1  [2] RSP  [3..6] DATA (LE)
//     [7] CHK = (RSP + D0 + D1 + D2 + D3) mod 256
//     RSP: 0x81 WRITE-ACK (DATA = echo of written value)
//          0x82 READ-DATA (DATA = register value)
//          0x83 RESET-DONE (DATA = RESET_CNT after the reset pulse)
//          0x84 PONG (DATA = VERSION 0x00000000)
//   Malformed frames (bad magic, bad checksum, unknown CMD) are dropped
//   SILENTLY with no response. The host speaks strict request-response:
//   exactly one RSP per well-formed CMD; no bytes are sent while busy.
//
// Avalon bridge: single-cycle reads/writes (DUT waitrequest is tied 0).
// WRITE-REG returns after the write cycle (it does NOT wait for commit;
// the host polls STATUS.BUSY via READ-REG). RESET pulses avr_reset_o for
// exactly 1 clk cycle (== DUT fsm_reset_i semantics), waits 2 cycles, then
// reads back RESET_CNT (offset 0x020) for the response payload.
//
// Verilog-2001 only (Gowin/Yosys + icarus compatible). No vendor IP.

`timescale 1ns / 1ps

module dut_uart #(
  parameter CLK_HZ = 50000000, // fabric clock (Tang board: 50 MHz on V22)
  parameter BAUD   = 115200    // host baud (8-N-1, no flow control)
) (
  input         clk,
  input         reset_n,       // async assert, sync release (as DUT)
  input         uart_rxd,      // FPGA RX pin (board V14)
  output        uart_txd,      // FPGA TX pin (board U15)
  // Avalon-MM-style master port into durable_tid_v0 slave.
  output [11:0] avr_address,
  output [31:0] avr_writedata,
  input  [31:0] avr_readdata,  // DUT read mux is combinational
  output        avr_read,
  output        avr_write,
  output [3:0]  avr_byteenable,
  output        avr_reset_o    // 1-cycle soft-reset pulse -> DUT fsm_reset_i
);

  // Protocol constants.
  localparam [7:0] MAGIC0     = 8'h44; // 'D'
  localparam [7:0] MAGIC1     = 8'h55; // 'U'
  localparam [7:0] CMD_WRITE  = 8'h01;
  localparam [7:0] CMD_READ   = 8'h02;
  localparam [7:0] CMD_RESET  = 8'h03;
  localparam [7:0] CMD_PING   = 8'h04;
  localparam [7:0] RSP_WRITE  = 8'h81;
  localparam [7:0] RSP_READ   = 8'h82;
  localparam [7:0] RSP_RESET  = 8'h83;
  localparam [7:0] RSP_PING   = 8'h84;
  localparam [7:0] A_RSTCNT   = 8'h20; // RESET_CNT byte offset (response data)
  localparam [31:0] VERSION_VAL = 32'h00000000; // v0 (matches DUT A_VERSION)

  // Baud timing (integer division; see header note for 115200 error).
  localparam integer BIT_DIV = CLK_HZ / BAUD; // clk cycles per serial bit
  // RX 16x-oversample tick; floor at 1 (exact when BIT_DIV is a multiple
  // of 16, e.g. sim baud 3125000 at 50 MHz -> BIT_DIV 16, tick 1).
  localparam integer OV_DIV  = ((BIT_DIV / 16) == 0) ? 1 : (BIT_DIV / 16);

  // ---------------------------------------------------------------- RX ---
  // 16x oversampling receiver: IDLE -> HALF (confirm start mid-bit) ->
  // DATA (8 bits, middle-sampled) -> STOP (must be 1, else framing error).
  localparam [1:0] R_IDLE = 2'd0;
  localparam [1:0] R_HALF = 2'd1;
  localparam [1:0] R_DATA = 2'd2;
  localparam [1:0] R_STOP = 2'd3;

  reg        rxd_a, rxd_b;      // 2-FF synchronizer
  wire       rxd_s = rxd_b;
  reg [1:0]  rx_state;
  reg [15:0] rx_ov;             // oversample counter
  reg [2:0]  rx_bit;
  reg [7:0]  rx_sh;
  reg [7:0]  rx_byte;
  reg        rx_valid;          // 1-cycle pulse: rx_byte holds a full byte
  reg        rx_ferr;           // 1-cycle pulse: stop bit was 0, byte dropped

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      rxd_a    <= 1'b1;
      rxd_b    <= 1'b1;
      rx_state <= R_IDLE;
      rx_ov    <= 16'd0;
      rx_bit   <= 3'd0;
      rx_sh    <= 8'h00;
      rx_byte  <= 8'h00;
      rx_valid <= 1'b0;
      rx_ferr  <= 1'b0;
    end else begin
      rxd_a    <= uart_rxd;
      rxd_b    <= rxd_a;
      rx_valid <= 1'b0;
      rx_ferr  <= 1'b0;
      case (rx_state)
        R_IDLE: begin
          rx_ov  <= 16'd0;
          rx_bit <= 3'd0;
          if (!rxd_s)
            rx_state <= R_HALF; // possible start bit
        end
        R_HALF: begin
          // Wait half a bit (8/16 of the oversample ticks), then confirm.
          if (rx_ov == (8 * OV_DIV - 1)) begin
            rx_ov <= 16'd0;
            if (!rxd_s)
              rx_state <= R_DATA; // genuine start, sample mid-bit onwards
            else
              rx_state <= R_IDLE; // glitch, false start
          end else begin
            rx_ov <= rx_ov + 16'd1;
          end
        end
        R_DATA: begin
          if (rx_ov == (16 * OV_DIV - 1)) begin
            rx_ov        <= 16'd0;
            rx_sh[rx_bit] <= rxd_s; // middle sample of this bit
            if (rx_bit == 3'd7)
              rx_state <= R_STOP;
            else
              rx_bit <= rx_bit + 3'd1;
          end else begin
            rx_ov <= rx_ov + 16'd1;
          end
        end
        R_STOP: begin
          if (rx_ov == (16 * OV_DIV - 1)) begin
            rx_ov    <= 16'd0;
            rx_state <= R_IDLE;
            if (rxd_s) begin
              rx_byte  <= rx_sh; // valid byte (stop bit OK)
              rx_valid <= 1'b1;
            end else begin
              rx_ferr <= 1'b1;   // framing error: drop, resync on next start
            end
          end else begin
            rx_ov <= rx_ov + 16'd1;
          end
        end
        default: rx_state <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- TX ---
  // Byte-serial transmitter: protocol block loads txbuf[0..7] and pulses
  // tx_start; this block shifts start + 8 data (LSB first) + stop per byte
  // and pulses tx_done after the 8th stop bit. Line idles high.
  reg        uart_txd_r;
  assign uart_txd = uart_txd_r;

  localparam [2:0] T_IDLE  = 3'd0;
  localparam [2:0] T_START = 3'd1;
  localparam [2:0] T_DATA  = 3'd2;
  localparam [2:0] T_STOP  = 3'd3;
  localparam [2:0] T_NEXT  = 3'd4;
  localparam [2:0] T_DONE  = 3'd5;

  reg [7:0] txbuf [0:7];   // loaded by the protocol block (8 RSP bytes)
  reg       tx_start;      // 1-cycle pulse from protocol block
  reg       tx_done;       // 1-cycle pulse to protocol block
  reg [2:0] tx_state;
  reg [3:0] tx_idx;        // byte index 0..7
  reg [2:0] tx_bit;        // bit index 0..7
  reg [7:0] tx_cur;
  reg [31:0] tx_cnt;       // bit-period counter (wide: BIT_DIV up to 434+)

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      uart_txd_r <= 1'b1;
      tx_done    <= 1'b0;
      tx_state   <= T_IDLE;
      tx_idx     <= 3'd0;
      tx_bit     <= 3'd0;
      tx_cur     <= 8'h00;
      tx_cnt     <= 32'd0;
    end else begin
      tx_done <= 1'b0;
      case (tx_state)
        T_IDLE: begin
          uart_txd_r <= 1'b1;
          tx_cnt     <= 32'd0;
          if (tx_start) begin
            tx_idx   <= 3'd0;
            tx_cur   <= txbuf[0];
            tx_state <= T_START;
          end
        end
        T_START: begin
          uart_txd_r <= 1'b0; // start bit
          if (tx_cnt == BIT_DIV - 1) begin
            tx_cnt   <= 32'd0;
            tx_bit   <= 3'd0;
            tx_state <= T_DATA;
          end else begin
            tx_cnt <= tx_cnt + 32'd1;
          end
        end
        T_DATA: begin
          uart_txd_r <= tx_cur[0];
          if (tx_cnt == BIT_DIV - 1) begin
            tx_cnt <= 32'd0;
            tx_cur <= {1'b0, tx_cur[7:1]};
            if (tx_bit == 3'd7)
              tx_state <= T_STOP;
            else
              tx_bit <= tx_bit + 3'd1;
          end else begin
            tx_cnt <= tx_cnt + 32'd1;
          end
        end
        T_STOP: begin
          uart_txd_r <= 1'b1; // stop bit
          if (tx_cnt == BIT_DIV - 1) begin
            tx_cnt   <= 32'd0;
            tx_state <= T_NEXT;
          end else begin
            tx_cnt <= tx_cnt + 32'd1;
          end
        end
        T_NEXT: begin
          if (tx_idx == 4'd7) begin
            tx_state <= T_DONE;
          end else begin
            tx_idx   <= tx_idx + 4'd1;
            tx_cur   <= txbuf[tx_idx + 4'd1];
            tx_state <= T_START;
          end
        end
        T_DONE: begin
          tx_done  <= 1'b1;
          tx_state <= T_IDLE;
        end
        default: tx_state <= T_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------- PROTOCOL ---
  // Collects 9-byte CMD frames, validates (magic + checksum + known CMD),
  // executes one Avalon transaction, loads the 7-byte RSP, transmits it.
  localparam [3:0] E_RX       = 4'd0;
  localparam [3:0] E_WR       = 4'd1; // assert avs_write this cycle
  localparam [3:0] E_WR_END   = 4'd2; // release write, load ACK, start TX
  localparam [3:0] E_RD       = 4'd3; // assert avs_read this cycle
  localparam [3:0] E_RD_CAP   = 4'd4; // capture readdata, load RSP, start TX
  localparam [3:0] E_RST      = 4'd5; // assert reset pulse this cycle
  localparam [3:0] E_RST_GAP  = 4'd6; // release reset, settle
  localparam [3:0] E_RST_RD   = 4'd7; // read RESET_CNT
  localparam [3:0] E_RST_CAP  = 4'd8; // capture count, load RSP, start TX
  localparam [3:0] E_PING     = 4'd9; // load PONG, start TX
  localparam [3:0] E_TXWAIT   = 4'd10;

  reg [3:0]  p_state;
  reg [7:0]  fbuf [0:8];    // CMD frame bytes
  reg [3:0]  fidx;          // next fill position 0..8
  reg [7:0]  p_cmd, p_addr;
  reg [31:0] p_data;        // CMD DATA payload
  reg [7:0]  rsp_code;
  reg [31:0] rsp_data;
  // Blocking temps (module scope, Verilog-2001): response checksum byte.
  reg [7:0] chk_b;

  reg [11:0] avr_address_r;
  reg [31:0] avr_writedata_r;
  reg        avr_read_r;
  reg        avr_write_r;
  reg        avr_reset_r;

  assign avr_address    = avr_address_r;
  assign avr_writedata  = avr_writedata_r;
  assign avr_read       = avr_read_r;
  assign avr_write      = avr_write_r;
  assign avr_byteenable = 4'hF; // full-word accesses only
  assign avr_reset_o    = avr_reset_r;

  // Blocking-validated frame checksum temp (module scope, Verilog-2001).
  reg [11:0] chk_tmp;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      p_state        <= E_RX;
      fidx           <= 4'd0;
      p_cmd          <= 8'h00;
      p_addr         <= 8'h00;
      p_data         <= 32'h00000000;
      rsp_code       <= 8'h00;
      rsp_data       <= 32'h00000000;
      avr_address_r  <= 12'h000;
      avr_writedata_r <= 32'h00000000;
      avr_read_r     <= 1'b0;
      avr_write_r    <= 1'b0;
      avr_reset_r    <= 1'b0;
      tx_start       <= 1'b0;
    end else begin
      tx_start <= 1'b0; // default: single-cycle pulse only where set
      case (p_state)
        E_RX: begin
          if (rx_ferr) begin
            fidx <= 4'd0; // framing error: drop partial frame, resync
          end else if (rx_valid) begin
            if (fidx == 4'd8) begin
              // 9th byte arrives in rx_byte; bytes 0..7 are in fbuf.
              // Blocking checksum over CMD+ADDR+D0..D3; valid iff it
              // EQUALS the received CHK byte (CHK is the payload sum,
              // not a two's-complement residue).
              chk_tmp = fbuf[2] + fbuf[3] + fbuf[4] + fbuf[5]
                      + fbuf[6] + fbuf[7];
              fidx <= 4'd0;
              if (fbuf[0] == MAGIC0 && fbuf[1] == MAGIC1
                  && chk_tmp[7:0] == rx_byte
                  && (fbuf[2] == CMD_WRITE || fbuf[2] == CMD_READ
                      || fbuf[2] == CMD_RESET || fbuf[2] == CMD_PING)) begin
                p_cmd  <= fbuf[2];
                p_addr <= fbuf[3];
                p_data <= {fbuf[7], fbuf[6], fbuf[5], fbuf[4]};
                if (fbuf[2] == CMD_WRITE) begin
                  avr_address_r   <= {4'h0, fbuf[3]};
                  avr_writedata_r <= {fbuf[7], fbuf[6], fbuf[5], fbuf[4]};
                  p_state <= E_WR;
                end else if (fbuf[2] == CMD_READ) begin
                  avr_address_r <= {4'h0, fbuf[3]};
                  p_state <= E_RD;
                end else if (fbuf[2] == CMD_RESET) begin
                  p_state <= E_RST;
                end else begin
                  p_state <= E_PING;
                end
              end
              // else: malformed (bad magic/checksum/CMD) -> silent drop.
            end else begin
              fbuf[fidx] <= rx_byte;
              fidx <= fidx + 4'd1;
            end
          end
        end
        E_WR: begin
          avr_write_r <= 1'b1;
          p_state     <= E_WR_END;
        end
        E_WR_END: begin
          avr_write_r <= 1'b0;
          rsp_code <= RSP_WRITE;
          rsp_data <= p_data; // echo written value
          txbuf[0] <= MAGIC0;
          txbuf[1] <= MAGIC1;
          txbuf[2] <= RSP_WRITE;
          txbuf[3] <= p_data[7:0];
          txbuf[4] <= p_data[15:8];
          txbuf[5] <= p_data[23:16];
          txbuf[6] <= p_data[31:24];
          // Blocking checksum over the NEW payload (nonblocking txbuf/rsp
          // registers still hold stale values this cycle).
          chk_b = RSP_WRITE + p_data[7:0] + p_data[15:8]
                + p_data[23:16] + p_data[31:24];
          txbuf[7] <= chk_b;
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_RD: begin
          avr_read_r <= 1'b1;
          p_state    <= E_RD_CAP;
        end
        E_RD_CAP: begin
          avr_read_r <= 1'b0;
          rsp_code <= RSP_READ;
          rsp_data <= avr_readdata; // DUT read mux is combinational
          txbuf[0] <= MAGIC0;
          txbuf[1] <= MAGIC1;
          txbuf[2] <= RSP_READ;
          txbuf[3] <= avr_readdata[7:0];
          txbuf[4] <= avr_readdata[15:8];
          txbuf[5] <= avr_readdata[23:16];
          txbuf[6] <= avr_readdata[31:24];
          chk_b = RSP_READ + avr_readdata[7:0] + avr_readdata[15:8]
                + avr_readdata[23:16] + avr_readdata[31:24];
          txbuf[7] <= chk_b;
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_RST: begin
          avr_reset_r <= 1'b1; // 1-cycle soft-reset pulse
          p_state     <= E_RST_GAP;
        end
        E_RST_GAP: begin
          avr_reset_r   <= 1'b0;
          avr_address_r <= {4'h0, A_RSTCNT};
          p_state       <= E_RST_RD;
        end
        E_RST_RD: begin
          avr_read_r <= 1'b1;
          p_state    <= E_RST_CAP;
        end
        E_RST_CAP: begin
          avr_read_r <= 1'b0;
          rsp_code <= RSP_RESET;
          rsp_data <= avr_readdata;
          txbuf[0] <= MAGIC0;
          txbuf[1] <= MAGIC1;
          txbuf[2] <= RSP_RESET;
          txbuf[3] <= avr_readdata[7:0];
          txbuf[4] <= avr_readdata[15:8];
          txbuf[5] <= avr_readdata[23:16];
          txbuf[6] <= avr_readdata[31:24];
          chk_b = RSP_RESET + avr_readdata[7:0] + avr_readdata[15:8]
                + avr_readdata[23:16] + avr_readdata[31:24];
          txbuf[7] <= chk_b;
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_PING: begin
          rsp_code <= RSP_PING;
          rsp_data <= VERSION_VAL;
          txbuf[0] <= MAGIC0;
          txbuf[1] <= MAGIC1;
          txbuf[2] <= RSP_PING;
          txbuf[3] <= VERSION_VAL[7:0];
          txbuf[4] <= VERSION_VAL[15:8];
          txbuf[5] <= VERSION_VAL[23:16];
          txbuf[6] <= VERSION_VAL[31:24];
          chk_b = RSP_PING + VERSION_VAL[7:0] + VERSION_VAL[15:8]
                + VERSION_VAL[23:16] + VERSION_VAL[31:24];
          txbuf[7] <= chk_b;
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_TXWAIT: begin
          if (tx_done)
            p_state <= E_RX;
          // Stray bytes arriving mid-response are dropped (fidx stays 0).
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        default: p_state <= E_RX;
      endcase
    end
  end

endmodule
