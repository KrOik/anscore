// UART control is a supplementary path; this is not hard user-JTAG binding.
module isp_top #(parameter BIT_CYCLES=434)(
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
 uart_csr_transport transport(clk,rst_n,rx_data,rx_valid,rx_error,tx_data,tx_valid,tx_ready,
 qv,qw,addr,qd,qr,pv,pd,pe,pr);
 isp_control control(.clk(clk),.rst_n(rst_n),.req_valid(qv),.req_write(qw),.req_addr(addr),.req_data(qd),.req_strobe(4'hf),
 .req_ready(qr),.resp_valid(pv),.resp_error(pe),.resp_data(pd),.resp_ready(pr),.probe(probe_out),
 .out_valid(),.out_ready(1'b1),.out_data(),.out_sof(),.out_eol(),.out_eof(),.out_frame_id());
endmodule
