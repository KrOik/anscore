// SPDX-License-Identifier: Apache-2.0
// Exact signed8 channel-wise global spatial mean, NHWC transfer order.
module signed8_global_average_pool #(
 parameter MAX_CHANNELS=16, MAX_PIXELS=256, TAG_W=16
)(
 input wire clk,rst,
 input wire cmd_valid,output wire cmd_ready,
 input wire [16:0] cmd_pixels,input wire [15:0] cmd_channels,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,
 input wire signed [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,
 output reg signed [7:0] m_data,output reg signed [23:0] m_sum,
 output wire [15:0] m_channel,output wire [TAG_W-1:0] m_tag,
 output wire m_last,output reg m_inexact,
 output wire rsp_valid,input wire rsp_ready,
 output reg [1:0] rsp_error,output reg [15:0] rsp_outputs,
 output reg [23:0] rsp_inputs,output wire [TAG_W-1:0] rsp_tag,
 output wire busy
);
 localparam IDLE=0,LOAD=1,UPDATE=2,READ_SUM=3,DIV_SEND=4,
            DIV_WAIT=5,ROUND=6,OUTPUT=7,DONE=8;
 reg [3:0] state;
 reg signed [23:0] sums[0:MAX_CHANNELS-1];
 reg signed [23:0] sum_read;
 reg signed [7:0] sample;
 reg [16:0] pixels,pixel_index;
 reg [15:0] channels,channel_index;
 reg [TAG_W-1:0] tag;
 reg [23:0] quotient,remainder;
 reg negative;
 wire [23:0] magnitude=sum_read[23]?(~sum_read+24'd1):sum_read;
 wire d_ready,d_valid,d_zero;
 wire [23:0] d_quotient,d_remainder;
 wire [24:0] twice_remainder={remainder,1'b0};
 wire [24:0] denominator={8'd0,pixels};
 wire round_up=(twice_remainder>denominator) ||
               ((twice_remainder==denominator) && quotient[0]);
 wire [8:0] rounded={1'b0,quotient[7:0]}+round_up;
 wire signed [8:0] signed_mean=negative?-$signed(rounded):$signed(rounded);
 wire signed [23:0] sample_ext={{16{sample[7]}},sample};
 wire signed [23:0] new_sum=sum_read+sample_ext;
 assign cmd_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==LOAD;
 assign m_valid=!rst && state==OUTPUT;
 assign m_channel=channel_index;
 assign m_tag=tag;
 assign m_last=channel_index==channels-1'b1;
 assign rsp_valid=!rst && state==DONE;
 assign rsp_tag=tag;
 assign busy=state!=IDLE;
 generate if(MAX_CHANNELS<1 || MAX_CHANNELS>64 || MAX_PIXELS<1 ||
             MAX_PIXELS>65536 || TAG_W<1 || TAG_W>32) begin:invalid_parameters
  SIGNED8_GLOBAL_AVERAGE_POOL_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate
 integer_divider #(.W(24)) divide(
  .clk(clk),.rst(rst),.s_valid(!rst && state==DIV_SEND),.s_ready(d_ready),
  .s_numerator(magnitude),.s_denominator({7'd0,pixels}),
  .m_valid(d_valid),.m_ready(state==DIV_WAIT),
  .m_quotient(d_quotient),.m_remainder(d_remainder),.m_divzero(d_zero));
 // Single synchronous read or write per clock; payload RAM has no reset.
 always @(posedge clk) begin
  if(!rst) begin
   if(state==LOAD && s_valid) begin
    if(pixel_index==0) sum_read<=0;
    else sum_read<=sums[channel_index];
   end
   if(state==UPDATE) sums[channel_index]<=new_sum;
   if(state==READ_SUM) sum_read<=sums[channel_index];
  end
 end
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;pixels<=0;pixel_index<=0;channels<=0;channel_index<=0;
   tag<=0;sample<=0;quotient<=0;remainder<=0;negative<=0;
   m_data<=0;m_sum<=0;m_inexact<=0;rsp_error<=0;rsp_outputs<=0;rsp_inputs<=0;
  end else case(state)
   IDLE: if(cmd_valid) begin
    pixels<=cmd_pixels;channels<=cmd_channels;tag<=cmd_tag;
    pixel_index<=0;channel_index<=0;rsp_error<=0;rsp_outputs<=0;rsp_inputs<=0;
    if(cmd_pixels==0 || cmd_pixels>MAX_PIXELS || cmd_channels==0 ||
       cmd_channels>MAX_CHANNELS) begin rsp_error<=1;state<=DONE;end
    else state<=LOAD;
   end
   LOAD: if(s_valid) begin
    sample<=s_data;rsp_inputs<=rsp_inputs+1'b1;
    if(s_last!=((pixel_index==pixels-1'b1)&&(channel_index==channels-1'b1))) begin
     rsp_error<=2;state<=DONE;
    end else state<=UPDATE;
   end
   UPDATE: begin
    if(channel_index==channels-1'b1) begin
     channel_index<=0;
     if(pixel_index==pixels-1'b1) state<=READ_SUM;
     else begin pixel_index<=pixel_index+1'b1;state<=LOAD;end
    end else begin channel_index<=channel_index+1'b1;state<=LOAD;end
   end
   READ_SUM: state<=DIV_SEND;
   DIV_SEND: if(d_ready) begin negative<=sum_read[23];state<=DIV_WAIT;end
   DIV_WAIT: if(d_valid) begin
    if(d_zero) begin rsp_error<=3;state<=DONE;end
    else begin quotient<=d_quotient;remainder<=d_remainder;state<=ROUND;end
   end
   ROUND: begin
    m_sum<=sum_read;m_data<=signed_mean[7:0];m_inexact<=remainder!=0;state<=OUTPUT;
   end
   OUTPUT: if(m_ready) begin
    rsp_outputs<=rsp_outputs+1'b1;
    if(channel_index==channels-1'b1) state<=DONE;
    else begin channel_index<=channel_index+1'b1;state<=READ_SUM;end
   end
   DONE: if(rsp_ready) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
