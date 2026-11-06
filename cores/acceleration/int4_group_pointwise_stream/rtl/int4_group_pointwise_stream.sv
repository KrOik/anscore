// SPDX-License-Identifier: Apache-2.0
// Resident grouped 1x1 convolution, pixel-at-a-time NHWC, optional GxR transpose.
module int4_group_pointwise_stream #(
 parameter GROUPS=2, MAX_IN_PER_GROUP=8, MAX_OUT_PER_GROUP=8,
 parameter MAX_PIXELS=4096, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_group,c_row,c_word,input wire [31:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,
 input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_pixels,cmd_in_per_group,cmd_out_per_group,
 input wire [7:0] cmd_x_zero,input wire cmd_shuffle,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output reg signed [7:0] m_data,
 output wire [15:0] m_pixel,m_channel,m_group,m_row,
 output wire m_last,output wire [TAG_W-1:0] m_tag,
 output reg m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output reg [1:0] rsp_error,
 output reg [31:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag,
 output wire busy
);
 generate if(GROUPS<1 || GROUPS>8 || MAX_IN_PER_GROUP<1 ||
  GROUPS*MAX_IN_PER_GROUP>1024 || MAX_OUT_PER_GROUP<1 ||
  GROUPS*MAX_OUT_PER_GROUP>64 || MAX_PIXELS<1 || MAX_PIXELS>4096 ||
  TAG_W<1 || TAG_W>32)begin:bad_parameters
  INT4_GROUP_POINTWISE_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate
 localparam WORDS=(MAX_IN_PER_GROUP+7)/8, ROWS=GROUPS*MAX_OUT_PER_GROUP;
 localparam GW=GROUPS<2?1:$clog2(GROUPS);
 localparam IW=MAX_IN_PER_GROUP<2?1:$clog2(MAX_IN_PER_GROUP+1);
 localparam OW=MAX_OUT_PER_GROUP<2?1:$clog2(MAX_OUT_PER_GROUP+1);
 localparam PW=MAX_PIXELS<2?1:$clog2(MAX_PIXELS+1);
 localparam WW=WORDS<2?1:$clog2(WORDS+1);
 localparam RW=ROWS<2?1:$clog2(ROWS);
 localparam WA=ROWS*WORDS<2?1:$clog2(ROWS*WORDS);
 localparam VA=GROUPS*MAX_IN_PER_GROUP<2?1:$clog2(GROUPS*MAX_IN_PER_GROUP);
 localparam IDLE=0,CONFIG_RSP=1,PRECHECK=2,COLLECT=3,META_READ=4,
  META_LOAD=5,READ_TERM=6,MAC=7,SCALE=8,Q_SEND=9,Q_WAIT=10,OUTPUT_ROW=11,DONE=12;
 reg [3:0] state;
 reg [31:0] weights[0:ROWS*WORDS-1];
 reg [60:0] metadata[0:ROWS-1];
 reg [7:0] vector_mem[0:GROUPS*MAX_IN_PER_GROUP-1];
 reg [ROWS*WORDS-1:0] word_valid;
 reg [ROWS-1:0] meta_valid;
 reg [GW-1:0] group_index,input_group,check_group;
 reg [IW-1:0] in_count,input_col,column;
 reg [OW-1:0] out_count,row_index,check_row;
 reg [WW-1:0] check_word;
 reg [PW-1:0] pixels,pixel_index;
 reg [6:0] output_index;
 reg [7:0] x_zero;
 reg shuffle;
 reg [TAG_W-1:0] tag;
 reg [60:0] meta_q;
 reg [31:0] weight_q;
 reg [7:0] x_q;
 reg [2:0] nibble_q;
 reg signed [39:0] accumulator;
 reg signed [56:0] scaled;
 wire [RW-1:0] row_addr=group_index*MAX_OUT_PER_GROUP+row_index;
 wire [RW-1:0] check_row_addr=check_group*MAX_OUT_PER_GROUP+check_row;
 wire [RW-1:0] config_row_addr=c_group*MAX_OUT_PER_GROUP+c_row;
 wire [WA-1:0] config_word_addr=config_row_addr*WORDS+c_word;
 wire [WA-1:0] check_word_addr=check_row_addr*WORDS+check_word;
 wire [WA-1:0] term_word_addr=row_addr*WORDS+(column>>3);
 wire [VA-1:0] term_x_addr=group_index*MAX_IN_PER_GROUP+column;
 wire [VA-1:0] input_addr=input_group*MAX_IN_PER_GROUP+input_col;
 wire signed [31:0] bias_q=meta_q[60:29];
 wire [15:0] scale_q=meta_q[28:13];
 wire [4:0] shift_q=meta_q[12:8];
 wire signed [7:0] zero_q=meta_q[7:0];
 wire signed [8:0] delta=$signed({1'b0,x_q})-$signed({1'b0,x_zero});
 wire signed [3:0] weight=$signed(weight_q[nibble_q*4+:4]);
 wire signed [12:0] product=delta*weight;
 wire signed [39:0] extended_product={{27{product[12]}},product};
 wire signed [56:0] scaled_product=accumulator*$signed({1'b0,scale_q});
 wire last_input=input_group==GROUPS-1 && input_col==in_count-1'b1;
 wire last_output=output_index==GROUPS*out_count-1'b1;
 wire final_pixel=pixel_index==pixels-1'b1;
 wire q_ready,q_valid,q_clip,q_inexact,q_tag;
 wire [15:0] q_data;
 wire signed [16:0] with_zero=$signed({q_data[15],q_data})+$signed({{9{zero_q[7]}},zero_q});
 // This already-committed quantizer is shared with the resident matrix IP.
 // Intermediate S16 saturation cannot move an eventual S8 value back in range.
 stream_requantize #(.IN_W(64),.OUT_W(16),.TAG_W(1)) quantizer(
  .clk(clk),.rst(rst),.s_valid(state==Q_SEND),.s_ready(q_ready),
  .s_data({{7{scaled[56]}},scaled}),.s_shift({2'b0,shift_q}),.s_tag(1'b0),
  .m_valid(q_valid),.m_ready(state==Q_WAIT),.m_data(q_data),
  .m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_tag)
 );
 assign c_ready=!rst && state==IDLE;
 assign c_rsp_valid=!rst && state==CONFIG_RSP;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign s_ready=!rst && state==COLLECT;
 assign m_valid=!rst && state==OUTPUT_ROW;
 assign m_pixel=pixel_index;assign m_channel=output_index;
 assign m_group=group_index;assign m_row=row_index;
 assign m_last=last_output && final_pixel;assign m_tag=tag;
 assign rsp_valid=!rst && state==DONE;assign rsp_tag=tag;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;word_valid<=0;meta_valid<=0;
   rsp_error<=0;rsp_outputs<=0;
   group_index<=0;input_group<=0;check_group<=0;
   in_count<=0;input_col<=0;column<=0;
   out_count<=0;row_index<=0;check_row<=0;check_word<=0;
   pixels<=0;pixel_index<=0;output_index<=0;
  end else case(state)
   IDLE:begin
    if(c_valid)begin
     c_error<=0;
     if(c_op==2)begin word_valid<=0;meta_valid<=0;end
     else if(c_op==3)c_error<=2;
     else if(c_group>=GROUPS || c_row>=MAX_OUT_PER_GROUP ||
        (c_op==0 && c_word>=WORDS))c_error<=1;
     else if(c_op==0)begin weights[config_word_addr]<=c_weights;word_valid[config_word_addr]<=1;end
     else begin metadata[config_row_addr]<={c_bias,c_scale,c_shift,c_zero};meta_valid[config_row_addr]<=1;end
     state<=CONFIG_RSP;
    end else if(cmd_valid)begin
     tag<=cmd_tag;rsp_error<=0;rsp_outputs<=0;
     pixel_index<=0;output_index<=0;group_index<=0;row_index<=0;
     input_group<=0;input_col<=0;check_group<=0;check_row<=0;check_word<=0;
     if(cmd_pixels==0 || cmd_pixels>MAX_PIXELS || cmd_in_per_group==0 ||
      cmd_in_per_group>MAX_IN_PER_GROUP || cmd_out_per_group==0 ||
      cmd_out_per_group>MAX_OUT_PER_GROUP)begin rsp_error<=1;state<=DONE;end
     else begin
      pixels<=cmd_pixels;in_count<=cmd_in_per_group;out_count<=cmd_out_per_group;
      x_zero<=cmd_x_zero;shuffle<=cmd_shuffle;state<=PRECHECK;
     end
    end
   end
   CONFIG_RSP:if(c_rsp_ready)state<=IDLE;
   PRECHECK:begin
    if(!meta_valid[check_row_addr] || !word_valid[check_word_addr])begin rsp_error<=2;state<=DONE;end
    else if(check_word==((in_count-1'b1)>>3))begin
     check_word<=0;
     if(check_row==out_count-1'b1)begin
      check_row<=0;
      if(check_group==GROUPS-1)state<=COLLECT;
      else check_group<=check_group+1'b1;
     end else check_row<=check_row+1'b1;
    end else check_word<=check_word+1'b1;
   end
   COLLECT:if(s_valid)begin
    if(s_last!=(last_input && final_pixel))begin rsp_error<=3;state<=DONE;end
    else begin
     vector_mem[input_addr]<=s_data;
     if(last_input)begin
      input_group<=0;input_col<=0;group_index<=0;row_index<=0;output_index<=0;state<=META_READ;
     end else if(input_col==in_count-1'b1)begin input_col<=0;input_group<=input_group+1'b1;end
     else input_col<=input_col+1'b1;
    end
   end
   META_READ:begin meta_q<=metadata[row_addr];state<=META_LOAD;end
   META_LOAD:begin accumulator<={{8{bias_q[31]}},bias_q};column<=0;state<=READ_TERM;end
   READ_TERM:begin weight_q<=weights[term_word_addr];x_q<=vector_mem[term_x_addr];nibble_q<=column;state<=MAC;end
   MAC:begin
    accumulator<=accumulator+extended_product;
    if(column==in_count-1'b1)state<=SCALE;
    else begin column<=column+1'b1;state<=READ_TERM;end
   end
   SCALE:begin scaled<=scaled_product;state<=Q_SEND;end
   Q_SEND:if(q_ready)state<=Q_WAIT;
   Q_WAIT:if(q_valid)begin
    m_data<=with_zero>127?8'sd127:with_zero< -128?8'sh80:with_zero[7:0];
    m_clip<=q_clip || with_zero>127 || with_zero< -128;
    m_inexact<=q_inexact;state<=OUTPUT_ROW;
   end
   OUTPUT_ROW:if(m_ready)begin
    rsp_outputs<=rsp_outputs+1'b1;
    if(last_output)begin
     if(final_pixel)state<=DONE;
     else begin pixel_index<=pixel_index+1'b1;input_group<=0;input_col<=0;state<=COLLECT;end
    end else begin
     output_index<=output_index+1'b1;
     if(shuffle)begin
      if(group_index==GROUPS-1)begin group_index<=0;row_index<=row_index+1'b1;end
      else group_index<=group_index+1'b1;
     end else begin
      if(row_index==out_count-1'b1)begin row_index<=0;group_index<=group_index+1'b1;end
      else row_index<=row_index+1'b1;
     end
     state<=META_READ;
    end
   end
   DONE:if(rsp_ready)state<=IDLE;
  endcase
 end
endmodule
