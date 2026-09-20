// Board-only regression wrapper: 27 MHz, CPI=1/CPO=2, two input bubbles/pixel.
// UART frame: CIG1, output count (80), error flag, 80 two-byte output words.
module input_layer_gap_board(input wire clk, output wire uart_tx,output wire dbg_uart);
reg [12:0] reset_count=0;
wire rst_n=reset_count[12];
always @(posedge clk) if(!rst_n) reset_count<=reset_count+1'b1;
localparam RESET=0,RUN=1,PREPARE=2,SEND=3,ACK=4;
reg [2:0] state;
reg [3:0] reset_hold;
reg [8:0] tick;
reg [7:0] count,byte_index;
reg error;
reg [17:0] stimulus[0:511];
initial $readmemh("input_gap_stimulus.mem",stimulus);
wire [17:0] beat=stimulus[tick];
wire [15:0] y_out;
wire output_valid,new_line_out_1;
lprnet_layer_direct #(.PE_PAGE_NUM(2),.PE_ROW_NUM(9),.PE_COL_NUM(2),
 .KERNEL_COL(3),.KERNEL_ROW(3),.MAX_POOL(0),.WITH_RELU(1),
 .DATA_WIDTH(8),.WEIGHT_WIDTH(8),.CYCLE_PERIOD_IN(1),.CYCLE_PERIOD_OUT(2),
 .IMG_COL(8),.IMG_ROW(6),.STEP_ROW(1),.STEP_COL(1),.USE_DSP_PE("no"),
 .SHIFT_KEY(4),.BIAS_WIDTH(16),.OUT_WIDTH(8),
 .WEIGHT_FILE0("weight_layer9_page0.mem"),.WEIGHT_FILE1("weight_layer9_page1.mem"),
 .BIAS_FILE("bias_layer9.mem")) core(
 .clk(clk),.clk_en(state==RUN || state==RESET),.rst_n(rst_n && state!=RESET),
 .new_line_input_1(beat[17] && state==RUN),.data_input_valid(beat[16] && state==RUN),
 .data_input(beat[15:0]),.y_out(y_out),.output_valid(output_valid),.new_line_out_1(new_line_out_1));
reg [15:0] results[0:79];
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready,tx_busy;
uart_tx uart(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),
 .tx_data_ready(tx_ready),.tx_busy(tx_busy),.tx_pin(dbg_uart));
assign uart_tx=dbg_uart;
wire [7:0] payload=byte_index-6;
wire [15:0] word=results[payload[7:1]];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  state<=RESET;reset_hold<=0;tick<=0;count<=0;byte_index<=0;error<=0;tx_data<=0;tx_valid<=0;
 end else case(state)
  RESET: begin
   tick<=0;count<=0;error<=0;
   if(reset_hold==7) begin reset_hold<=0;state<=RUN;end
   else reset_hold<=reset_hold+1'b1;
  end
  RUN: begin
   if(output_valid) begin
    if(count<80) results[count]<=y_out; else error<=1;
    if(count!=255) count<=count+1'b1;
   end
   if(tick==511) begin
    if(count!=80 || output_valid) error<=1;
    state<=PREPARE;byte_index<=0;
   end else tick<=tick+1'b1;
  end
  PREPARE: begin
   case(byte_index)
    0:tx_data<=8'h43;1:tx_data<=8'h49;2:tx_data<=8'h47;3:tx_data<=8'h31;
    4:tx_data<=count;5:tx_data<={7'b0,error};
    default:tx_data<=payload[0] ? word[15:8] : word[7:0];
   endcase
   state<=SEND;
  end
  SEND: if(tx_ready) begin tx_valid<=1;state<=ACK;end
  ACK: if(tx_busy) begin
   tx_valid<=0;
   if(byte_index==165) state<=RESET;
   else begin byte_index<=byte_index+1'b1;state<=PREPARE;end
  end
 endcase
end
endmodule
