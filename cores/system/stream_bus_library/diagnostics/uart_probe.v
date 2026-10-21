// Uncounted physical UART diagnostic: reports real pin edges/decoded bytes.
module sys_uart_probe(input wire clk,uart_rx,output wire uart_tx,output wire [1:0] led);
reg [15:0] por=0; always @(posedge clk) if(!(&por)) por<=por+1'b1;
wire rst_n=&por;
wire [7:0] rx_data; wire rx_valid,rx_error;
sys_uart_rx receiver(clk,rst_n,uart_rx,rx_data,rx_valid,rx_error);
reg [7:0] received,errors,last,edges; reg pin;
reg [22:0] pace; reg sending; reg [3:0] index; reg [63:0] report;
wire ready; wire [7:0] tx_data=report[index*8+:8];
sys_uart_tx transmitter(clk,rst_n,tx_data,sending,ready,uart_tx);
assign led={uart_rx,sending};
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin received<=0; errors<=0; last<=0; edges<=0; pin<=1; pace<=0; sending<=0; index<=0; report<=0; end
 else begin
  pin<=uart_rx;
  if(pin!=uart_rx) edges<=edges+1'b1;
  if(rx_valid) begin received<=received+1'b1; last<=rx_data; end
  if(rx_error) errors<=errors+1'b1;
  if(!sending) begin
   if(pace==2500000) begin pace<=0; index<=0; sending<=1; report<={8'h0a,8'h0d,7'd0,uart_rx,edges,errors,received,last,8'h50}; end
   else pace<=pace+1'b1;
  end else if(ready) begin if(index==7) sending<=0; else index<=index+1'b1; end
 end
end
endmodule
