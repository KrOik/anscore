// ---------------------------------------------------------------------------
// gw2a_ips_ct_compare : packaged, licensable wrapper for the ips_ct_compare core.
// Family sec.  Length and content comparison that is time- and energy-constant, with early-exit resistance
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_ct_compare #(
    parameter WIDTH = 32,
    parameter LEN_BITS = 12,
    parameter ROT_BITS = 5,
    parameter LEN_BAD_CONST = 32'hD2E7_0001
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire cmp_start,
    input wire [LEN_BITS-1:0] exp_len,
    input wire in_valid,
    input wire in_last,
    input wire [WIDTH-1:0] cand_word,
    input wire [WIDTH-1:0] ref_word,
    output wire [WIDTH-1:0] diff_acc,
    output wire [LEN_BITS-1:0] match_cnt,
    output wire [LEN_BITS-1:0] mismatch_cnt,
    output wire [LEN_BITS-1:0] beat_cnt,
    output wire [LEN_BITS-1:0] exp_cnt,
    output wire len_err,
    output wire cmp_done
);

    ips_ct_compare #(
        .WIDTH(WIDTH),
        .LEN_BITS(LEN_BITS),
        .ROT_BITS(ROT_BITS),
        .LEN_BAD_CONST(LEN_BAD_CONST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .cmp_start(cmp_start),
        .exp_len(exp_len),
        .in_valid(in_valid),
        .in_last(in_last),
        .cand_word(cand_word),
        .ref_word(ref_word),
        .diff_acc(diff_acc),
        .match_cnt(match_cnt),
        .mismatch_cnt(mismatch_cnt),
        .beat_cnt(beat_cnt),
        .exp_cnt(exp_cnt),
        .len_err(len_err),
        .cmp_done(cmp_done)
    );

endmodule
