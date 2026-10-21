// ============================================================================
// gw2a_sig_otsu_thresh : packaged wrapper for otsu_thresh
// Iterative Otsu threshold over a 256-bin 16-bit histogram. 0 DSP.
// Gowin GW2A-18C / Tang Primer 20K.
// Dependency: src/otsu_thresh.v.  See ip/otsu_thresh/README.md.
// ============================================================================
module gw2a_sig_otsu_thresh (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output wire        busy,
    output wire        done,
    output wire        h_req,
    output wire [7:0]  h_addr,
    input  wire [15:0] h_data,
    output wire [7:0]  thr,
    output wire [31:0] best_score
);

otsu_thresh u_core (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .busy       (busy),
    .done       (done),
    .h_req      (h_req),
    .h_addr     (h_addr),
    .h_data     (h_data),
    .thr        (thr),
    .best_score (best_score)
);

endmodule
