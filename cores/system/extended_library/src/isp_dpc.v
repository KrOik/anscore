// ============================================================================
// isp_dpc -- defective pixel correction on a streaming 3x3 window.
//
// For each emitted window (win3x3_gen / w2_win_rd layout, edge-replicated):
//   c    = centre tap (win[39:32])
//   med8 = (s[3] + s[4]) >> 1 of the 8 sorted neighbours
//   out  = (|c - med8| > THR) ? med8 : c
// Combinational network + registered output, one clk_en beat latency
// (same contract as imgwin median3x3).  sort8 = Batcher odd-even mergesort,
// 19 comparators; verified against a true sort in tools/golden_isp.py.
// All registers are clk_en gated (T2).  No multipliers.
// ============================================================================
module isp_dpc #(
    parameter [7:0] THR = 8'd32
)(
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
    // comparator-exchange: returns {hi, lo}
    function [15:0] ce;
        input [7:0] a, b;
        begin
            ce = (a < b) ? {b, a} : {a, b};
        end
    endfunction

    // neighbours: taps 0,1,2,3,5,6,7,8 (skip centre tap 4)
    wire [7:0] n0 = win[7:0];
    wire [7:0] n1 = win[15:8];
    wire [7:0] n2 = win[23:16];
    wire [7:0] n3 = win[31:24];
    wire [7:0] n4 = win[47:40];
    wire [7:0] n5 = win[55:48];
    wire [7:0] n6 = win[63:56];
    wire [7:0] n7 = win[71:64];

    // Batcher odd-even mergesort, n=8 (19 comparators)
    wire [15:0] p01 = ce(n0, n1);
    wire [15:0] p23 = ce(n2, n3);
    wire [15:0] p45 = ce(n4, n5);
    wire [15:0] p67 = ce(n6, n7);

    wire [15:0] q02 = ce(p01[7:0],  p23[7:0]);   // (0,2)
    wire [15:0] q13 = ce(p01[15:8], p23[15:8]);  // (1,3)
    wire [15:0] q46 = ce(p45[7:0],  p67[7:0]);   // (4,6)
    wire [15:0] q57 = ce(p45[15:8], p67[15:8]);  // (5,7)

    wire [15:0] r12 = ce(q02[15:8], q13[7:0]);   // (1,2)
    wire [15:0] r56 = ce(q46[15:8], q57[7:0]);   // (5,6)

    // sorted half A: a0=q02[7:0] a1=r12[7:0] a2=r12[15:8] a3=q13[15:8]
    // sorted half B: b0=q46[7:0] b1=r56[7:0] b2=r56[15:8] b3=q57[15:8]
    wire [15:0] m04 = ce(q02[7:0],  q46[7:0]);   // (0,4)
    wire [15:0] m15 = ce(r12[7:0],  r56[7:0]);   // (1,5)
    wire [15:0] m26 = ce(r12[15:8], r56[15:8]);  // (2,6)
    wire [15:0] m37 = ce(q13[15:8], q57[15:8]);  // (3,7)

    wire [15:0] m24 = ce(m26[7:0],  m04[15:8]);  // (2,4)
    wire [15:0] m35 = ce(m37[7:0],  m15[15:8]);  // (3,5)

    // merge cleanup: (1,2) (3,4) (5,6)
    wire [15:0] f12 = ce(m15[7:0],  m24[7:0]);   // (1,2)
    wire [15:0] f34 = ce(m35[7:0],  m24[15:8]);  // (3,4)
    wire [15:0] f56 = ce(m35[15:8], m26[15:8]);  // (5,6)

    // ascending: s0=m04[7:0] s1=f12[7:0] s2=f12[15:8] s3=f34[7:0]
    //            s4=f34[15:8] s5=f56[7:0] s6=f56[15:8] s7=m37[15:8]
    wire [8:0]  med_sum = {1'b0, f34[7:0]} + {1'b0, f34[15:8]};
    wire [7:0]  med8    = med_sum[8:1];
    wire [7:0]  ctr     = win[39:32];
    wire [7:0]  d_ab    = (ctr > med8) ? (ctr - med8) : (med8 - ctr);
    wire [7:0]  corr    = (d_ab > THR) ? med8 : ctr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= corr;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
