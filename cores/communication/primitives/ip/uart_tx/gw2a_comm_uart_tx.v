// ============================================================================
// gw2a_comm_uart_tx -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: uart_tx  (src/uart_tx.v, reused verbatim from cnn_systolic_20k)
// Board-validated: drives the COMM5 UART report on pin M11,
//   evidence doc/board_uart_*.txt
// UART transmitter: 8N1, valid/ready handshake, busy flag.
// ============================================================================
module gw2a_comm_uart_tx #(
    parameter integer CLK_FRE   = 27,      // clk frequency in MHz
    parameter integer BAUD_RATE = 115200
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_data_valid,
    output wire       tx_data_ready,
    output wire       tx_pin,
    output wire       tx_busy
);

    uart_tx #(
        .CLK_FRE(CLK_FRE),
        .BAUD_RATE(BAUD_RATE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .tx_data(tx_data),
        .tx_data_valid(tx_data_valid),
        .tx_data_ready(tx_data_ready),
        .tx_pin(tx_pin),
        .tx_busy(tx_busy)
    );

endmodule
