// ---------------------------------------------------------------------------
// gw2a_ips_fix_add_sat : packaged, licensable wrapper for the ips_fix_add_sat core.
// Family arith.  Pipelined fixed-point add/sub with saturating or wrap-around result and sticky saturation flag
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_fix_add_sat #(
    parameter WIDTH = 16,
    parameter GUARD = 2
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire signed [WIDTH-1:0] a,
    input wire signed [WIDTH-1:0] b,
    input wire signed [WIDTH-1:0] k,
    output wire signed [WIDTH-1:0] y,
    output wire sat_pos,
    output wire sat_neg,
    output wire [GUARD-1:0] headroom,
    output wire [7:0] clip_count,
    output wire signed [WIDTH-1:0] y_max,
    output wire signed [WIDTH-1:0] y_min
);

    ips_fix_add_sat #(
        .WIDTH(WIDTH),
        .GUARD(GUARD)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .a(a),
        .b(b),
        .k(k),
        .y(y),
        .sat_pos(sat_pos),
        .sat_neg(sat_neg),
        .headroom(headroom),
        .clip_count(clip_count),
        .y_max(y_max),
        .y_min(y_min)
    );

endmodule
