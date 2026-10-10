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
//     CLK_HZ=50000000 default below. Baud rate is EXACT on average
//     (Bresenham phase accumulators for the TX bit clock and the RX 16x
//     ticks -- see the Baud timing note at the RX section): at 50 MHz /
//     115200 the TX emits 434/435-cycle bits (avg 434.0278) and the RX
//     ticks every ~27.13 cycles, i.e. within a fraction of a cycle of the
//     old flat 434/27 dividers. A non-divisible CLK_HZ such as the
//     25.175 MHz HDMI pixel clock (avg 218.53, RX tick ~13.66 -- where the
//     flat 218/13 truncation would drift 36 % of a bit across a byte)
//     stays exact the same way.
//   Divided-clock note (2026-09-25): dut_top_uart ran the fabric at
//   25 MHz for a while (toggle-FF divider, then BUFG); that experiment
//   is REVERTED -- the fabric is the 50 MHz board clock again, so the
//   divisor above (434/27) is the live operating point, verified in
//   sim at hardware baud (see dut_uart_tb.sv).
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
//          0x84 PONG (DATA = VERSION 0x00000001)
//   BURST frame (host -> FPGA), variable 5+16*N bytes, N = COUNT (1..64):
//     [0] MAGIC0  [1] MAGIC1  [2] CMD_BURST_SUBMIT = 0x05  [3] COUNT
//     [4..4+16*N-1] N entries, 16 bytes each, all words little-endian:
//       per entry: REQ_LO[0..3] DESC0[0..3] DESC1[0..3] DESC_CRC[0..3]
//       (same LE byte order and same CRC input tuple {EPOCH,REQ_LO,
//       DESC1,DESC0} as the single-submit register path; REQ_HI is
//       implicitly 0, written by the bridge per entry)
//     [4+16*N] CHK = (CMD + COUNT + all 16*N entry bytes) mod 256
//   BURST-RSP frame (FPGA -> host), variable 13+N bytes:
//     [0] MAGIC0  [1] MAGIC1  [2] RSP_BURST = 0x85  [3] COUNT (= N)
//     [4..4+N-1] per-entry result bytes R0..R{N-1}:
//       bit0 COMMITTED (1 = entry committed, durable advanced)
//       bit1 REJECT (= ~COMMITTED)
//       bits[4:2] CODE: 0 none  1 CRC_ERR  2 DUP_SEQ  3 GAP_SEQ
//                       4 MALFORMED  5 OVERFLOW (6..7 reserved)
//       bits[7:5] reserved 0
//     [4+N..7+N] DURABLE_LO (LE)  [8+N..11+N] DURABLE_HI (LE)
//     [12+N] CHK = (RSP + COUNT + R0..R{N-1} + 8 watermark bytes) mod 256
//   Burst execution: the bridge buffers the whole frame, validates the
//   checksum FIRST, then feeds entries internally one per DUT commit
//   (EPOCH/REQ_LO/REQ_HI/DESC0/DESC1/DESC_CRC + CTRL.SUBMIT per entry,
//   EPOCH pinned to its frame-start value for all N). Each entry is
//   validated against the LIVE durable count at feed time, so a mid-burst
//   reject does NOT cascade: the code is recorded, sticky ERROR bits
//   from the entry are cleared, and the rest CONTINUE (never stall).
//   Pre-existing sticky ERROR bits (set before the burst) are preserved,
//   never cleared by the burst engine.
//   Malformed frames (bad magic, bad checksum, unknown CMD) are dropped
//   SILENTLY with no response. The host speaks strict request-response:
//   exactly one RSP per well-formed CMD; no bytes are sent while busy.
//
// Avalon bridge: single-cycle writes; reads complete 2 cycles after
// the request (DUT avs_readdata is registered -- E_RD/E_RST_RD assert
// avr_read, one WAIT state, then E_RD_CAP/E_RST_CAP sample the word).
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
  input  [31:0] avr_readdata,  // DUT read data (registered, 2-cycle)
  output        avr_read,
  output        avr_write,
  output [3:0]  avr_byteenable,
  output        avr_reset_o,    // 1-cycle soft-reset pulse -> DUT fsm_reset_i
  // Display-poller share hint (added 2026-10-10 for dut_hdmi_top; purely
  // observational, behavior-preserving -- no existing path reads it):
  // 1 whenever the protocol engine may stage or assert a bus cycle, i.e.
  // the bus is NOT safely borrowable: any non-idle protocol state, any
  // collected frame byte, any RX in progress (a byte completing mid-borrow
  // would stage + assert on the next cycles), or any TX in progress.
  // A sharing poller must borrow only while this is 0 (plus its own
  // address-stability check), so same-address consecutive bridge reads --
  // which stage with no visible address change -- can never collide.
  output        avr_busy_o
);

  // Protocol constants.
  localparam [7:0] MAGIC0     = 8'h44; // 'D'
  localparam [7:0] MAGIC1     = 8'h55; // 'U'
  localparam [7:0] CMD_WRITE  = 8'h01;
  localparam [7:0] CMD_READ   = 8'h02;
  localparam [7:0] CMD_RESET  = 8'h03;
  localparam [7:0] CMD_PING   = 8'h04;
  // CMD_BURST_SUBMIT = 0x05: next free CMD value (0x01..0x04 taken), so
  // all existing single-submit frames keep working byte-identically; the
  // RSP keeps the CMD|0x80 convention (0x05|0x80 = 0x85). 0x06+ reserved.
  localparam [7:0] CMD_BURST  = 8'h05;
  localparam [7:0] RSP_WRITE  = 8'h81;
  localparam [7:0] RSP_READ   = 8'h82;
  localparam [7:0] RSP_RESET  = 8'h83;
  localparam [7:0] RSP_PING   = 8'h84;
  localparam [7:0] RSP_BURST  = 8'h85;
  localparam [7:0] A_RSTCNT   = 8'h20; // RESET_CNT byte offset (response data)
  localparam [31:0] VERSION_VAL = 32'h00000001; // matches DUT A_VERSION

  // Baud timing: phase accumulators give the EXACT average bit rate
  // (Bresenham): TX advances BAUD per cycle and emits a bit-time tick each
  // crossing of CLK_HZ (average exactly CLK_HZ/BAUD cycles/bit); RX advances
  // 16*BAUD per cycle for the 16x oversample ticks. At the legacy 50 MHz /
  // 115200 operating point this ticks 434/435 (TX) and ~27.13 (RX) cycles --
  // within a fraction of a cycle of the old flat dividers, so all existing
  // behavior and suites are preserved -- while a non-divisible operating
  // point such as the 25.175 MHz HDMI pixel clock (avg 218.53, where the
  // flat 218/13 truncation would drift 36 % of a bit across a byte) stays
  // exact. TB drivers use flat nominal bit times; margins are enormous.
  // (Regs + tick wires up here: icarus requires declare-before-use.)
  reg [31:0] rx_phase;         // 16x-tick accumulator (exact avg rate)
  reg [31:0] tx_phase;         // bit-time accumulator (exact avg rate)
  wire [31:0] tx_phase_next = tx_phase + BAUD;
  wire        tx_tick = (tx_phase_next >= CLK_HZ);
  wire [31:0] rx_phase_next = rx_phase + 16 * BAUD;
  wire        rx_tick = (rx_phase_next >= CLK_HZ);

  // Protocol (all multi-byte values little-endian, byte0 = bits[7:0]):

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
  reg [15:0] rx_tickn;            // oversample TICKS within the bit (0..15)
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
      rx_phase <= 32'd0;
      rx_tickn <= 16'd0;
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
          rx_phase <= 32'd0;
          rx_tickn <= 16'd0;
          rx_bit   <= 3'd0;
          if (!rxd_s)
            rx_state <= R_HALF; // possible start bit
        end
        R_HALF: begin
          // 8 oversample ticks ~= half a bit, then confirm the start.
          rx_phase <= rx_tick ? rx_phase_next - CLK_HZ : rx_phase_next;
          if (rx_tick) begin
            if (rx_tickn == 16'd7) begin
              rx_tickn <= 16'd0;
              if (!rxd_s)
                rx_state <= R_DATA; // genuine start, sample mid-bit onwards
              else
                rx_state <= R_IDLE; // glitch, false start
            end else begin
              rx_tickn <= rx_tickn + 16'd1;
            end
          end
        end
        R_DATA: begin
          // 16 oversample ticks per bit, middle-sampled.
          rx_phase <= rx_tick ? rx_phase_next - CLK_HZ : rx_phase_next;
          if (rx_tick) begin
            if (rx_tickn == 16'd15) begin
              rx_tickn       <= 16'd0;
              rx_sh[rx_bit] <= rxd_s; // middle sample of this bit
              if (rx_bit == 3'd7)
                rx_state <= R_STOP;
              else
                rx_bit <= rx_bit + 3'd1;
            end else begin
              rx_tickn <= rx_tickn + 16'd1;
            end
          end
        end
        R_STOP: begin
          rx_phase <= rx_tick ? rx_phase_next - CLK_HZ : rx_phase_next;
          if (rx_tick) begin
            if (rx_tickn == 16'd15) begin
              rx_tickn <= 16'd0;
              rx_state <= R_IDLE;
              if (rxd_s) begin
                rx_byte  <= rx_sh; // valid byte (stop bit OK)
                rx_valid <= 1'b1;
              end else begin
                rx_ferr <= 1'b1;   // framing error: drop, resync on next start
              end
            end else begin
              rx_tickn <= rx_tickn + 16'd1;
            end
          end
        end
        default: rx_state <= R_IDLE;
      endcase
    end
  end

  // ---------------------------------------------------------------- TX ---
  // Byte-serial transmitter: protocol block loads txbuf[0..tx_len-1] and
  // pulses tx_start; this block shifts start + 8 data (LSB first) + stop
  // per byte and pulses tx_done after the last stop bit. Line idles high.
  // txbuf holds up to 80 bytes: 8-byte legacy RSPs + 77-byte max
  // BURST-RSP (13 + 64 results).
  reg        uart_txd_r;
  assign uart_txd = uart_txd_r;

  localparam [2:0] T_IDLE  = 3'd0;
  localparam [2:0] T_START = 3'd1;
  localparam [2:0] T_DATA  = 3'd2;
  localparam [2:0] T_STOP  = 3'd3;
  localparam [2:0] T_NEXT  = 3'd4;
  localparam [2:0] T_DONE  = 3'd5;

  // TX engine state only. tx_len/txbuf/tx_start are owned SOLELY by the
  // protocol FSM below (reset + all updates there); this block reads them.
  reg [7:0] txbuf [0:79]; // loaded by the protocol block (RSP bytes)
  reg       tx_start;      // 1-cycle pulse from protocol block
  reg       tx_done;       // 1-cycle pulse to protocol block
  reg [6:0] tx_len;        // RSP length in bytes (8 legacy, 13+N burst)
  reg [2:0] tx_state;
  reg [6:0] tx_idx;        // byte index 0..tx_len-1
  reg [2:0] tx_bit;        // bit index 0..7
  reg [7:0] tx_cur;

  always @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      uart_txd_r <= 1'b1;
      tx_done    <= 1'b0;
      tx_state   <= T_IDLE;
      // NOTE: tx_len reset lives in the protocol FSM (sole driver).
      tx_idx     <= 7'd0;
      tx_bit     <= 3'd0;
      tx_cur     <= 8'h00;
      tx_phase   <= 32'd0;
    end else begin
      tx_done <= 1'b0;
      case (tx_state)
        T_IDLE: begin
          uart_txd_r <= 1'b1;
          tx_phase   <= 32'd0;
          if (tx_start) begin
            tx_idx   <= 7'd0;
            tx_cur   <= txbuf[0];
            tx_state <= T_START;
          end
        end
        T_START: begin
          uart_txd_r <= 1'b0; // start bit
          tx_phase <= tx_tick ? tx_phase_next - CLK_HZ : tx_phase_next;
          if (tx_tick) begin
            tx_bit   <= 3'd0;
            tx_state <= T_DATA;
          end
        end
        T_DATA: begin
          uart_txd_r <= tx_cur[0];
          tx_phase <= tx_tick ? tx_phase_next - CLK_HZ : tx_phase_next;
          if (tx_tick) begin
            tx_cur <= {1'b0, tx_cur[7:1]};
            if (tx_bit == 3'd7)
              tx_state <= T_STOP;
            else
              tx_bit <= tx_bit + 3'd1;
          end
        end
        T_STOP: begin
          uart_txd_r <= 1'b1; // stop bit
          tx_phase <= tx_tick ? tx_phase_next - CLK_HZ : tx_phase_next;
          if (tx_tick) begin
            tx_state <= T_NEXT;
          end
        end
        T_NEXT: begin
          if (tx_idx == tx_len - 7'd1) begin
            tx_state <= T_DONE;
          end else begin
            tx_idx   <= tx_idx + 7'd1;
            tx_cur   <= txbuf[tx_idx + 7'd1];
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
  // executes one Avalon transaction, loads the RSP, transmits it.
  // BURST frames (CMD 0x05) carry COUNT + N 16-byte entries; the whole
  // frame is buffered and checksum-validated BEFORE dispatch, then each
  // entry is fed through the same single-submit register sequence.
  localparam [4:0] E_RX       = 5'd0;
  localparam [4:0] E_WR       = 5'd1; // assert avs_write this cycle
  localparam [4:0] E_WR_END   = 5'd2; // release write, load ACK, start TX
  localparam [4:0] E_RD       = 5'd3; // assert avs_read this cycle
  localparam [4:0] E_RD_WAIT  = 5'd4; // hold read (DUT read latency 2)
  localparam [4:0] E_RD_CAP   = 5'd5; // capture readdata, load RSP, start TX
  localparam [4:0] E_RST      = 5'd6; // assert reset pulse this cycle
  localparam [4:0] E_RST_GAP  = 5'd7; // release reset, settle
  localparam [4:0] E_RST_RD   = 5'd8; // read RESET_CNT
  localparam [4:0] E_RST_WAIT = 5'd9; // hold read (DUT read latency 2)
  localparam [4:0] E_RST_CAP  = 5'd10; // capture count, load RSP, start TX
  localparam [4:0] E_PING     = 5'd11; // load PONG, start TX
  localparam [4:0] E_TXWAIT   = 5'd12;
  // Burst engine (CMD_BURST): buffer -> validate -> feed N entries.
  localparam [4:0] E_BST_RX     = 5'd13; // collect 16*N payload bytes + CHK
  localparam [4:0] E_BST_EP_RD  = 5'd14; // read EPOCH (latch for all N)
  localparam [4:0] E_BST_EP_WT  = 5'd15;
  localparam [4:0] E_BST_EP_CAP = 5'd16;
  localparam [4:0] E_BST_EB_RD  = 5'd17; // read ERROR base (pre-existing)
  localparam [4:0] E_BST_EB_WT  = 5'd18;
  localparam [4:0] E_BST_EB_CAP = 5'd19;
  localparam [4:0] E_BST_WR     = 5'd20; // per-entry writes (wr_ph 0..6)
  localparam [4:0] E_BST_WR_END = 5'd21;
  localparam [4:0] E_BST_WAIT   = 5'd22; // settle past the commit pipeline
  localparam [4:0] E_BST_ER_RD  = 5'd23; // sample ERROR for this entry
  localparam [4:0] E_BST_ER_WT  = 5'd24;
  localparam [4:0] E_BST_ER_CAP = 5'd25;
  localparam [4:0] E_BST_CLR    = 5'd26; // rw1c-clear entry errors
  localparam [4:0] E_BST_CLR_END = 5'd27; // release clear, stage DUR addr
  localparam [4:0] E_BST_D_RD   = 5'd28; // read DURABLE_LO/HI (d_phase)
  localparam [4:0] E_BST_D_WT   = 5'd29;
  localparam [4:0] E_BST_D_CAP  = 5'd30;
  localparam [4:0] E_BST_TX     = 5'd31; // load BURST-RSP, start TX

  // Burst register addresses (byte offsets in the DUT window).
  localparam [7:0] B_EPOCH   = 8'h00;
  localparam [7:0] B_REQ_LO  = 8'h04;
  localparam [7:0] B_DUR_LO  = 8'h0C;
  localparam [7:0] B_ERROR   = 8'h18;
  localparam [7:0] B_CTRL    = 8'h24;
  localparam [7:0] B_DESC0   = 8'h2C;
  localparam [7:0] B_DESC1   = 8'h30;
  localparam [7:0] B_DESC_CRC = 8'h34;
  localparam [7:0] B_REQ_HI  = 8'h44;
  localparam [7:0] B_DUR_HI  = 8'h48;

  reg [4:0]  p_state;
  reg [7:0]  fbuf [0:8];    // CMD frame bytes
  reg [3:0]  fidx;          // next fill position 0..8
  reg [7:0]  p_cmd, p_addr;
  reg [31:0] p_data;        // CMD DATA payload
  reg [7:0]  rsp_code;
  reg [31:0] rsp_data;
  // Burst engine registers.
  reg [7:0]  burst_buf [0:1023]; // entry payload (16 bytes x up to 64)
  reg [7:0]  burst_res [0:63];   // per-entry result bytes
  reg [6:0]  burst_n;            // COUNT 1..64
  reg [6:0]  burst_i;            // entry index under feed
  reg [10:0] burst_j;            // payload byte counter in E_BST_RX
  reg [7:0]  burst_acc;          // running frame checksum (mod 256)
  reg [7:0]  res_sum;            // running sum of result bytes (RSP CHK)
  reg [31:0] burst_ep;           // EPOCH latched at frame start
  reg [31:0] err_base;           // ERROR bits pre-existing the burst
  reg [31:0] clr_bits;           // this entry's new ERROR bits (to clear)
  reg [31:0] dur_lo, dur_hi;     // final watermark for the BURST-RSP
  reg [2:0]  wr_ph;              // per-entry write phase 0..6
  reg [4:0]  wait_cnt;           // commit-pipeline settle counter
  reg        d_phase;            // 0 = DURABLE_LO, 1 = DURABLE_HI
  integer    bi;                 // TX-fill loop index (E_BST_TX)
  // Blocking temps (module scope, Verilog-2001).
  reg [7:0] chk_b;
  reg [10:0] need_tmp;           // 16*N expected payload bytes
  reg [10:0] eb_tmp;             // byte base of entry burst_i
  reg [8:0]  acc_tmp;            // checksum accumulate (take [7:0])
  reg [31:0] nb_tmp;             // this entry's new ERROR bits
  reg [2:0]  code_tmp;           // reject CODE for bits[4:2]
  reg [7:0]  res_tmp;            // result byte under construction
  reg [7:0]  sum_tmp;            // BURST-RSP checksum accumulate
  reg [6:0]  di_tmp;             // txbuf index of DURABLE_LO byte 0

  // Baud timing: phase accumulators give the EXACT average bit rate
  // (Regs + tick wires live near the top: icarus needs declare-before-use.)

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
  assign avr_busy_o     = (p_state != E_RX) || (fidx != 4'd0)
                       || (rx_state != R_IDLE) || rx_valid || rx_ferr
                       || (tx_state != T_IDLE) || tx_start;

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
      burst_n        <= 7'd0;
      burst_i        <= 7'd0;
      burst_j        <= 11'd0;
      burst_acc      <= 8'h00;
      res_sum        <= 8'h00;
      burst_ep       <= 32'h00000000;
      err_base       <= 32'h00000000;
      clr_bits       <= 32'h00000000;
      dur_lo         <= 32'h00000000;
      dur_hi         <= 32'h00000000;
      wr_ph          <= 3'd0;
      wait_cnt       <= 5'd0;
      d_phase        <= 1'b0;
      avr_address_r  <= 12'h000;
      avr_writedata_r <= 32'h00000000;
      avr_read_r     <= 1'b0;
      avr_write_r    <= 1'b0;
      avr_reset_r    <= 1'b0;
      tx_start       <= 1'b0;
      tx_len         <= 7'd8; // sole driver: legacy idle length
    end else begin
      tx_start <= 1'b0; // default: single-cycle pulse only where set
      case (p_state)
        E_RX: begin
          if (rx_ferr) begin
            fidx <= 4'd0; // framing error: drop partial frame, resync
          end else if (rx_valid) begin
            if (fidx == 4'd3 && fbuf[0] == MAGIC0 && fbuf[1] == MAGIC1
                && fbuf[2] == CMD_BURST) begin
              // 4th byte of a burst frame is COUNT (1..64). Anything
              // else (bad magic handled below, COUNT 0 or >64) is a
              // malformed frame: silent drop, no response.
              if (rx_byte >= 8'd1 && rx_byte <= 8'd64) begin
                burst_n   <= rx_byte[6:0];
                burst_j   <= 11'd0;
                burst_acc <= CMD_BURST + rx_byte; // running CHK seed
                fidx      <= 4'd0;
                p_state   <= E_BST_RX;
              end else begin
                fidx <= 4'd0; // bad COUNT: drop, resync on next magic
              end
            end else if (fidx == 4'd8) begin
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
          tx_len <= 7'd8; // legacy 8-byte RSP
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_RD: begin
          avr_read_r <= 1'b1;
          p_state    <= E_RD_WAIT;
        end
        E_RD_WAIT: begin
          // DUT read latency is 2 cycles: hold the request one more
          // cycle so E_RD_CAP samples the registered word.
          p_state <= E_RD_CAP;
        end
        E_RD_CAP: begin
          avr_read_r <= 1'b0;
          rsp_code <= RSP_READ;
          rsp_data <= avr_readdata; // DUT read data (registered)
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
          tx_len <= 7'd8; // legacy 8-byte RSP
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
          p_state    <= E_RST_WAIT;
        end
        E_RST_WAIT: begin
          // DUT read latency is 2 cycles: hold the request one more
          // cycle so E_RST_CAP samples the registered word.
          p_state <= E_RST_CAP;
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
          tx_len <= 7'd8; // legacy 8-byte RSP
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
          tx_len <= 7'd8; // legacy 8-byte RSP
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
        end
        E_BST_RX: begin
          // Collect 16*N entry bytes + trailing CHK into burst_buf.
          // The checksum is accumulated incrementally (mod 256); only a
          // fully-validated frame dispatches (no partial commit on CHK
          // failure -- E_TXWAIT hardware reality: no streaming output).
          if (rx_ferr) begin
            fidx    <= 4'd0;
            p_state <= E_RX; // framing error: drop, resync
          end else if (rx_valid) begin
            need_tmp = {burst_n, 4'b0000}; // 16*N payload bytes
            if (burst_j == need_tmp) begin
              // Trailing CHK byte: valid iff it equals the payload sum.
              fidx <= 4'd0;
              if (burst_acc == rx_byte) begin
                burst_i <= 7'd0;
                res_sum <= 8'h00;
                // Stage the EPOCH address a full cycle before the read
                // asserts (same convention as the legacy E_RX -> E_RD
                // handoff: the DUT samples address+read together, so the
                // address must already be stable).
                avr_address_r <= {4'h0, B_EPOCH};
                p_state <= E_BST_EP_RD; // dispatch: latch EPOCH first
              end else begin
                p_state <= E_RX; // bad checksum: silent drop, no response
              end
            end else begin
              burst_buf[burst_j] <= rx_byte;
              acc_tmp = {1'b0, burst_acc} + {1'b0, rx_byte};
              burst_acc <= acc_tmp[7:0];
              burst_j   <= burst_j + 11'd1;
            end
          end
        end
        E_BST_EP_RD: begin
          // Address already staged in E_BST_RX; assert read only.
          avr_read_r    <= 1'b1;
          p_state       <= E_BST_EP_WT;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_EP_WT: begin
          // DUT read latency is 2 cycles: hold the request one more
          // cycle so E_BST_EP_CAP samples the registered word.
          p_state <= E_BST_EP_CAP;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_EP_CAP: begin
          avr_read_r <= 1'b0;
          burst_ep   <= avr_readdata; // latched at frame start, all N
          // Stage the ERROR address for the base read below.
          avr_address_r <= {4'h0, B_ERROR};
          p_state    <= E_BST_EB_RD;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_EB_RD: begin
          // Address already staged in E_BST_EP_CAP; assert read only.
          avr_read_r    <= 1'b1;
          p_state       <= E_BST_EB_WT;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_EB_WT: begin
          p_state <= E_BST_EB_CAP;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_EB_CAP: begin
          avr_read_r <= 1'b0;
          err_base   <= avr_readdata; // pre-existing stickies: preserved
          wr_ph      <= 3'd0;
          burst_i    <= 7'd0;
          p_state    <= E_BST_WR;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_WR: begin
          // One Avalon write per phase: EPOCH (pinned) / DESC0 / DESC1 /
          // REQ_LO / REQ_HI=0 / DESC_CRC / CTRL.SUBMIT -- the exact
          // single-submit register sequence, driven internally.
          eb_tmp = {burst_i, 4'b0000}; // byte base of entry burst_i
          case (wr_ph)
            3'd0: begin
              avr_address_r   <= {4'h0, B_EPOCH};
              avr_writedata_r <= burst_ep;
            end
            3'd1: begin
              avr_address_r   <= {4'h0, B_DESC0};
              avr_writedata_r <= {burst_buf[eb_tmp + 11'd7],
                                  burst_buf[eb_tmp + 11'd6],
                                  burst_buf[eb_tmp + 11'd5],
                                  burst_buf[eb_tmp + 11'd4]};
            end
            3'd2: begin
              avr_address_r   <= {4'h0, B_DESC1};
              avr_writedata_r <= {burst_buf[eb_tmp + 11'd11],
                                  burst_buf[eb_tmp + 11'd10],
                                  burst_buf[eb_tmp + 11'd9],
                                  burst_buf[eb_tmp + 11'd8]};
            end
            3'd3: begin
              avr_address_r   <= {4'h0, B_REQ_LO};
              avr_writedata_r <= {burst_buf[eb_tmp + 11'd3],
                                  burst_buf[eb_tmp + 11'd2],
                                  burst_buf[eb_tmp + 11'd1],
                                  burst_buf[eb_tmp]};
            end
            3'd4: begin
              avr_address_r   <= {4'h0, B_REQ_HI};
              avr_writedata_r <= 32'h00000000;
            end
            3'd5: begin
              avr_address_r   <= {4'h0, B_DESC_CRC};
              avr_writedata_r <= {burst_buf[eb_tmp + 11'd15],
                                  burst_buf[eb_tmp + 11'd14],
                                  burst_buf[eb_tmp + 11'd13],
                                  burst_buf[eb_tmp + 11'd12]};
            end
            default: begin
              avr_address_r   <= {4'h0, B_CTRL};
              avr_writedata_r <= 32'h00000001; // CTRL.SUBMIT
            end
          endcase
          avr_write_r <= 1'b1;
          p_state     <= E_BST_WR_END;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_WR_END: begin
          avr_write_r <= 1'b0;
          if (wr_ph == 3'd6) begin
            wait_cnt <= 5'd0;
            // Stage the ERROR address now so the post-settle sample
            // reads the settled word (legacy convention).
            avr_address_r <= {4'h0, B_ERROR};
            p_state  <= E_BST_WAIT;
          end else begin
            wr_ph   <= wr_ph + 3'd1;
            p_state <= E_BST_WR;
          end
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_WAIT: begin
          // Settle past the DUT commit pipeline (SUBMIT 1 + CRC 1 +
          // COMMIT hold <= 3 + COMPLETE 1; rejects return to IDLE even
          // faster). 16 cycles of margin; the next feed always finds
          // the DUT idle, so entries never collide (no MALFORMED from
          // submit-while-busy inside a burst).
          if (wait_cnt == 5'd16) begin
            // Address already staged in E_BST_WR_END; assert read only.
            avr_read_r    <= 1'b1;
            p_state       <= E_BST_ER_RD;
          end else begin
            wait_cnt <= wait_cnt + 5'd1;
          end
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_ER_RD: begin
          p_state <= E_BST_ER_WT;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_ER_WT: begin
          p_state <= E_BST_ER_CAP;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_ER_CAP: begin
          avr_read_r <= 1'b0;
          // New sticky bits from THIS entry only (pre-existing base
          // excluded). No new bits <=> the entry committed.
          nb_tmp = avr_readdata & ~err_base;
          clr_bits <= nb_tmp;
          if (nb_tmp == 32'h00000000) begin
            code_tmp = 3'd0;
          end else if (nb_tmp[0]) begin
            code_tmp = 3'd1; // CRC_ERR
          end else if (nb_tmp[1]) begin
            code_tmp = 3'd2; // DUP_SEQ
          end else if (nb_tmp[2]) begin
            code_tmp = 3'd3; // GAP_SEQ
          end else if (nb_tmp[3] || nb_tmp[4]) begin
            code_tmp = 3'd4; // MALFORMED (RSTMID unreachable: no reset
                             // is ever asserted mid-burst; mapped here)
          end else begin
            code_tmp = 3'd5; // OVERFLOW
          end
          // Blocking result byte (nonblocking regs still stale).
          // bit0 COMMITTED, bit1 REJECT, bits[4:2] CODE, bits[7:5] 0.
          if (nb_tmp == 32'h00000000)
            res_tmp = 8'h01;                    // COMMITTED, CODE 0
          else
            res_tmp = {3'b000, code_tmp, 2'b10}; // REJECT + CODE
          burst_res[burst_i] <= res_tmp;
          acc_tmp = {1'b0, res_sum} + {1'b0, res_tmp};
          res_sum <= acc_tmp[7:0];
          p_state <= E_BST_CLR;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_CLR: begin
          // rw1c-clear ONLY this entry's bits (pre-existing stickies
          // survive), then CONTINUE with the next entry -- never stall.
          // NOTE: the clear write and the next address stage cannot share
          // a cycle (one addr register), so the last entry exits through
          // E_BST_CLR_END, which releases the write AND stages DUR_LO.
          if (clr_bits != 32'h00000000) begin
            avr_address_r   <= {4'h0, B_ERROR};
            avr_writedata_r <= clr_bits;
            avr_write_r     <= 1'b1;
          end
          if (burst_i + 7'd1 == burst_n) begin
            p_state <= E_BST_CLR_END;
          end else begin
            burst_i <= burst_i + 7'd1;
            wr_ph   <= 3'd0;
            p_state <= E_BST_WR;
          end
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_CLR_END: begin
          avr_write_r   <= 1'b0; // release the clear write above
          d_phase       <= 1'b0;
          // Stage DURABLE_LO a full cycle before E_BST_D_RD asserts
          // its read (legacy convention).
          avr_address_r <= {4'h0, B_DUR_LO};
          p_state       <= E_BST_D_RD;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_D_RD: begin
          avr_write_r   <= 1'b0; // release a possible E_BST_CLR write
          // Address already staged (E_BST_CLR / E_BST_D_CAP); read only.
          avr_read_r    <= 1'b1;
          p_state       <= E_BST_D_WT;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_D_WT: begin
          p_state <= E_BST_D_CAP;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_D_CAP: begin
          avr_read_r <= 1'b0;
          if (d_phase == 1'b0) begin
            dur_lo  <= avr_readdata;
            d_phase <= 1'b1;
            // Stage DURABLE_HI for the second watermark read.
            avr_address_r <= {4'h0, B_DUR_HI};
            p_state <= E_BST_D_RD;
          end else begin
            dur_hi  <= avr_readdata;
            p_state <= E_BST_TX;
          end
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
        end
        E_BST_TX: begin
          rsp_code <= RSP_BURST;
          txbuf[0] <= MAGIC0;
          txbuf[1] <= MAGIC1;
          txbuf[2] <= RSP_BURST;
          txbuf[3] <= {1'b0, burst_n};
          for (bi = 0; bi < 64; bi = bi + 1) begin
            if (bi[6:0] < burst_n)
              txbuf[4 + bi] <= burst_res[bi[5:0]];
          end
          di_tmp = 7'd4 + burst_n; // DURABLE_LO byte 0 index
          txbuf[di_tmp]       <= dur_lo[7:0];
          txbuf[di_tmp + 7'd1] <= dur_lo[15:8];
          txbuf[di_tmp + 7'd2] <= dur_lo[23:16];
          txbuf[di_tmp + 7'd3] <= dur_lo[31:24];
          txbuf[di_tmp + 7'd4] <= dur_hi[7:0];
          txbuf[di_tmp + 7'd5] <= dur_hi[15:8];
          txbuf[di_tmp + 7'd6] <= dur_hi[23:16];
          txbuf[di_tmp + 7'd7] <= dur_hi[31:24];
          // Blocking checksum over the NEW payload (nonblocking
          // txbuf/dur regs still hold stale values this cycle).
          sum_tmp = RSP_BURST + {1'b0, burst_n} + res_sum
                  + dur_lo[7:0] + dur_lo[15:8]
                  + dur_lo[23:16] + dur_lo[31:24]
                  + dur_hi[7:0] + dur_hi[15:8]
                  + dur_hi[23:16] + dur_hi[31:24];
          txbuf[di_tmp + 7'd8] <= sum_tmp;
          tx_len   <= 7'd13 + burst_n; // 13 + N bytes total
          tx_start <= 1'b1;
          p_state  <= E_TXWAIT;
          if (rx_valid || rx_ferr)
            fidx <= 4'd0;
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
