// Original input-layer and convolution-layer UART contracts (units 10/12).
module cnn_input_legacy_board(input wire clk,output wire uart_tx,output wire dbg_uart);
top #(.UNIT_EN(16'h1400)) core(.clk(clk),.uart_tx_pin(uart_tx),.status_pass(),.status_fail());
assign dbg_uart=uart_tx;
endmodule
