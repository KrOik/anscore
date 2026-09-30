// ============================================================================
// crc_core : byte-serial CRC engine, runtime-selectable polynomial set.
//
//   mode[1:0] = 0 : CRC-8/SMBUS        poly 0x07       init 0x00
//               1 : CRC-16/CCITT-FALSE poly 0x1021     init 0xFFFF
//               2 : CRC-32/ISO-HDLC    poly 0x04C11DB7 init 0xFFFFFFFF
//                                        (reflected in/out, xorout 0xFFFFFFFF,
//                                         == zlib/binascii.crc32 semantics)
//
// Protocol (clk_en-gated, active-low async reset):
//   pulse init (1 clk_en beat) with mode stable -> feed bytes on din with
//   din_valid=1 (one byte per beat) -> crc_out holds the running residue
//   (xorout already applied). After the last byte beat, crc_out is the
//   final CRC; upper bits are 0 for modes 0/1.
//
// One byte per clk_en beat (8-bit parallel update). No DSP, no BSRAM.
// ============================================================================
module crc_core (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [1:0]  mode,
    input  wire        init,
    input  wire [7:0]  din,
    input  wire        din_valid,
    output wire [31:0] crc_out
);

// ---------------------------------------------------------------------------
// Per-byte update functions (8 serial bit steps unrolled combinationally)
// ---------------------------------------------------------------------------
function [7:0] crc8_step;       // MSB-first, poly 0x07
    input [7:0] c;
    input [7:0] d;
    reg [7:0] x;
    integer i;
    begin
        x = c;
        for (i = 7; i >= 0; i = i - 1) begin
            if (x[7] ^ d[i]) x = {x[6:0], 1'b0} ^ 8'h07;
            else             x = {x[6:0], 1'b0};
        end
        crc8_step = x;
    end
endfunction

function [15:0] crc16_step;     // MSB-first, poly 0x1021
    input [15:0] c;
    input [7:0]  d;
    reg [15:0] x;
    integer i;
    begin
        x = c;
        for (i = 7; i >= 0; i = i - 1) begin
            if (x[15] ^ d[i]) x = {x[14:0], 1'b0} ^ 16'h1021;
            else              x = {x[14:0], 1'b0};
        end
        crc16_step = x;
    end
endfunction

function [31:0] crc32_step;     // LSB-first reflected, poly 0xEDB88320
    input [31:0] c;
    input [7:0]  d;
    reg [31:0] x;
    integer i;
    begin
        x = c;
        for (i = 0; i < 8; i = i + 1) begin
            if (x[0] ^ d[i]) x = {1'b0, x[31:1]} ^ 32'hEDB88320;
            else             x = {1'b0, x[31:1]};
        end
        crc32_step = x;
    end
endfunction

// ---------------------------------------------------------------------------
reg [31:0] crc_r;

wire [31:0] crc_next =
    (mode == 2'd0) ? {24'd0, crc8_step(crc_r[7:0], din)}   :
    (mode == 2'd1) ? {16'd0, crc16_step(crc_r[15:0], din)} :
                     crc32_step(crc_r, din);

wire [31:0] crc_init =
    (mode == 2'd0) ? 32'h00000000 :
    (mode == 2'd1) ? 32'h0000FFFF : 32'hFFFFFFFF;

assign crc_out = crc_r ^ ((mode == 2'd2) ? 32'hFFFFFFFF : 32'h00000000);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        crc_r <= 32'hFFFFFFFF;
    end else if (clk_en) begin
        if (init)            crc_r <= crc_init;
        else if (din_valid)  crc_r <= crc_next;
    end
end

endmodule
