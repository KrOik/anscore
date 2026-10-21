// Independent physical UART diagnostic. Transmits 0x55 every 524288 clocks.
module uart_diagnostic_top #(parameter BIT_CYCLES=434)(
 input wire clk,uart_rx,output wire uart_tx,output reg [7:0] probe_out
);
 reg [15:0] por=0;
 reg [19:0] ticks=0;
 always @(posedge clk) begin
  if(!(&por)) por<=por+1'b1;
  ticks<=ticks+1'b1;
 end
 wire rst_n=&por;
 wire tx_valid=rst_n&&(ticks[18:0]==0);
 wire tx_ready;
 wire [7:0] rx_data;
 wire rx_valid,rx_error;
 reg rx_toggle,tx_toggle,sticky_error;
 sys_uart_tx #(.BIT_CYCLES(BIT_CYCLES)) transmitter(clk,rst_n,8'h55,tx_valid,tx_ready,uart_tx);
 sys_uart_rx #(.BIT_CYCLES(BIT_CYCLES)) receiver(clk,rst_n,uart_rx,rx_data,rx_valid,rx_error);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin rx_toggle<=0; tx_toggle<=0; sticky_error<=0; probe_out<=0; end
  else begin
   if(rx_valid) rx_toggle<=~rx_toggle;
   if(tx_valid&&tx_ready) tx_toggle<=~tx_toggle;
   if(rx_error) sticky_error<=1;
   probe_out<={rst_n,ticks[18],tx_toggle,rx_data[0],sticky_error,rx_toggle,uart_tx,uart_rx};
  end
 end
endmodule
