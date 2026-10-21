// ---------------------------------------------------------------------------
// gw2a_ips_i2s_tx_master : packaged, licensable wrapper for the ips_i2s_tx_master core.
// Family iface.  I2S stereo transmit master with programmable BCLK divider and right-justified or standard alignment
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_i2s_tx_master #(
    parameter WORD_W = 16,
    parameter SLOT_B = 32,
    parameter BCLK_DIV = 4,
    parameter ALIGN = 1,
    parameter UNDER_MAX = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire ch_valid,
    input wire signed [WORD_W-1:0] ch_l,
    input wire signed [WORD_W-1:0] ch_r,
    output wire sclk,
    output wire lrclk,
    output wire sd,
    output wire fresh_l,
    output wire fresh_r,
    output wire [6:0] bit_idx,
    output wire [3:0] div_idx,
    output wire [7:0] word_count,
    output wire [7:0] under_count,
    output wire underflow_sticky
);

    ips_i2s_tx_master #(
        .WORD_W(WORD_W),
        .SLOT_B(SLOT_B),
        .BCLK_DIV(BCLK_DIV),
        .ALIGN(ALIGN),
        .UNDER_MAX(UNDER_MAX)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .ch_valid(ch_valid),
        .ch_l(ch_l),
        .ch_r(ch_r),
        .sclk(sclk),
        .lrclk(lrclk),
        .sd(sd),
        .fresh_l(fresh_l),
        .fresh_r(fresh_r),
        .bit_idx(bit_idx),
        .div_idx(div_idx),
        .word_count(word_count),
        .under_count(under_count),
        .underflow_sticky(underflow_sticky)
    );

endmodule
