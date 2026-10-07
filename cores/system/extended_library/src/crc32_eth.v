// ============================================================================
// crc32_eth -- wave2 idx32 "CRC": streaming CRC engine.
//
// Two modes, selected by `mode` (sampled with each init/dv beat):
//   mode=0: CRC-32 / IEEE 802.3 (Ethernet FCS)
//           poly 0xEDB88320 (reflected), init 0xFFFFFFFF,
//           final XOR 0xFFFFFFFF.  Check: "123456789" -> 0xCBF43926.
//   mode=1: CRC-16/CCITT-FALSE
//           poly 0x1021 (MSB-first), init 0xFFFF, no reflection,
//           final XOR 0x0000.  Check: "123456789" -> 0x29B1.
//
// init=1 for one clk_en beat loads the init value; each dv beat consumes
// one byte.  crc_out is the current residue with the final XOR applied
// (combinational read of state; valid one beat after the last dv).
//
// All registers clk_en gated (T2).  Byte update is an 8-deep XOR tree.
// ============================================================================
module crc32_eth (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        mode,
    input  wire        init,
    input  wire        dv,
    input  wire [7:0]  din,
    output reg  [31:0] state,
    output wire [31:0] crc_out
);

function [31:0] crc32_step;
    input [31:0] c;
    input [7:0]  d;
    reg [31:0] x;
    integer k;
    begin
        x = c ^ {24'b0, d};
        for (k = 0; k < 8; k = k + 1)
            x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
        crc32_step = x;
    end
endfunction

function [15:0] crc16_step;
    input [15:0] c;
    input [7:0]  d;
    reg [15:0] x;
    integer k;
    begin
        x = c ^ {d, 8'b0};
        for (k = 0; k < 8; k = k + 1)
            x = x[15] ? ((x << 1) ^ 16'h1021) : (x << 1);
        crc16_step = x;
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= 32'hFFFFFFFF;
    end else if (clk_en) begin
        if (init)
            state <= mode ? {16'b0, 16'hFFFF} : 32'hFFFFFFFF;
        else if (dv)
            state <= mode ? {16'b0, crc16_step(state[15:0], din)}
                          : crc32_step(state, din);
    end
end

assign crc_out = mode ? {16'b0, state[15:0]} : (state ^ 32'hFFFFFFFF);

endmodule
