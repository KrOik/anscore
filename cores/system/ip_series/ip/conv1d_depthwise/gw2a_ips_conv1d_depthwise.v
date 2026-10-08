// ---------------------------------------------------------------------------
// gw2a_ips_conv1d_depthwise : packaged, licensable wrapper for the ips_conv1d_depthwise core.
// Family nn.  Depthwise separable 1-D conv with programmable tap count, per-channel multiplier and shift
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_conv1d_depthwise #(
    parameter TAPS = 4,
    parameter YB = 8
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire [1:0] ch,
    input wire [2:0] tap,
    input wire [2:0] tcfg,
    input wire signed [7:0] xv,
    input wire pad_en,
    input wire signed [7:0] padv,
    output wire signed [YB-1:0] y,
    output wire out_valid,
    output wire sat_last,
    output wire [7:0] clip_count,
    output wire signed [17:0] acc,
    output wire [15:0] cfg_id
);

    ips_conv1d_depthwise #(
        .TAPS(TAPS),
        .YB(YB)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .ch(ch),
        .tap(tap),
        .tcfg(tcfg),
        .xv(xv),
        .pad_en(pad_en),
        .padv(padv),
        .y(y),
        .out_valid(out_valid),
        .sat_last(sat_last),
        .clip_count(clip_count),
        .acc(acc),
        .cfg_id(cfg_id)
    );

endmodule
