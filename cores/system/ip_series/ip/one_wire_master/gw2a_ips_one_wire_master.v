// ---------------------------------------------------------------------------
// gw2a_ips_one_wire_master : packaged, licensable wrapper for the ips_one_wire_master core.
// Family iface.  1-Wire master with reset/presence, slot timing generation and sampling, CRC8 over 9-byte scratchpad
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_one_wire_master #(
    parameter RST_LOW = 6,
    parameter PRE_SMP = 8,
    parameter PRE_END = 12,
    parameter RD_LOW = 2,
    parameter RD_SMP = 3,
    parameter W1_LOW = 2,
    parameter W0_LOW = 6,
    parameter SLOT_END = 5,
    parameter CRC_POLY = 8'h8C,
    parameter CRC_BYTES = 9
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire ow_i,
    input wire [1:0] cmd,
    input wire cmd_valid,
    input wire [7:0] wdata,
    input wire crc_en,
    input wire crc_end,
    output wire ow_oe,
    output wire done,
    output wire [2:0] state,
    output wire [5:0] tc,
    output wire [2:0] bit_idx,
    output wire [7:0] rx_word,
    output wire [7:0] tx_word,
    output wire [7:0] crc,
    output wire [3:0] byte_count,
    output wire presence,
    output wire nopre_sticky,
    output wire crc_sticky,
    output wire len_sticky,
    output wire busy_sticky,
    output wire bad_cmd_sticky,
    output wire [3:0] rst_count,
    output wire [3:0] crc_count,
    output wire [3:0] err_count
);

    ips_one_wire_master #(
        .RST_LOW(RST_LOW),
        .PRE_SMP(PRE_SMP),
        .PRE_END(PRE_END),
        .RD_LOW(RD_LOW),
        .RD_SMP(RD_SMP),
        .W1_LOW(W1_LOW),
        .W0_LOW(W0_LOW),
        .SLOT_END(SLOT_END),
        .CRC_POLY(CRC_POLY),
        .CRC_BYTES(CRC_BYTES)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .ow_i(ow_i),
        .cmd(cmd),
        .cmd_valid(cmd_valid),
        .wdata(wdata),
        .crc_en(crc_en),
        .crc_end(crc_end),
        .ow_oe(ow_oe),
        .done(done),
        .state(state),
        .tc(tc),
        .bit_idx(bit_idx),
        .rx_word(rx_word),
        .tx_word(tx_word),
        .crc(crc),
        .byte_count(byte_count),
        .presence(presence),
        .nopre_sticky(nopre_sticky),
        .crc_sticky(crc_sticky),
        .len_sticky(len_sticky),
        .busy_sticky(busy_sticky),
        .bad_cmd_sticky(bad_cmd_sticky),
        .rst_count(rst_count),
        .crc_count(crc_count),
        .err_count(err_count)
    );

endmodule
