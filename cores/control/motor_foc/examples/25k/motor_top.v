// Controlled digital CSR binding. Probes are not motor power-stage outputs.
// Supplementary UART transport; mandatory runtime hard-user-JTAG is separate.
`ifndef MOTOR_BUILD_ID
`define MOTOR_BUILD_ID 64'd0
`endif
module motor_top #(parameter BIT_CYCLES=434)(
 input wire clk,uart_rx,output wire uart_tx,output reg [7:0] probe_out
);
reg [15:0] por=0;
always @(posedge clk)if(!(&por))por<=por+1'b1;
wire rst_n=&por;
reg [15:0] monitor_divider;
always @(posedge clk)if(!rst_n)monitor_divider<=0;else monitor_divider<=monitor_divider+1'b1;
wire [7:0] rx_data,tx_data,addr;
wire rx_valid,rx_error,tx_valid,tx_ready,qv,qw,qr,pv,pe,pr;
wire [31:0] qd,pd;wire [2:0] hi,lo;wire applied;
sys_uart_rx #(.BIT_CYCLES(BIT_CYCLES)) receiver(clk,rst_n,uart_rx,rx_data,rx_valid,rx_error);
sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) transmitter(clk,rst_n,tx_data,tx_valid,tx_ready,uart_tx);
uart_csr_transport transport(clk,rst_n,rx_data,rx_valid,rx_error,tx_data,tx_valid,tx_ready,
 qv,qw,addr,qd,qr,pv,pd,pe,pr);
// No external motor/encoder pins assigned: shunt samples/electrical angle are
// CSR supplied; raw encoder/index fixed0,raw external fault inactive.
motor_control_csr #(.BUILD_ID(`MOTOR_BUILD_ID)) control(clk,rst_n,1'b1,monitor_divider==0,
 1'b0,1'b0,1'b0,1'b0,qv,qw,addr,qd,4'hf,qr,pv,pe,pd,pr,hi,lo,applied);
// Exactly one clock observation delay, isolated from the functional path.
always @(posedge clk)if(!rst_n)probe_out<=0;
else probe_out<={applied,uart_tx,lo,hi};
endmodule
