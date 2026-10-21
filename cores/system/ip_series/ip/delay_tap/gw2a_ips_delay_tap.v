// ---------------------------------------------------------------------------
// gw2a_ips_delay_tap : packaged, licensable wrapper for the ips_delay_tap core.
// Family path.  Programmable 0..255-cycle delay line that carries valid/ready payload without bubble re-alignment
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_delay_tap #(
    parameter PAY_W = 8,
    parameter MAX_DELAY = 15
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire [PAY_W-1:0] in_data,
    input wire stall,
    input wire [7:0] delay_sel,
    output wire [PAY_W-1:0] out_data,
    output wire out_valid,
    output wire in_ready,
    output wire [7:0] tap_index,
    output wire [7:0] active_lat,
    output wire [7:0] beat_count,
    output wire [7:0] drop_count,
    output wire [7:0] lat_events,
    output wire drop_sticky
);

    ips_delay_tap #(
        .PAY_W(PAY_W),
        .MAX_DELAY(MAX_DELAY)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_data(in_data),
        .stall(stall),
        .delay_sel(delay_sel),
        .out_data(out_data),
        .out_valid(out_valid),
        .in_ready(in_ready),
        .tap_index(tap_index),
        .active_lat(active_lat),
        .beat_count(beat_count),
        .drop_count(drop_count),
        .lat_events(lat_events),
        .drop_sticky(drop_sticky)
    );

endmodule
