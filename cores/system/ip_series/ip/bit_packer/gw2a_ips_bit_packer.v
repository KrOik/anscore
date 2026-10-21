// ---------------------------------------------------------------------------
// gw2a_ips_bit_packer : packaged, licensable wrapper for the ips_bit_packer core.
// Family pkt.  MSB-first bit packer turning N-bit fields of arbitrary width into a byte-aligned output burst
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_bit_packer #(
    parameter FIELD_BITS = 11,
    parameter OUT_BITS = 8,
    parameter MAX_BURST = 24
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire in_last,
    input wire [FIELD_BITS-1:0] in_field,
    input wire flush,
    output wire in_ready,
    output wire out_valid,
    output wire out_last,
    output wire [OUT_BITS-1:0] out_word,
    output wire [4:0] resid_bits,
    output wire [3:0] pad_bits,
    output wire [5:0] burst_len,
    output wire [7:0] cnt_fields,
    output wire [7:0] cnt_words,
    output wire [3:0] cnt_flush,
    output wire [3:0] cnt_spur,
    output wire [4:0] max_resid,
    output wire [11:0] bits_in,
    output wire [11:0] bits_out,
    output wire [1:0] err_sticky,
    output wire [5:0] cnt_sat
);

    ips_bit_packer #(
        .FIELD_BITS(FIELD_BITS),
        .OUT_BITS(OUT_BITS),
        .MAX_BURST(MAX_BURST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_last(in_last),
        .in_field(in_field),
        .flush(flush),
        .in_ready(in_ready),
        .out_valid(out_valid),
        .out_last(out_last),
        .out_word(out_word),
        .resid_bits(resid_bits),
        .pad_bits(pad_bits),
        .burst_len(burst_len),
        .cnt_fields(cnt_fields),
        .cnt_words(cnt_words),
        .cnt_flush(cnt_flush),
        .cnt_spur(cnt_spur),
        .max_resid(max_resid),
        .bits_in(bits_in),
        .bits_out(bits_out),
        .err_sticky(err_sticky),
        .cnt_sat(cnt_sat)
    );

endmodule
