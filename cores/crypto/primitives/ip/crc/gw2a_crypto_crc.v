// ============================================================================
// gw2a_crypto_crc -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: crc_core  (src/crc_core.v)
// Board-validated: unit(s) 2/3/4 (CRC8/CR16/CR32), digest FD957A4B/D0771E60/720D8B44, bitstream m1e
// Clock protocol: posedge clk + clk_en step enable (tie 1 for full rate),
// active-low asynchronous rst_n. No DSP, no BSRAM.
// ============================================================================
module gw2a_crypto_crc (
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire [1:0] mode,  // 0=CRC-8, 1=CRC-16, 2=CRC-32
    input  wire init,  // pulse 1 clk_en beat: load per-mode init
    input  wire [7:0] din,  // message byte
    input  wire din_valid,  // one byte consumed per beat
    output  wire [31:0] crc_out   // running/final residue, xorout applied
);

    crc_core u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .mode(mode),
        .init(init),
        .din(din),
        .din_valid(din_valid),
        .crc_out(crc_out)
    );

endmodule
