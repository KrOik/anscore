// ---------------------------------------------------------------------------
// gw2a_ips_cdc_handshake_2ff : packaged, licensable wrapper for the ips_cdc_handshake_2ff core.
// Family cdc.  4-phase req/ack handshake crossing for a multi-bit word, data launched one source cycle before req
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_cdc_handshake_2ff #(
    parameter DATA_W = 16,
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
    output wire req,
    output wire pend,
    output wire busy,
    output wire phase,
    output wire [CNT_W-1:0] tx_count,
    output wire [CNT_W-1:0] err_count,
    output wire err_sticky,
    output wire ack_s1,
    output wire ack_s2,
    output wire [DATA_W-1:0] data_dst,
    output wire valid,
    output wire ack,
    output wire [CNT_W-1:0] rx_count,
    output wire [CNT_W-1:0] hop_count,
    output wire req_s1,
    output wire req_s2
);

    ips_cdc_handshake_2ff #(
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
        .req(req),
        .pend(pend),
        .busy(busy),
        .phase(phase),
        .tx_count(tx_count),
        .err_count(err_count),
        .err_sticky(err_sticky),
        .ack_s1(ack_s1),
        .ack_s2(ack_s2),
        .data_dst(data_dst),
        .valid(valid),
        .ack(ack),
        .rx_count(rx_count),
        .hop_count(hop_count),
        .req_s1(req_s1),
        .req_s2(req_s2)
    );

endmodule
