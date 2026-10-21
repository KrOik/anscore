// CRC-32 (IEEE 802.3): reflected poly 0xEDB88320, init/xorout 0xFFFFFFFF.
// Each accepted beat consumes s_tdata LSB-first; DATA_WIDTH=16 matches
// zlib.crc32 over little-endian byte pairs, DATA_WIDTH=8 one byte per beat.
// init reseeds to INIT; a same-edge beat folds into the fresh seed.
// An accepted s_tlast beat latches result (with xorout), pulses done and
// auto-reseeds, so framed streams can be checked back to back.
module crc32 #(parameter integer DATA_WIDTH=16) (
  input wire clk, rst_n,
  input wire init,
  input wire [DATA_WIDTH-1:0] s_tdata,
  input wire s_tvalid, output wire s_tready,
  input wire s_tlast,
  output reg [31:0] state,
  output reg [31:0] result,
  output reg done
);
  assign s_tready = rst_n;
  wire accept = rst_n && s_tvalid && s_tready;

  function [31:0] step(input [31:0] c, input [DATA_WIDTH-1:0] d);
    integer i; reg [31:0] t;
    begin
      t = c;
      for (i = 0; i < DATA_WIDTH; i = i + 1)
        t = (t[0] ^ d[i]) ? ((t >> 1) ^ 32'hEDB88320) : (t >> 1);
      step = t;
    end
  endfunction

  wire [31:0] base = init ? 32'hFFFFFFFF : state;
  always @(posedge clk) begin
    if (!rst_n) begin
      state <= 32'hFFFFFFFF; result <= 32'd0; done <= 1'b0;
    end else begin
      done <= 1'b0;
      if (accept) begin
        state <= s_tlast ? 32'hFFFFFFFF : step(base, s_tdata);
        if (s_tlast) begin
          result <= step(base, s_tdata) ^ 32'hFFFFFFFF;
          done <= 1'b1;
        end
      end else if (init) begin
        state <= 32'hFFFFFFFF;
      end
    end
  end
`ifndef SYNTHESIS
  initial if (DATA_WIDTH < 1 || DATA_WIDTH > 64) $fatal(1, "unsupported DATA_WIDTH");
`endif
endmodule
