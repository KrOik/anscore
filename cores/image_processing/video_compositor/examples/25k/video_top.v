// Supplementary UART/debug binding. No display PHY or hard-user-JTAG claim.
`ifndef VIDEO_BUILD_ID
`define VIDEO_BUILD_ID 64'd0
`endif
module video_top #(parameter BIT_CYCLES=434)(
 input wire clk,uart_rx,output wire uart_tx,output reg [7:0] probe_out
);
reg [15:0] por=0;
always @(posedge clk)if(!(&por))por<=por+1'b1;
wire rst_n=&por;
wire [7:0] rx_data,tx_data,addr,probe;
wire rx_valid,rx_error,tx_valid,tx_ready,qv,qw,qr,pv,pe,pr;
wire [31:0] qd,pd;
sys_uart_rx #(.BIT_CYCLES(BIT_CYCLES)) receiver(clk,rst_n,uart_rx,rx_data,rx_valid,rx_error);
sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) transmitter(clk,rst_n,tx_data,tx_valid,tx_ready,uart_tx);
uart_csr_transport transport(clk,rst_n,rx_data,rx_valid,rx_error,tx_data,tx_valid,tx_ready,qv,qw,addr,qd,qr,pv,pd,pe,pr);
video_uart_control #(.BUILD_ID(`VIDEO_BUILD_ID)) control(clk,rst_n,qv,qw,addr,qd,qr,pv,pe,pd,pr,probe);
always @(posedge clk)if(!rst_n)probe_out<=0;else probe_out<=probe;
endmodule
