// ============================================================================
// gw2a_sig_fft64 : packaged wrapper for fft64 (64-pt radix-2 DIT FFT, Q1.15)
// Gowin GW2A-18C / Tang Primer 20K. 0 DSP (shift-add twiddle multiply).
// Dependencies: src/fft64.v, src/sig_sdp_ram.v,
//               src/tw_rom_cos.v, src/tw_rom_sin.v (no readmemh files).
// Ports are identical to the inner core; see ip/fft64/README.md.
// ============================================================================
module gw2a_sig_fft64 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        ld_en,
    input  wire [5:0]  ld_addr,
    input  wire signed [15:0] ld_re,
    input  wire signed [15:0] ld_im,
    input  wire        start,
    output wire        busy,
    output wire        done,
    input  wire        rd_en,
    input  wire [5:0]  rd_addr,
    output wire signed [15:0] rd_re,
    output wire signed [15:0] rd_im
);

fft64 u_core (
    .clk     (clk),
    .clk_en  (clk_en),
    .rst_n   (rst_n),
    .ld_en   (ld_en),
    .ld_addr (ld_addr),
    .ld_re   (ld_re),
    .ld_im   (ld_im),
    .start   (start),
    .busy    (busy),
    .done    (done),
    .rd_en   (rd_en),
    .rd_addr (rd_addr),
    .rd_re   (rd_re),
    .rd_im   (rd_im)
);

endmodule
