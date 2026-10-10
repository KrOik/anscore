// ---------------------------------------------------------------------------
// gw2a_ips_softmax_fixed : packaged, licensable wrapper for the ips_softmax_fixed core.
// Family nn.  Max-subtract, exp LUT, reciprocal-normalise softmax over 16 fixed-point logits
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_softmax_fixed #(
    parameter LANES = 16,
    parameter LB = 12,
    parameter PB = 8
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire signed [LB-1:0] lg,
    output wire signed [LB-1:0] rmax,
    output wire [12:0] rsum,
    output wire [7:0] exp_last,
    output wire [PB-1:0] p,
    output wire p_vld,
    output wire sat_sticky,
    output wire [7:0] clip_count,
    output wire [1:0] ph_last,
    output wire signed [13:0] resid,
    output wire [31:0] cfg_id
);

    ips_softmax_fixed #(
        .LANES(LANES),
        .LB(LB),
        .PB(PB)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .lg(lg),
        .rmax(rmax),
        .rsum(rsum),
        .exp_last(exp_last),
        .p(p),
        .p_vld(p_vld),
        .sat_sticky(sat_sticky),
        .clip_count(clip_count),
        .ph_last(ph_last),
        .resid(resid),
        .cfg_id(cfg_id)
    );

endmodule
