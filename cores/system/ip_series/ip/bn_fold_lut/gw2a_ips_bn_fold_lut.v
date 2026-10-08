// ---------------------------------------------------------------------------
// gw2a_ips_bn_fold_lut : packaged, licensable wrapper for the ips_bn_fold_lut core.
// Family nn.  Batch-norm folding helper: computes folded weight and bias per channel with fixed-point rounding
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_bn_fold_lut #(
    parameter SH = 9,
    parameter WB = 8,
    parameter BB = 16
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire sel,
    input wire [2:0] ch,
    input wire signed [11:0] w,
    output wire signed [WB-1:0] yw,
    output wire signed [BB-1:0] yb,
    output wire signed [23:0] fs_last,
    output wire y_vld,
    output wire sel_last,
    output wire [2:0] ch_last,
    output wire oor,
    output wire oor_w,
    output wire oor_b,
    output wire [7:0] clip_count,
    output wire [31:0] cfg_id
);

    ips_bn_fold_lut #(
        .SH(SH),
        .WB(WB),
        .BB(BB)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .sel(sel),
        .ch(ch),
        .w(w),
        .yw(yw),
        .yb(yb),
        .fs_last(fs_last),
        .y_vld(y_vld),
        .sel_last(sel_last),
        .ch_last(ch_last),
        .oor(oor),
        .oor_w(oor_w),
        .oor_b(oor_b),
        .clip_count(clip_count),
        .cfg_id(cfg_id)
    );

endmodule
