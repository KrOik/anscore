// ---------------------------------------------------------------------------
// gw2a_ips_cdc_reset_bridge : packaged, licensable wrapper for the ips_cdc_reset_bridge core.
// Family cdc.  POR counter plus 2FF reset release bridge, asserts reset on async glitch and reports sticky glitch count
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_cdc_reset_bridge #(
    parameter POR_W = 5,
    parameter POR_LAST = 12
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire src_tick,
    input wire dst_tick,
    input wire arst_req,
    output wire src_ok,
    output wire por_done,
    output wire [POR_W-1:0] por_count,
    output wire sync1,
    output wire sync2,
    output wire rst_out_n,
    output wire released,
    output wire glitch_sticky,
    output wire [3:0] glitch_count,
    output wire [3:0] rst_events
);

    ips_cdc_reset_bridge #(
        .POR_W(POR_W),
        .POR_LAST(POR_LAST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .src_tick(src_tick),
        .dst_tick(dst_tick),
        .arst_req(arst_req),
        .src_ok(src_ok),
        .por_done(por_done),
        .por_count(por_count),
        .sync1(sync1),
        .sync2(sync2),
        .rst_out_n(rst_out_n),
        .released(released),
        .glitch_sticky(glitch_sticky),
        .glitch_count(glitch_count),
        .rst_events(rst_events)
    );

endmodule
