// Legacy output-layer and complete convolution-layer selftests (units 11/12).
module cnn_output_legacy_board(input wire clk, output wire uart_tx, output wire dbg_uart);
top #(.UNIT_EN(16'h1800)) core(.clk(clk),.uart_tx_pin(uart_tx),.status_pass(),.status_fail());
assign dbg_uart=uart_tx;
endmodule
