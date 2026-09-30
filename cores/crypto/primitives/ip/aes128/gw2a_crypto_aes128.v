// ============================================================================
// gw2a_crypto_aes128 -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: aes128_core  (src/aes128_core.v)
// Board-validated: unit(s) 0 (AESB), digest 61C7D1CF, bitstream m01
// Clock protocol: posedge clk + clk_en step enable (tie 1 for full rate),
// active-low asynchronous rst_n. No DSP, no BSRAM.
// ============================================================================
module gw2a_crypto_aes128 (
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire start,  // pulse 1 clk_en beat; key/din must be stable
    input  wire [127:0] key,  // cipher key, byte 0 = key[127:120]
    input  wire [127:0] din,  // plaintext block, byte 0 = din[127:120]
    output  wire [127:0] dout,  // ciphertext, valid when done pulses
    output  wire done,  // 1-beat pulse when dout is ready
    output  wire busy   // high while a block is being processed
);

    aes128_core u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .start(start),
        .key(key),
        .din(din),
        .dout(dout),
        .done(done),
        .busy(busy)
    );

endmodule
