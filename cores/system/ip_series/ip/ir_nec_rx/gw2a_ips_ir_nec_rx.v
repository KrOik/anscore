// ---------------------------------------------------------------------------
// gw2a_ips_ir_nec_rx : packaged, licensable wrapper for the ips_ir_nec_rx core.
// Family iface.  NEC infrared receiver: leader/carrier timing validator, 32-bit frame with repeat code and command CRC
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_ir_nec_rx #(
    parameter TICK_LEAD = 48,
    parameter LEAD_SP = 24,
    parameter REPEAT_SP = 12,
    parameter BIT0_SP = 6,
    parameter BIT1_SP = 12,
    parameter TOL = 2
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire ir_in,
    output wire [31:0] rx_word,
    output wire [7:0] addr,
    output wire [7:0] cmd,
    output wire frame_valid,
    output wire repeat_valid,
    output wire [2:0] state,
    output wire [5:0] bit_index,
    output wire [5:0] width,
    output wire timing_sticky,
    output wire crc_sticky,
    output wire [7:0] timing_count,
    output wire [7:0] crc_count,
    output wire [7:0] frame_count,
    output wire [7:0] repeat_count
);

    ips_ir_nec_rx #(
        .TICK_LEAD(TICK_LEAD),
        .LEAD_SP(LEAD_SP),
        .REPEAT_SP(REPEAT_SP),
        .BIT0_SP(BIT0_SP),
        .BIT1_SP(BIT1_SP),
        .TOL(TOL)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .ir_in(ir_in),
        .rx_word(rx_word),
        .addr(addr),
        .cmd(cmd),
        .frame_valid(frame_valid),
        .repeat_valid(repeat_valid),
        .state(state),
        .bit_index(bit_index),
        .width(width),
        .timing_sticky(timing_sticky),
        .crc_sticky(crc_sticky),
        .timing_count(timing_count),
        .crc_count(crc_count),
        .frame_count(frame_count),
        .repeat_count(repeat_count)
    );

endmodule
