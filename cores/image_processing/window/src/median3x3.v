// ============================================================================
// median3x3 -- 3x3 median filter, row/column layered sorting network
// (7 x sort3 = 21 compare-swap stages; classic J.L. Smith network):
//   1. sort each row ascending
//   2. sort each column ascending
//   3. median = middle element of the anti-diagonal {p6, p4, p2}
// Verified exhaustively in tools/golden_model.py against a true sort.
// Combinational network + registered output, one clk_en beat latency.
// NOTE: the combinational network is ~9 compare levels deep; use clk_en
// step-down (e.g. /16) or add pipeline registers for high clock rates.
// ============================================================================
module median3x3 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         nl_out
);
    // sort3: ascending order; returns {hi, mid, lo}.  Middle element is
    // recovered as a+b+c-lo-hi (8-bit modular arithmetic is exact here).
    function [23:0] sort3;
        input [7:0] a, b, c;
        reg [7:0] lo, mid, hi, t_lo, t_hi;
        begin
            t_lo = (a < b) ? a : b;
            t_hi = (a < b) ? b : a;
            lo   = (t_lo < c) ? t_lo : c;
            hi   = (t_hi > c) ? t_hi : c;
            mid  = t_lo + t_hi + c - lo - hi;
            sort3 = {hi, mid, lo};
        end
    endfunction

    // stage 1: sort rows
    wire [23:0] r0 = sort3(win[7:0],   win[15:8],  win[23:16]);
    wire [23:0] r1 = sort3(win[31:24], win[39:32], win[47:40]);
    wire [23:0] r2 = sort3(win[55:48], win[63:56], win[71:64]);

    // stage 2: sort columns (lo at [7:0], hi at [23:16])
    wire [23:0] c0 = sort3(r0[7:0],  r1[7:0],  r2[7:0]);
    wire [23:0] c1 = sort3(r0[15:8], r1[15:8], r2[15:8]);
    wire [23:0] c2 = sort3(r0[23:16],r1[23:16],r2[23:16]);

    // stage 3: median of anti-diagonal {max-of-mins, mid-of-mids, min-of-maxs}
    wire [23:0] dg = sort3(c0[23:16], c1[15:8], c2[7:0]);
    wire [7:0]  med = dg[15:8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= med;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
