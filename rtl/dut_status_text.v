// SPDX-License-Identifier: Apache-2.0
// rtl/dut_status_text.v -- 640x480 text-status renderer for the DUT.
//
// Pixel-domain, fully combinational: given the raster position (x,y) and the
// snapshotted DUT state, produces an RGB pixel. 80x60 cells of 8x8 pixels;
// status rows near the top, black elsewhere.
//
// Layout (text rows, columns; col = x[9:3], row = y[9:3]):
//   row  2: "DUT STATUS 640X480"            (title, amber)
//   row  4: "DURABLE  HHHHHHHH HHHHHHHH"     (durable count hi/lo)
//   row  5: "VISIBLE  HHHHHHHH HHHHHHHH"     (visible watermark hi/lo)
//   row  6: "ERROR    HHHHHHHH"              (sticky error bits)
//   row  7: "VERSION  HHHHHHHH"              (ABI version)
//   row  8: "BUSY b   TC t"                 (live busy, stretched TC pulse)
//
// Font: minimal hand-authored 8x8 glyphs (space, 0-9, A-Z) drawn for this
// repo -- no ROM blobs, no third-party font data, nothing to license-check.
// Glyph constant bit order: bits[63:56] = top row, bit7 of each byte = left
// pixel. Pixel on = glyph bit for (gy,gx).

`timescale 1ns / 1ps

module dut_status_text (
  input  [9:0] x,            // raster x (0..799); meaningful iff de
  input  [9:0] y,            // raster y (0..524); meaningful iff de
  input        de,            // display enable (visible area)
  input [63:0] durable,
  input [63:0] visible,
  input [31:0] error,
  input [31:0] version,
  input        busy,
  input        tc,            // stretched trusted-complete pulse
  output [7:0] r,
  output [7:0] g,
  output [7:0] b
);

  // Nibble -> ASCII hex.
  function [7:0] hexasc;
    input [3:0] n;
    begin
      hexasc = (n < 4'd10) ? (8'h30 + n) : (8'h41 + (n - 4'd10));
    end
  endfunction

  // Character at text cell (row, col); space default.
  function [7:0] row_char;
    input [5:0] row;
    input [6:0] col;
    reg [7:0] c;
    begin
      c = 8'h20; // space
      case (row)
        6'd2: begin // "DUT STATUS 640X480" at col 2
          case (col)
            7'd2:  c = "D"; 7'd3:  c = "U"; 7'd4:  c = "T";
            7'd5:  c = " "; 7'd6:  c = "S"; 7'd7:  c = "T";
            7'd8:  c = "A"; 7'd9:  c = "T"; 7'd10: c = "U";
            7'd11: c = "S"; 7'd12: c = " "; 7'd13: c = "6";
            7'd14: c = "4"; 7'd15: c = "0"; 7'd16: c = "X";
            7'd17: c = "4"; 7'd18: c = "8"; 7'd19: c = "0";
          endcase
        end
        6'd4: begin // "DURABLE  HHHHHHHH HHHHHHHH"
          case (col)
            7'd2:  c = "D"; 7'd3:  c = "U"; 7'd4:  c = "R";
            7'd5:  c = "A"; 7'd6:  c = "B"; 7'd7:  c = "L";
            7'd8:  c = "E";
            default: begin
              if (col >= 7'd11 && col <= 7'd18)
                c = hexasc(durable[63:32] >> ((7'd18 - col) * 4));
              else if (col >= 7'd20 && col <= 7'd27)
                c = hexasc(durable[31:0] >> ((7'd27 - col) * 4));
            end
          endcase
        end
        6'd5: begin // "VISIBLE  HHHHHHHH HHHHHHHH"
          case (col)
            7'd2:  c = "V"; 7'd3:  c = "I"; 7'd4:  c = "S";
            7'd5:  c = "I"; 7'd6:  c = "B"; 7'd7:  c = "L";
            7'd8:  c = "E";
            default: begin
              if (col >= 7'd11 && col <= 7'd18)
                c = hexasc(visible[63:32] >> ((7'd18 - col) * 4));
              else if (col >= 7'd20 && col <= 7'd27)
                c = hexasc(visible[31:0] >> ((7'd27 - col) * 4));
            end
          endcase
        end
        6'd6: begin // "ERROR    HHHHHHHH"
          case (col)
            7'd2:  c = "E"; 7'd3:  c = "R"; 7'd4:  c = "R";
            7'd5:  c = "O"; 7'd6:  c = "R";
            default: begin
              if (col >= 7'd11 && col <= 7'd18)
                c = hexasc(error >> ((7'd18 - col) * 4));
            end
          endcase
        end
        6'd7: begin // "VERSION  HHHHHHHH"
          case (col)
            7'd2:  c = "V"; 7'd3:  c = "E"; 7'd4:  c = "R";
            7'd5:  c = "S"; 7'd6:  c = "I"; 7'd7:  c = "O";
            7'd8:  c = "N";
            default: begin
              if (col >= 7'd11 && col <= 7'd18)
                c = hexasc(version >> ((7'd18 - col) * 4));
            end
          endcase
        end
        6'd8: begin // "BUSY b   TC t"
          case (col)
            7'd2:  c = "B"; 7'd3:  c = "U"; 7'd4:  c = "S";
            7'd5:  c = "Y"; 7'd8:  c = busy ? "1" : "0";
            7'd11: c = "T"; 7'd12: c = "C"; 7'd15: c = tc ? "1" : "0";
          endcase
        end
        default: c = 8'h20;
      endcase
      row_char = c;
    end
  endfunction

  // 8x8 glyph ROM (hand-drawn for this repo; see header). One 64-bit
  // constant per glyph: byte 7 (bits[63:56]) is the top row.
  function [63:0] glyph;
    input [7:0] ch;
    begin
      case (ch)
        "0": glyph = 64'h7c42424242427c00;
        "1": glyph = 64'h1030101010103800;
        "2": glyph = 64'h7c04047c40407c00;
        "3": glyph = 64'h7c04043c04047c00;
        "4": glyph = 64'h4444447c04040400;
        "5": glyph = 64'h7c40407c04047c00;
        "6": glyph = 64'h7c40407c44447c00;
        "7": glyph = 64'h7c04081020202000;
        "8": glyph = 64'h7c44447c44447c00;
        "9": glyph = 64'h7c44447c04047c00;
        "A": glyph = 64'h3844447c44444400;
        "B": glyph = 64'h7844447844447800;
        "C": glyph = 64'h7c40404040407c00;
        "D": glyph = 64'h7844424242447800;
        "E": glyph = 64'h7c40407840407c00;
        "F": glyph = 64'h7c40407840404000;
        "G": glyph = 64'h7c40404c44447c00;
        "H": glyph = 64'h4444447c44444400;
        "I": glyph = 64'h7c10101010107c00;
        "J": glyph = 64'h0c0c0c0c0c443800;
        "K": glyph = 64'h4448506050484400;
        "L": glyph = 64'h4040404040407c00;
        "M": glyph = 64'h446c7c5444444400;
        "N": glyph = 64'h446454544c444400;
        "O": glyph = 64'h7c42424242427c00;
        "P": glyph = 64'h7c44447c40404000;
        "Q": glyph = 64'h7c4242424c4c3e00;
        "R": glyph = 64'h7c44447848444400;
        "S": glyph = 64'h7c40407c04047c00;
        "T": glyph = 64'h7c10101010101000;
        "U": glyph = 64'h4444444444447c00;
        "V": glyph = 64'h444444446c381000;
        "W": glyph = 64'h444444547c6c4400;
        "X": glyph = 64'h4444281010284400;
        "Y": glyph = 64'h4444281010101000;
        "Z": glyph = 64'h7c04081020407c00;
        default: glyph = 64'h0000000000000000; // space + others blank
      endcase
    end
  endfunction

  wire [6:0] col = x[9:3];
  wire [5:0] row = y[9:3];
  wire [2:0] gx  = x[2:0];
  wire [2:0] gy  = y[2:0];
  wire [7:0] ch  = row_char(row, col);
  wire [63:0] g64 = glyph(ch);
  wire [7:0] grow = g64 >> ((3'd7 - gy) * 8);
  wire       on   = de & grow[3'd7 - gx];
  wire       title = (row == 6'd2);

  // Title amber (255,176,0); body white; background black.
  assign r = on ? 8'hFF : 8'h00;
  assign g = on ? (title ? 8'hB0 : 8'hFF) : 8'h00;
  assign b = on ? (title ? 8'h00 : 8'hFF) : 8'h00;

endmodule
