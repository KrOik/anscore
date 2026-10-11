`timescale 1ns / 1ps
// ips_fifo_sync_fwft : synchronous first-word-fall-through FIFO.
//
// DEPTH is a power-of-two parameter; the pointer and occupancy widths follow it.
// A write is taken while not full and a read while not empty, both in the same
// beat (concurrent read/write leaves the occupancy unchanged).  rdata is the
// head word as soon as the FIFO is non-empty, with no read-latency bubble, and
// is blanked while empty so the output can never resolve to X (trap T6).
// wm_hi / wm_lo are programmatic watermarks compared against the registered
// occupancy; a write attempted while full latches ov_flag and counts it, a read
// attempted while empty latches uf_flag and counts it, both 4-bit wrapping.
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset (trap T2).  The store is a modest register array, no BSRAM primitive.
module ips_fifo_sync_fwft #(
    parameter DATA_W = 8,
    parameter DEPTH = 16
)(
    input  wire                     clk,
    input  wire                     clk_en,
    input  wire                     rst_n,

    input  wire                     wr_req,
    input  wire  [DATA_W-1:0]       wdata,
    input  wire                     rd_req,
    input  wire  [($clog2(DEPTH)):0] wm_hi,
    input  wire  [($clog2(DEPTH)):0] wm_lo,

    output wire  [DATA_W-1:0]       rdata,
    output wire                     full,
    output wire                     empty,
    output reg   [($clog2(DEPTH)):0] level,
    output reg                      flag_hi,
    output reg                      flag_lo,
    output reg                      ov_flag,
    output reg                      uf_flag,
    output reg   [3:0]              ov_count,
    output reg   [3:0]              uf_count
);

localparam PW = $clog2(DEPTH);
localparam [PW-1:0] LAST = DEPTH - 1;
localparam [PW:0] FULL_LVL = DEPTH;

reg [DATA_W-1:0] mem [0:DEPTH-1];
reg [PW-1:0] wptr;
reg [PW-1:0] rptr;

wire do_write = wr_req && !full;
wire do_read  = rd_req && !empty;

assign full  = (level == FULL_LVL);
assign empty = !level;
assign rdata = empty ? 0 : mem[rptr];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        wptr     <= {PW{1'b0}};
        rptr     <= {PW{1'b0}};
        level    <= {(PW+1){1'b0}};
        flag_hi  <= 1'b0;
        flag_lo  <= 1'b1;
        ov_flag  <= 1'b0;
        uf_flag  <= 1'b0;
        ov_count <= 4'h0;
        uf_count <= 4'h0;
    end else if (clk_en) begin
        if (do_write) begin
            mem[wptr] <= wdata;
            if (wptr == LAST) begin
                wptr <= 0;
            end else begin
                wptr <= wptr + 1;
            end
        end
        if (do_read) begin
            if (rptr == LAST) begin
                rptr <= 0;
            end else begin
                rptr <= rptr + 1;
            end
        end
        if (do_write ^ do_read) begin
            if (do_write) begin
                level <= level + 1;
            end else begin
                level <= level - 1;
            end
        end
        if (wr_req && full) begin
            ov_flag  <= 1;
            ov_count <= ov_count + 1;
        end
        if (rd_req && empty) begin
            uf_flag  <= 1;
            uf_count <= uf_count + 1;
        end
        flag_hi <= (level >= wm_hi);
        flag_lo <= (level <= wm_lo);
    end
end

endmodule
