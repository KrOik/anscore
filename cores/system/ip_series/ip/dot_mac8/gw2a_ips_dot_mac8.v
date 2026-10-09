// ---------------------------------------------------------------------------
// gw2a_ips_dot_mac8 : packaged, licensable wrapper for the ips_dot_mac8 core.
// Family arith.  8-lane fixed-point dot product tree with saturation, one vector per cycle throughput
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_dot_mac8 #(
    parameter AW = 16,
    parameter BW = 16,
    parameter ACCW = 32,
    parameter GUARD = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    output wire in_ready,
    input wire [8*AW-1:0] av,
    input wire [8*BW-1:0] bv,
    input wire first,
    output wire signed [ACCW-1:0] acc,
    output wire signed [AW+BW-1:0] prod,
    output wire [GUARD-1:0] headroom,
    output wire sat_pos,
    output wire sat_neg,
    output wire ovf_sticky,
    output wire pub_first,
    output wire valid,
    output wire [7:0] vec_count,
    output wire [7:0] sat_count,
    output wire busy,
    output wire [2:0] phase,
    output wire [1:0] stage
);

    ips_dot_mac8 #(
        .AW(AW),
        .BW(BW),
        .ACCW(ACCW),
        .GUARD(GUARD)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_ready(in_ready),
        .av(av),
        .bv(bv),
        .first(first),
        .acc(acc),
        .prod(prod),
        .headroom(headroom),
        .sat_pos(sat_pos),
        .sat_neg(sat_neg),
        .ovf_sticky(ovf_sticky),
        .pub_first(pub_first),
        .valid(valid),
        .vec_count(vec_count),
        .sat_count(sat_count),
        .busy(busy),
        .phase(phase),
        .stage(stage)
    );

endmodule
