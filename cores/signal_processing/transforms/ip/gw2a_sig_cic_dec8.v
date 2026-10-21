// ============================================================================
// gw2a_sig_cic_dec8 : packaged wrapper for cic_dec8 (CIC decimator N=3 R=8 M=1)
// Gowin GW2A-18C / Tang Primer 20K. 0 DSP, 0 BSRAM.
// Dependency: src/cic_dec8.v.  See ip/cic_dec8/README.md.
// ============================================================================
module gw2a_sig_cic_dec8 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        in_valid,
    input  wire signed [7:0]  din,
    output wire        out_valid,
    output wire signed [16:0] dout
);

cic_dec8 u_core (
    .clk       (clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .din       (din),
    .out_valid (out_valid),
    .dout      (dout)
);

endmodule
