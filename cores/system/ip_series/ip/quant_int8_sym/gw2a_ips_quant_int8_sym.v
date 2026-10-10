// ---------------------------------------------------------------------------
// gw2a_ips_quant_int8_sym : packaged, licensable wrapper for the ips_quant_int8_sym core.
// Family nn.  Symmetric quantise and dequantise pair with programmable scale, round-half-away and clipping
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_quant_int8_sym #(
    parameter XB = 12,
    parameter MB = 12,
    parameter YB = 8
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire dir,
    input wire [1:0] ch,
    input wire signed [XB-1:0] x,
    output wire signed [YB-1:0] yq,
    output wire signed [15:0] ydq,
    output wire [15:0] ymag,
    output wire y_neg,
    output wire y_vld,
    output wire clipped_last,
    output wire sat_q,
    output wire sat_d,
    output wire udf_sticky,
    output wire [7:0] clip_count,
    output wire [31:0] cfg_id
);

    ips_quant_int8_sym #(
        .XB(XB),
        .MB(MB),
        .YB(YB)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .dir(dir),
        .ch(ch),
        .x(x),
        .yq(yq),
        .ydq(ydq),
        .ymag(ymag),
        .y_neg(y_neg),
        .y_vld(y_vld),
        .clipped_last(clipped_last),
        .sat_q(sat_q),
        .sat_d(sat_d),
        .udf_sticky(udf_sticky),
        .clip_count(clip_count),
        .cfg_id(cfg_id)
    );

endmodule
