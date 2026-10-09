// ---------------------------------------------------------------------------
// gw2a_ips_iir_biquad : packaged, licensable wrapper for the ips_iir_biquad core.
// Family arith.  Direct-form II biquad IIR section, transposed dual accumulators, saturation on state update
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_iir_biquad #(
    parameter B0 = 6,
    parameter B1 = 13,
    parameter B2 = 6,
    parameter C1 = 90,
    parameter C2 = -38,
    parameter QDIV = 6,
    parameter GUARD = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire signed [11:0] x_in,
    output wire signed [11:0] y_out,
    output wire signed [11:0] state1,
    output wire signed [11:0] state2,
    output wire [GUARD-1:0] headroom,
    output wire [7:0] sat_cnt,
    output wire [7:0] nsmp,
    output wire satur,
    output wire valid,
    output wire busy,
    output wire [2:0] stage,
    output wire [1:0] step
);

    ips_iir_biquad #(
        .B0(B0),
        .B1(B1),
        .B2(B2),
        .C1(C1),
        .C2(C2),
        .QDIV(QDIV),
        .GUARD(GUARD)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .x_in(x_in),
        .y_out(y_out),
        .state1(state1),
        .state2(state2),
        .headroom(headroom),
        .sat_cnt(sat_cnt),
        .nsmp(nsmp),
        .satur(satur),
        .valid(valid),
        .busy(busy),
        .stage(stage),
        .step(step)
    );

endmodule
