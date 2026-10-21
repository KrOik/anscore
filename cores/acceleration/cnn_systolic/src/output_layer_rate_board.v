// 27 MHz / clk_en=1 validation of CPO=1, CPI=3, PAGES pages and two columns.
// Frame: "COL1", output count, timing/count error, 8 packed 32-bit outputs BE.
module output_layer_rate_board #(parameter PAGES=2)
 (input wire clk, output wire uart_tx, output wire dbg_uart);
reg [12:0] reset_count=0;
wire rst_n=reset_count[12];
always @(posedge clk) if(!rst_n) reset_count<=reset_count+1'b1;
localparam RUN=0, PREPARE=1, SEND=2, ACK=3;
reg [1:0] state;
reg [5:0] tick,byte_index;
reg [3:0] count;
reg error;
reg [PAGES*32-1:0] inputs[0:63];
initial $readmemh("accumulation_input.mem",inputs);
wire [31:0] final_out;
wire output_valid,new_line_out_1;
output_layer #(.PE_PAGE_NUM(PAGES),.PE_COL_NUM(2),.PE_ROW_NUM(1),
 .PE_OUT_WIDTH(16),.BIAS_WIDTH(16),.ACC_WIDTH(24),.SHIFT_KEY(0),
 .OUT_WIDTH(16),.CYCLE_PERIOD_OUT(1),.CYCLE_PERIOD_IN(3),.IMG_COL(8),
 .WITH_RELU(0),.BIAS_FILE("accumulation_bias.mem")) core(
 .clk(clk),.clk_en(state==RUN),.rst_n(rst_n),.new_line_in(tick==0),
 .page_y_out(inputs[tick]),.final_out(final_out),
 .output_valid(output_valid),.new_line_out_1(new_line_out_1));
reg [31:0] results[0:7];
reg [7:0] tx_data;
reg tx_valid;
wire tx_ready,tx_busy;
uart_tx uart(.clk(clk),.rst_n(rst_n),.tx_data(tx_data),.tx_data_valid(tx_valid),
 .tx_data_ready(tx_ready),.tx_busy(tx_busy),.tx_pin(dbg_uart));
assign uart_tx=dbg_uart;
wire [5:0] payload_index=byte_index-6;
wire [31:0] word=results[payload_index[4:2]];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin state<=RUN; tick<=0; byte_index<=0; count<=0; error<=0; tx_data<=0; tx_valid<=0; end
 else case(state)
  RUN: begin
   if(output_valid) begin
    if(count>=8) error<=1;
    else begin
     results[count[2:0]]<=final_out;
     if(tick!=(13+count+(count<<1))) error<=1;
    end
    count<=count+1'b1;
   end
   if(tick==47) begin
    if(count!=8) error<=1;
    state<=PREPARE; byte_index<=0;
   end else tick<=tick+1'b1;
  end
  PREPARE: begin
   case(byte_index)
    0:tx_data<=8'h43; 1:tx_data<=8'h4f; 2:tx_data<=8'h4c; 3:tx_data<=8'h31;
    4:tx_data<={4'd0,count}; 5:tx_data<={7'd0,error};
    default: case(payload_index[1:0])
     0:tx_data<=word[31:24]; 1:tx_data<=word[23:16];
     2:tx_data<=word[15:8]; 3:tx_data<=word[7:0];
    endcase
   endcase
   state<=SEND;
  end
  SEND: if(tx_ready) begin tx_valid<=1; state<=ACK; end
  ACK: if(tx_busy) begin
   tx_valid<=0;
   if(byte_index==37) begin state<=RUN; tick<=0; count<=0; error<=0; end
   else begin byte_index<=byte_index+1'b1; state<=PREPARE; end
  end
 endcase
end
endmodule
