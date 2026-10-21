// ALT1, block index 0..31, error byte, 256 consecutive raw lookup outputs.
// Each block is acquired at clk_en=1; UART transfer occurs between blocks.
module activation_lut_rate_board #(parameter ROM_STYLE="auto", UART_BAUD=115200)(
 input wire clk,output wire uart_tx,output wire dbg_uart);
reg [12:0] reset_count=0;
wire rst_n=reset_count[12];
always @(posedge clk) if(!rst_n) reset_count<=reset_count+1'b1;
localparam RUN=0,PREPARE=1,SEND=2,ACK=3;
reg [1:0] state;
reg [4:0] block_index;
reg [8:0] issued,received,byte_index;
reg error;
wire input_valid=rst_n && state==RUN && issued<256;
wire output_valid;
wire [7:0] value;
activation_lut #(.ROM_STYLE(ROM_STYLE)) core(.clk(clk),.in_valid(input_valid),
 .val_in({block_index,issued[7:0]}),.out_valid(output_valid),.confidence_out(value));
reg [7:0] results[0:255];
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready,tx_busy;
uart_tx #(.BAUD_RATE(UART_BAUD)) uart(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),
 .tx_data_valid(tx_valid),.tx_data_ready(tx_ready),.tx_busy(tx_busy),.tx_pin(dbg_uart));
assign uart_tx=dbg_uart;
wire [7:0] payload_index=byte_index-6;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=RUN;block_index<=0;issued<=0;received<=0;byte_index<=0;error<=0;tx_valid<=0;tx_data<=0;
 end else case(state)
  RUN: begin
   if(input_valid) issued<=issued+1'b1;
   if(output_valid) begin
    if(received<256) results[received[7:0]]<=value;else error<=1;
    received<=received+1'b1;
    if(issued!=received+1'b1) error<=1;
   end
   if(received==256) begin
    if(output_valid || issued!=256) error<=1;
    byte_index<=0;state<=PREPARE;
   end
  end
  PREPARE: begin
   case(byte_index)
    0:tx_data<=8'h41;1:tx_data<=8'h4c;2:tx_data<=8'h54;3:tx_data<=8'h31;
    4:tx_data<={3'b0,block_index};5:tx_data<={7'b0,error};
    default:tx_data<=results[payload_index];
   endcase
   state<=SEND;
  end
  SEND: if(tx_ready) begin tx_valid<=1;state<=ACK;end
  ACK: if(tx_busy) begin
   tx_valid<=0;
   if(byte_index==261) begin
    block_index<=block_index+1'b1;issued<=0;received<=0;error<=0;state<=RUN;
   end else begin byte_index<=byte_index+1'b1;state<=PREPARE;end
  end
 endcase
end
endmodule
