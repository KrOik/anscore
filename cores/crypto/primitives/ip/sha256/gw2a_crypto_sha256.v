// ============================================================================
// gw2a_crypto_sha256 -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: sha256_core  (src/sha256_core.v)
// Board-validated: unit(s) 1 (SHAB), digest 566ACEA2, bitstream m1e
// Clock protocol: posedge clk + clk_en step enable (tie 1 for full rate),
// active-low asynchronous rst_n. No DSP, no BSRAM.
// ============================================================================
module gw2a_crypto_sha256 (
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire init,  // pulse 1 clk_en beat to start a new message
    input  wire [7:0] din,  // message byte
    input  wire din_valid,  // byte valid; honored only while din_ready
    input  wire din_last,  // marks the final message byte
    output  wire din_ready,  // low during 64-round compression
    output  wire [255:0] digest,  // {H0..H7}, H0 at [255:224]
    output  wire digest_valid   // level: digest complete
);

    sha256_core u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .init(init),
        .din(din),
        .din_valid(din_valid),
        .din_last(din_last),
        .din_ready(din_ready),
        .digest(digest),
        .digest_valid(digest_valid)
    );

endmodule
