// Dual-clock asynchronous FIFO, Gray-pointer full/empty detection.
//   DEPTH = 2**AW entries of DW bits
//   wr domain: wr_clk/wr_rst_n, wr_en + din, full
//   rd domain: rd_clk/rd_rst_n, rd_en + dout (registered, valid next rd_clk), empty
// Pointers use AW+1 bits with wrap-bit full detection; each pointer is
// synchronized into the other domain through a 2-FF Gray-code chain.
module fifo_async #(
    parameter integer DW = 8,
    parameter integer AW = 4
) (
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire           wr_en,
    input  wire [DW-1:0]  din,
    output wire           full,
    input  wire           rd_clk,
    input  wire           rd_rst_n,
    input  wire           rd_en,
    output reg  [DW-1:0]  dout = {DW{1'b0}},
    output wire           empty
);

localparam integer DEPTH = (1 << AW);

reg [DW-1:0] mem [0:DEPTH-1];

// pointers (both domains declared up-front; each is written in one domain
// and Gray-synchronized into the other)
reg  [AW:0] wptr_bin, wptr_gray;
// rd-domain regs carry explicit power-on initializers: when rd_clk is a
// hard-divided clock (CLKDIV2) it is stopped while rd_rst_n is low, so no
// posedge ever executes the async-reset branch. Hardware FFs power up at 0;
// these inits make simulation match hardware exactly.
reg  [AW:0] rptr_bin     = {AW+1{1'b0}};
reg  [AW:0] rptr_gray    = {AW+1{1'b0}};
reg  [AW:0] rptr_gray_w1, rptr_gray_w2;
reg  [AW:0] wptr_gray_r1 = {AW+1{1'b0}};
reg  [AW:0] wptr_gray_r2 = {AW+1{1'b0}};

// ------------------------------------------------------------- write domain

wire [AW:0] wptr_bin_next  = wptr_bin + ((wr_en && !full) ? {{AW{1'b0}},1'b1} : {AW+1{1'b0}});
wire [AW:0] wptr_gray_next = (wptr_bin_next >> 1) ^ wptr_bin_next;
// current-pointer compare: no combinational full->bin_next->full loop
assign full = (wptr_gray == {~rptr_gray_w2[AW:AW-1], rptr_gray_w2[AW-2:0]});

wire wr_push = wr_en && !full;

always @(posedge wr_clk or negedge wr_rst_n) begin
    if (!wr_rst_n) begin
        wptr_bin     <= {AW+1{1'b0}};
        wptr_gray    <= {AW+1{1'b0}};
        rptr_gray_w1 <= {AW+1{1'b0}};
        rptr_gray_w2 <= {AW+1{1'b0}};
    end else begin
        rptr_gray_w1 <= rptr_gray;
        rptr_gray_w2 <= rptr_gray_w1;
        wptr_bin     <= wptr_bin_next;
        wptr_gray    <= wptr_gray_next;
    end
end

// memory write in a pure posedge block (BRAM-friendly form)
always @(posedge wr_clk) begin
    if (wr_push) mem[wptr_bin[AW-1:0]] <= din;
end

// ------------------------------------------------------------- read domain
wire [AW:0] rptr_bin_next  = rptr_bin + ((rd_en && !empty) ? {{AW{1'b0}},1'b1} : {AW+1{1'b0}});
wire [AW:0] rptr_gray_next = (rptr_bin_next >> 1) ^ rptr_bin_next;
assign empty = (rptr_gray == wptr_gray_r2);

wire rd_pop = rd_en && !empty;

always @(posedge rd_clk or negedge rd_rst_n) begin
    if (!rd_rst_n) begin
        rptr_bin     <= {AW+1{1'b0}};
        rptr_gray    <= {AW+1{1'b0}};
        wptr_gray_r1 <= {AW+1{1'b0}};
        wptr_gray_r2 <= {AW+1{1'b0}};
        dout         <= {DW{1'b0}};
    end else begin
        wptr_gray_r1 <= wptr_gray;
        wptr_gray_r2 <= wptr_gray_r1;
        rptr_bin     <= rptr_bin_next;
        rptr_gray    <= rptr_gray_next;
        if (rd_pop) dout <= mem[rptr_bin[AW-1:0]];
    end
end

endmodule
