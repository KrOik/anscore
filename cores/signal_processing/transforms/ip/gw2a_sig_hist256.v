// ============================================================================
// gw2a_sig_hist256 : packaged wrapper for hist256 (256-bin histogram, BSRAM)
// Gowin GW2A-18C / Tang Primer 20K. 0 DSP, 1 BSRAM (18b x 256 SDP).
// Dependencies: src/hist256.v, src/sig_sdp_ram.v.  See ip/hist256/README.md.
// ============================================================================
module gw2a_sig_hist256 #(
    parameter CW = 16               // bin count width (<=18)
) (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output wire        busy,
    input  wire        in_valid,
    input  wire [7:0]  bin,
    output wire [23:0] total,
    input  wire        rd_en,
    input  wire [7:0]  rd_addr,
    output wire [CW-1:0] rd_data
);

hist256 #(.CW(CW)) u_core (
    .clk     (clk),
    .clk_en  (clk_en),
    .rst_n   (rst_n),
    .start   (start),
    .busy    (busy),
    .in_valid(in_valid),
    .bin     (bin),
    .total   (total),
    .rd_en   (rd_en),
    .rd_addr (rd_addr),
    .rd_data (rd_data)
);

endmodule
