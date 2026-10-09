// ---------------------------------------------------------------------------
// gw2a_ips_i2s_rx_slave : packaged, licensable wrapper for the ips_i2s_rx_slave core.
// Family iface.  I2S stereo receive slave with word-select edge detect, valid framing and dropped-frame counter
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_i2s_rx_slave #(
    parameter WORD_W = 16,
    parameter SLOT_B = 17,
    parameter TIMEOUT_T = 40,
    parameter DROP_MAX = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire sclk_i,
    input wire lrclk_i,
    input wire sd_i,
    input wire rx_ready,
    output wire signed [WORD_W-1:0] rx_word,
    output wire rx_valid,
    output wire rx_chan,
    output wire [5:0] bit_count,
    output wire [7:0] cap_count,
    output wire [7:0] drop_count,
    output wire [3:0] slip_count,
    output wire [3:0] lost_count,
    output wire slip_sticky,
    output wire lost_sticky,
    output wire sclk_q,
    output wire lrclk_q
);

    ips_i2s_rx_slave #(
        .WORD_W(WORD_W),
        .SLOT_B(SLOT_B),
        .TIMEOUT_T(TIMEOUT_T),
        .DROP_MAX(DROP_MAX)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .sclk_i(sclk_i),
        .lrclk_i(lrclk_i),
        .sd_i(sd_i),
        .rx_ready(rx_ready),
        .rx_word(rx_word),
        .rx_valid(rx_valid),
        .rx_chan(rx_chan),
        .bit_count(bit_count),
        .cap_count(cap_count),
        .drop_count(drop_count),
        .slip_count(slip_count),
        .lost_count(lost_count),
        .slip_sticky(slip_sticky),
        .lost_sticky(lost_sticky),
        .sclk_q(sclk_q),
        .lrclk_q(lrclk_q)
    );

endmodule
