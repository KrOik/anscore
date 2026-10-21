// ---------------------------------------------------------------------------
// gw2a_ips_pdm_decim16 : packaged, licensable wrapper for the ips_pdm_decim16 core.
// Family iface.  1-bit PDM to 16-bit PCM decimator, three cascaded integrator-comb stages of order 3, OSR 16
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_pdm_decim16 #(
    parameter R_RATE = 16,
    parameter OUT_W = 16,
    parameter GAIN_SH = 4,
    parameter SAT_MAX = 5
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire pdm_tick,
    input wire pdm_in,
    output wire signed [OUT_W-1:0] pcm,
    output wire [3:0] pcm_hr,
    output wire pcm_valid,
    output wire sat_pos,
    output wire sat_neg,
    output wire sat_sticky,
    output wire [7:0] sat_count,
    output wire [7:0] out_count,
    output wire [4:0] phase
);

    ips_pdm_decim16 #(
        .R_RATE(R_RATE),
        .OUT_W(OUT_W),
        .GAIN_SH(GAIN_SH),
        .SAT_MAX(SAT_MAX)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .pdm_tick(pdm_tick),
        .pdm_in(pdm_in),
        .pcm(pcm),
        .pcm_hr(pcm_hr),
        .pcm_valid(pcm_valid),
        .sat_pos(sat_pos),
        .sat_neg(sat_neg),
        .sat_sticky(sat_sticky),
        .sat_count(sat_count),
        .out_count(out_count),
        .phase(phase)
    );

endmodule
