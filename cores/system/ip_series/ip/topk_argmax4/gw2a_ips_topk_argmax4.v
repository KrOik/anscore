// ---------------------------------------------------------------------------
// gw2a_ips_topk_argmax4 : packaged, licensable wrapper for the ips_topk_argmax4 core.
// Family nn.  Unordered top-4 of 16 fixed-point scores with distinct-index handling and tie-break by index
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_topk_argmax4 #(
    parameter SW = 12,
    parameter NSC = 16,
    parameter IB = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire signed [SW-1:0] s,
    input wire [IB-1:0] idx,
    output wire signed [SW-1:0] t0,
    output wire signed [SW-1:0] t1,
    output wire signed [SW-1:0] t2,
    output wire signed [SW-1:0] t3,
    output wire [IB-1:0] i0,
    output wire [IB-1:0] i1,
    output wire [IB-1:0] i2,
    output wire [IB-1:0] i3,
    output wire v0,
    output wire v1,
    output wire v2,
    output wire v3,
    output wire [2:0] pos_last,
    output wire [IB:0] beat_last,
    output wire done,
    output wire rep_last,
    output wire drop_last,
    output wire in_last,
    output wire [7:0] drop_count,
    output wire [7:0] rep_count,
    output wire [31:0] cfg_id
);

    ips_topk_argmax4 #(
        .SW(SW),
        .NSC(NSC),
        .IB(IB)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .s(s),
        .idx(idx),
        .t0(t0),
        .t1(t1),
        .t2(t2),
        .t3(t3),
        .i0(i0),
        .i1(i1),
        .i2(i2),
        .i3(i3),
        .v0(v0),
        .v1(v1),
        .v2(v2),
        .v3(v3),
        .pos_last(pos_last),
        .beat_last(beat_last),
        .done(done),
        .rep_last(rep_last),
        .drop_last(drop_last),
        .in_last(in_last),
        .drop_count(drop_count),
        .rep_count(rep_count),
        .cfg_id(cfg_id)
    );

endmodule
