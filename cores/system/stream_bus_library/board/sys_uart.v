// Board support, not counted as a catalog IP. 50MHz, 115200 baud, 8N1.
module sys_uart_tx #(parameter BIT_CYCLES=434)(input wire clk,rst_n,
 input wire [7:0] data,input wire valid,output wire ready,output wire tx);
reg [9:0] shift; reg [15:0] timer; reg [3:0] bits;
assign ready=(bits==0); assign tx=(bits==0)?1'b1:shift[0];
always @(posedge clk or negedge rst_n)
 if(!rst_n) begin shift<=1023; timer<=0; bits<=0; end
 else if(bits==0) begin if(valid) begin shift<={1'b1,data,1'b0}; timer<=BIT_CYCLES-1; bits<=10; end end
 else if(timer==0) begin timer<=BIT_CYCLES-1; shift<={1'b1,shift[9:1]}; bits<=bits-1'b1; end
 else timer<=timer-1'b1;
endmodule

module sys_uart_rx #(parameter BIT_CYCLES=434)(input wire clk,rst_n,rx,
 output reg [7:0] data,output reg valid,output reg framing_error);
(* async_reg="true" *) reg rx1,rx2;
reg [1:0] state; reg [15:0] timer; reg [2:0] bit_index; reg [7:0] shift;
always @(posedge clk or negedge rst_n)
 if(!rst_n) begin rx1<=1; rx2<=1; state<=0; timer<=0; bit_index<=0; shift<=0; data<=0; valid<=0; framing_error<=0; end
 else begin
  rx1<=rx; rx2<=rx1; valid<=0; framing_error<=0;
  case(state)
   0: if(!rx2) begin state<=1; timer<=BIT_CYCLES/2-1; end
   1: if(timer!=0) timer<=timer-1'b1;
      else if(rx2) state<=0;
      else begin state<=2; timer<=BIT_CYCLES-1; bit_index<=0; end
   2: if(timer!=0) timer<=timer-1'b1;
      else begin shift[bit_index]<=rx2; timer<=BIT_CYCLES-1;
       if(bit_index==7) state<=3; else bit_index<=bit_index+1'b1; end
   3: if(timer!=0) timer<=timer-1'b1;
      else begin state<=0; data<=shift; valid<=rx2; framing_error<=!rx2; end
  endcase
 end
endmodule
