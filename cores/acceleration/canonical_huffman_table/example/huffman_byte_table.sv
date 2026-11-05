// SPDX-License-Identifier: Apache-2.0
module huffman_byte_table (
    input wire clk, rst, c_valid, output wire c_ready,
    input wire [1:0] c_op,
    input wire [31:0] c_symbol, c_length,
    input wire [7:0] c_tag,
    output wire r_valid, input wire r_ready,
    output wire [1:0] r_op, output wire [2:0] r_status,
    output wire [15:0] r_code, output wire [31:0] r_length,
    output wire [7:0] r_tag
);
    canonical_huffman_table #(.SYMBOLS(256),.MAX_BITS(16),.TAG_W(8)) table_core (
        .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_op(c_op),
        .c_symbol(c_symbol),.c_length(c_length),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_op(r_op),.r_status(r_status),
        .r_code(r_code),.r_length(r_length),.r_tag(r_tag)
    );
endmodule
