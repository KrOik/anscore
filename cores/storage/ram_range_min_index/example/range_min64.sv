// Original Apache-2.0 contribution. Fixed default all-port integration example.
module range_min64 (
    input wire clk, input wire rst_n,
    input wire c_valid, output wire c_ready, input wire [1:0] c_op,
    input wire [31:0] c_lo, input wire [31:0] c_hi,
    input wire [15:0] c_value, input wire [7:0] c_tag,
    output wire r_valid, input wire r_ready,
    output wire [1:0] r_op, output wire [1:0] r_status,
    output wire [31:0] r_index, output wire [15:0] r_value,
    output wire [7:0] r_tag
);
    ram_range_min_index #(.BUCKETS(64),.VALUE_W(16),.TAG_W(8)) core (
        .clk(clk),.rst_n(rst_n),.c_valid(c_valid),.c_ready(c_ready),
        .c_op(c_op),.c_lo(c_lo),.c_hi(c_hi),.c_value(c_value),.c_tag(c_tag),
        .r_valid(r_valid),.r_ready(r_ready),.r_op(r_op),.r_status(r_status),
        .r_index(r_index),.r_value(r_value),.r_tag(r_tag)
    );
endmodule
