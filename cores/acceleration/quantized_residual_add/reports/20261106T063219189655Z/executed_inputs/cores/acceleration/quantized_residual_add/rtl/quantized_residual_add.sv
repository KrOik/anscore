// SPDX-License-Identifier: Apache-2.0
// Paired affine U8 residual fusion; one rounding after the exact scaled sum.
module quantized_residual_add #(
 parameter MAX_CHANNELS=16, MAX_PIXELS=256, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_channel,input wire [15:0] c_scale_a,c_scale_b,
 input wire [4:0] c_shift,input wire [7:0] c_zero_a,c_zero_b,
 input wire signed [7:0] c_zero_out,c_min,c_max,
 output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_pixels,cmd_channels,input wire [TAG_W-1:0] cmd_tag,
 input wire a_valid,output wire a_ready,input wire [7:0] a_data,input wire a_last,
 input wire b_valid,output wire b_ready,input wire [7:0] b_data,input wire b_last,
 output wire m_valid,input wire m_ready,output reg signed [7:0] m_data,
 output wire [15:0] m_pixel,m_channel,output wire m_last,
 output wire [TAG_W-1:0] m_tag,output reg m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output reg [1:0] rsp_error,
 output reg [31:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag,
 output reg rsp_bad_a,rsp_bad_b,output wire busy
);
 generate if(MAX_CHANNELS<1 || MAX_CHANNELS>64 || MAX_PIXELS<1 || MAX_PIXELS>4096 || TAG_W<1 || TAG_W>32)begin:bad_parameters
  QUANTIZED_RESIDUAL_ADD_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate
 localparam CW=MAX_CHANNELS<2?1:$clog2(MAX_CHANNELS);
 localparam IDLE=0,CONFIG_RSP=1,PRECHECK=2,COLLECT=3,META_READ=4,
            MUL_A=5,MUL_B=6,SUM=7,Q_SEND=8,Q_WAIT=9,OUTPUT_ROW=10,DONE=11;
 reg [3:0] state;
 reg [MAX_CHANNELS-1:0] configured;
 reg [76:0] metadata[0:MAX_CHANNELS-1];
 reg [76:0] meta_q;
 reg [15:0] pixels,channels,pixel,channel,check_channel;
 reg [TAG_W-1:0] tag;
 reg a_full,b_full,al,bl;
 reg [7:0] av,bv;
 reg signed [25:0] product_a,product_b;
 reg signed [26:0] scaled_sum;
 wire [15:0] scale_a,scale_b;
 wire [4:0] shift;
 wire [7:0] zero_a,zero_b;
 wire signed [7:0] zero_out,act_min,act_max;
 assign {scale_a,scale_b,shift,zero_a,zero_b,zero_out,act_min,act_max}=meta_q;
 wire expected_last=pixel==pixels-1'b1 && channel==channels-1'b1;
 wire signed [8:0] delta_a=$signed({1'b0,av})-$signed({1'b0,zero_a});
 wire signed [8:0] delta_b=$signed({1'b0,bv})-$signed({1'b0,zero_b});
 // The two products use one explicitly selected 9x17 signed multiplier.
 wire signed [8:0] multiplier_x=state==MUL_B?delta_b:delta_a;
 wire signed [16:0] multiplier_y=$signed({1'b0,(state==MUL_B?scale_b:scale_a)});
 wire signed [25:0] product=multiplier_x*multiplier_y;
 wire q_ready,q_valid,q_clip,q_inexact;
 wire [27:0] q_data;
 wire q_tag;
 wire signed [28:0] with_zero=$signed({q_data[27],q_data})+$signed({{21{zero_out[7]}},zero_out});
 wire signed [28:0] minimum={{21{act_min[7]}},act_min};
 wire signed [28:0] maximum={{21{act_max[7]}},act_max};
 // Widened output prevents early saturation before adding the output zero point.
 stream_requantize #(.IN_W(27),.OUT_W(28),.TAG_W(1)) quantizer(
  .clk(clk),.rst(rst),.s_valid(state==Q_SEND),.s_ready(q_ready),
  .s_data(scaled_sum),.s_shift(shift),.s_tag(1'b0),
  .m_valid(q_valid),.m_ready(state==Q_WAIT),.m_data(q_data),
  .m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_tag)
 );
 assign c_ready=!rst && state==IDLE;
 assign c_rsp_valid=!rst && state==CONFIG_RSP;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign a_ready=!rst && state==COLLECT && !a_full;
 assign b_ready=!rst && state==COLLECT && !b_full;
 assign m_valid=!rst && state==OUTPUT_ROW;
 assign m_pixel=pixel;assign m_channel=channel;assign m_last=expected_last;
 assign m_tag=tag;assign rsp_tag=tag;
 assign rsp_valid=!rst && state==DONE;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;configured<=0;a_full<=0;b_full<=0;
   c_error<=0;rsp_error<=0;rsp_outputs<=0;rsp_bad_a<=0;rsp_bad_b<=0;
   pixels<=0;channels<=0;pixel<=0;channel<=0;check_channel<=0;tag<=0;
   m_data<=0;m_clip<=0;m_inexact<=0;
  end else case(state)
   IDLE:begin
    if(c_valid)begin
     c_error<=0;state<=CONFIG_RSP;
     if(c_op==1)configured<=0;
     else if(c_op!=0)c_error<=2;
     else if(c_channel>=MAX_CHANNELS)c_error<=1;
     else if(c_min>c_max)c_error<=3;
     else begin
      metadata[c_channel[CW-1:0]]<={c_scale_a,c_scale_b,c_shift,c_zero_a,c_zero_b,c_zero_out,c_min,c_max};
      configured[c_channel[CW-1:0]]<=1;
     end
    end else if(cmd_valid)begin
     tag<=cmd_tag;pixels<=cmd_pixels;channels<=cmd_channels;
     pixel<=0;channel<=0;check_channel<=0;a_full<=0;b_full<=0;
     rsp_outputs<=0;rsp_bad_a<=0;rsp_bad_b<=0;rsp_error<=0;
     if(cmd_pixels<1 || cmd_pixels>MAX_PIXELS || cmd_channels<1 || cmd_channels>MAX_CHANNELS)begin
      rsp_error<=1;state<=DONE;
     end else state<=PRECHECK;
    end
   end
   CONFIG_RSP:if(c_rsp_ready)state<=IDLE;
   PRECHECK:begin
    if(!configured[check_channel[CW-1:0]])begin rsp_error<=2;state<=DONE;end
    else if(check_channel==channels-1'b1)state<=COLLECT;
    else check_channel<=check_channel+1'b1;
   end
   COLLECT:begin
    if(a_valid && a_ready)begin av<=a_data;al<=a_last;a_full<=1;end
    if(b_valid && b_ready)begin bv<=b_data;bl<=b_last;b_full<=1;end
    if(a_full && b_full)begin
     if(al!=expected_last || bl!=expected_last)begin
      rsp_error<=3;rsp_bad_a<=al!=expected_last;rsp_bad_b<=bl!=expected_last;state<=DONE;
     end else state<=META_READ;
    end
   end
   META_READ:begin meta_q<=metadata[channel[CW-1:0]];state<=MUL_A;end
   MUL_A:begin product_a<=product;state<=MUL_B;end
   MUL_B:begin product_b<=product;state<=SUM;end
   SUM:begin scaled_sum<=$signed({product_a[25],product_a})+$signed({product_b[25],product_b});state<=Q_SEND;end
   Q_SEND:if(q_ready)state<=Q_WAIT;
   Q_WAIT:if(q_valid)begin
    m_data<=with_zero<minimum?act_min:with_zero>maximum?act_max:with_zero[7:0];
    m_clip<=with_zero<minimum || with_zero>maximum;m_inexact<=q_inexact;state<=OUTPUT_ROW;
   end
   OUTPUT_ROW:if(m_ready)begin
    rsp_outputs<=rsp_outputs+1'b1;a_full<=0;b_full<=0;
    if(expected_last)state<=DONE;
    else begin
     if(channel==channels-1'b1)begin channel<=0;pixel<=pixel+1'b1;end
     else channel<=channel+1'b1;
     state<=COLLECT;
    end
   end
   DONE:if(rsp_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
