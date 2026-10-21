// ---------------------------------------------------------------------------
// gw2a_ips_int8_mac_array : packaged, licensable wrapper for the ips_int8_mac_array core.
// Family nn.  8x8 int8 multiply-accumulate array with per-row bias and int32 saturating accumulation
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_int8_mac_array #(
    parameter LANES = 4,
    parameter ACCW = 32,
    parameter GUARD = 2
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire load,
    input wire [LANES*8-1:0] x,
    input wire [LANES*8-1:0] w,
    input wire [LANES*ACCW-1:0] bias,
    output wire [LANES*ACCW-1:0] acc,
    output wire [LANES*GUARD-1:0] headroom,
    output wire [LANES-1:0] sat,
    output wire [7:0] clip_count,
    output wire [31:0] geom_id
);

    ips_int8_mac_array #(
        .LANES(LANES),
        .ACCW(ACCW),
        .GUARD(GUARD)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .load(load),
        .x(x),
        .w(w),
        .bias(bias),
        .acc(acc),
        .headroom(headroom),
        .sat(sat),
        .clip_count(clip_count),
        .geom_id(geom_id)
    );

endmodule
