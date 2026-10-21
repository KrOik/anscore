// 50 MHz / 115200 baud, 8N1. Separate reusable board support, not counted IP.
module prod_uart_tx #(parameter BIT_CYCLES=434)(
 input wire clk,rst_n, input wire [7:0] data, input wire valid,
 output wire ready, output wire tx
);
reg [9:0] shift;
reg [8:0] timer;
reg [3:0] bits;
assign ready=(bits==0);
assign tx=(bits==0)?1'b1:shift[0];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin shift<=1023; timer<=0; bits<=0; end
 else if(bits==0) begin
   if(valid) begin shift<={1'b1,data,1'b0}; timer<=BIT_CYCLES-1; bits<=10; end
 end else if(timer==0) begin
   timer<=BIT_CYCLES-1; shift<={1'b1,shift[9:1]}; bits<=bits-1'b1;
 end else timer<=timer-1'b1;
end
endmodule
