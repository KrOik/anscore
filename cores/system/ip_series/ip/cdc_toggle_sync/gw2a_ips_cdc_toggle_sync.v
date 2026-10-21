// ---------------------------------------------------------------------------
// gw2a_ips_cdc_toggle_sync : packaged, licensable wrapper for the ips_cdc_toggle_sync core.
// Family cdc.  Two-flop toggle synchroniser with data-stable-before-req rule and transfer/error counters
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_cdc_toggle_sync #(
    parameter DATA_W = 12,
    parameter CNT_W = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire src_tick,
    input wire dst_tick,
    input wire src_start,
    input wire [DATA_W-1:0] src_data,
    input wire dst_take,
    output wire [DATA_W-1:0] data_hold,
    output wire tog_src,
    output wire pend,
    output wire outstanding,
    output wire [CNT_W-1:0] tx_count,
    output wire [CNT_W-1:0] rx_count,
    output wire [CNT_W-1:0] err_count,
    output wire err_sticky,
    output wire [DATA_W-1:0] dst_data,
    output wire dst_valid,
    output wire ack_tog,
    output wire tog_s1,
    output wire tog_s2,
    output wire ack_s1,
    output wire ack_s2
);

    ips_cdc_toggle_sync #(
        .DATA_W(DATA_W),
        .CNT_W(CNT_W)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .src_tick(src_tick),
        .dst_tick(dst_tick),
        .src_start(src_start),
        .src_data(src_data),
        .dst_take(dst_take),
        .data_hold(data_hold),
        .tog_src(tog_src),
        .pend(pend),
        .outstanding(outstanding),
        .tx_count(tx_count),
        .rx_count(rx_count),
        .err_count(err_count),
        .err_sticky(err_sticky),
        .dst_data(dst_data),
        .dst_valid(dst_valid),
        .ack_tog(ack_tog),
        .tog_s1(tog_s1),
        .tog_s2(tog_s2),
        .ack_s1(ack_s1),
        .ack_s2(ack_s2)
    );

endmodule
