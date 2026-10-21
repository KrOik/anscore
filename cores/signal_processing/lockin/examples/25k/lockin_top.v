// Supplementary UART board binding; mandatory hard user-JTAG remains separate.
`ifndef LOCKIN_BUILD_ID
`define LOCKIN_BUILD_ID 64'd0
`endif
module lockin_top #(parameter BIT_CYCLES=434)(
 input wire clk,uart_rx,output wire uart_tx,output wire [7:0] probe_out
);
 reg [15:0] por=0;
 always @(posedge clk)if(!(&por))por<=por+1'b1;
 wire rst_n=&por;
 wire [7:0] rx_data,tx_data,addr;
 wire rx_valid,rx_error,tx_valid,tx_ready,qv,qw,qr,pv,pe,pr;
 wire [31:0] qd,pd;
 sys_uart_rx #(.BIT_CYCLES(BIT_CYCLES)) receiver(clk,rst_n,uart_rx,rx_data,rx_valid,rx_error);
 sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) transmitter(clk,rst_n,tx_data,tx_valid,tx_ready,uart_tx);
 uart_csr_transport transport(clk,rst_n,rx_data,rx_valid,rx_error,tx_data,tx_valid,tx_ready,qv,qw,addr,qd,qr,pv,pd,pe,pr);
 lockin_control #(.BUILD_ID(`LOCKIN_BUILD_ID)) control(clk,rst_n,qv,qw,addr,qd,4'hf,qr,pv,pe,pd,pr,probe_out);
endmodule
