module ntt256_systolic_bank_mapper (
    input  wire       inverse,
    input  wire [2:0] stage,
    input  wire [6:0] butterfly_index,
    output wire [7:0] addr_a,
    output wire [7:0] addr_b,
    output wire [1:0] bank_a,
    output wire [1:0] bank_b,
    output wire       conflict
);

wire [2:0] gap_log = inverse ? (3'd7 - stage) : stage;
wire [3:0] gap_shift = {1'b0, gap_log};
wire [3:0] block_shift = {1'b0, gap_log} + 4'd1;
wire [7:0] gap = 8'd1 << gap_shift;
wire [7:0] low_mask = gap - 8'd1;
wire [7:0] index_ext = {1'b0, butterfly_index};
wire [7:0] j_index = index_ext & low_mask;
wire [7:0] block_base = (index_ext >> gap_shift) << block_shift;
wire bank_group = stage[0] ^ inverse;

assign addr_a = block_base + j_index;
assign addr_b = addr_a + gap;
assign bank_a = {bank_group, addr_a[gap_log]};
assign bank_b = {bank_group, addr_b[gap_log]};
assign conflict = (addr_a == addr_b) || (bank_a == bank_b) || (addr_b < addr_a);

endmodule
