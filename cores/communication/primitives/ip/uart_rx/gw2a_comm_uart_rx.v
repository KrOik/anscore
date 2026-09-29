// ============================================================================
// gw2a_comm_uart_rx -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: uart_rx  (src/uart_rx.v)
// Board-validated: selftest unit 0 (URX), digest 6BC47DCE,
//   evidence doc/board_uart_*.txt
// UART receiver: 8N1, oversampling FSM, framing-error flag.
// ============================================================================
module gw2a_comm_uart_rx #(
    parameter integer CLK_FRE   = 27,      // clk frequency in MHz
    parameter integer BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clk_en,              // step enable; tie 1 for full rate
    input  wire       rx_pin,
    output wire [7:0] rx_data,
    output wire       rx_valid,
    input  wire       rx_ack,
    output wire       framing_err
);

    uart_rx #(
        .CLK_FRE(CLK_FRE),
        .BAUD_RATE(BAUD_RATE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .rx_pin(rx_pin),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ack(rx_ack),
        .framing_err(framing_err)
    );

endmodule
