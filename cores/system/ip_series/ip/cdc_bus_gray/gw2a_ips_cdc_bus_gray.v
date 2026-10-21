// ---------------------------------------------------------------------------
// gw2a_ips_cdc_bus_gray : packaged, licensable wrapper for the ips_cdc_bus_gray core.
// Family cdc.  Binary-to-Gray pointer crossing for async FIFO style multi-bit bus coherence
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_cdc_bus_gray #(
    parameter PTR_W = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire src_tick,
    input wire dst_tick,
    input wire [PTR_W-1:0] src_step,
    output wire [PTR_W-1:0] bin_ptr,
    output wire [PTR_W-1:0] gray_q,
    output wire [PTR_W-1:0] sync1,
    output wire [PTR_W-1:0] sync2,
    output wire [PTR_W-1:0] bin_dec,
    output wire err_sticky,
    output wire [3:0] err_count,
    output wire [3:0] sync_count,
    output wire [3:0] hold_count
);

    ips_cdc_bus_gray #(
        .PTR_W(PTR_W)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .src_tick(src_tick),
        .dst_tick(dst_tick),
        .src_step(src_step),
        .bin_ptr(bin_ptr),
        .gray_q(gray_q),
        .sync1(sync1),
        .sync2(sync2),
        .bin_dec(bin_dec),
        .err_sticky(err_sticky),
        .err_count(err_count),
        .sync_count(sync_count),
        .hold_count(hold_count)
    );

endmodule
