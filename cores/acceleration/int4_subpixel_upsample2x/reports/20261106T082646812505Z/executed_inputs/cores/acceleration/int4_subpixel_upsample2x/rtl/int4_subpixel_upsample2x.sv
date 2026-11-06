// SPDX-License-Identifier: Apache-2.0
// Resident INT4 1x1 map followed by DCR depth-to-space2, one lower-row RAM.
module int4_subpixel_upsample2x #(
 parameter MAX_IN_CHANNELS=8,MAX_OUT_CHANNELS=4,MAX_WIDTH=64,MAX_HEIGHT=64,TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [1:0] c_op,input wire [15:0] c_row,c_word,
 input wire [31:0] c_weights,input wire signed [31:0] c_bias,
 input wire [15:0] c_scale,input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_in_channels,cmd_out_channels,
 input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_sof,s_eol,s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_x,m_y,m_channel,output wire [TAG_W-1:0] m_tag,
 output wire m_sof,m_eol,m_last,m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output reg [2:0] rsp_error,
 output wire [TAG_W-1:0] rsp_tag,output reg [31:0] rsp_inputs,rsp_outputs,
 output wire busy
);
 localparam DEPTH=2*MAX_WIDTH*MAX_OUT_CHANNELS,AW=DEPTH<2?1:$clog2(DEPTH);
 localparam IDLE=0,START=1,FEED=2,COLLECT=3,LOWER_RD=4,LOWER_SEND=5,DONE=6,FLUSH=7;
 generate if(MAX_IN_CHANNELS<1 || MAX_IN_CHANNELS>64 || MAX_OUT_CHANNELS<1 || MAX_OUT_CHANNELS>16 ||
             MAX_WIDTH<1 || MAX_WIDTH>1024 || MAX_HEIGHT<1 || MAX_HEIGHT>1024 || TAG_W<1 || TAG_W>32) begin:bad_parameters
  int4_subpixel_upsample2x_parameters_outside_contract unsupported();
 end endgenerate
 reg [2:0] state;
 reg flush;
 reg [15:0] width,height,ichannels,ochannels,sx,sy,ic,lane,expected_row;
 reg dx,dy;
 reg [15:0] lower_x,lower_channel;
 reg [AW-1:0] write_addr,read_addr;
 reg [9:0] lower_mem[0:DEPTH-1];
 reg [9:0] lower_q;
 reg [7:0] x_zero;
 reg [TAG_W-1:0] tag;
 wire child_rst=rst||flush;
 wire kc_ready,kc_valid,kcmd_ready,ks_ready,km_valid,km_last,km_clip,km_inexact,kbusy;
 wire [1:0] kc_error,km_error;
 wire signed [7:0] km_data;
 wire [15:0] km_row;
 wire [TAG_W-1:0] km_tag;
 wire first_input=sx==0 && sy==0 && ic==0;
 wire final_input=sx==width-1'b1 && sy==height-1'b1 && ic==ichannels-1'b1;
 wire end_source_row=sx==width-1'b1 && ic==ichannels-1'b1;
 wire bad_marker=(s_sof!=first_input)||(s_eol!=end_source_row)||(s_last!=final_input);
 wire child_bad=(km_error!=0)||(km_row!=expected_row)||(km_tag!=tag)||
                (km_last!=(expected_row==4*ochannels-1'b1));
 wire top_token=state==COLLECT && !dy;
 wire lower_token=state==LOWER_SEND;
 wire km_ready=!rst && ((km_error!=0 && (state==FEED || state==COLLECT)) ||
                         (state==COLLECT && (child_bad || dy || m_ready)));
 assign c_ready=!rst && !flush && state==IDLE && kc_ready;
 assign c_rsp_valid=!rst && !flush && state==IDLE && kc_valid;
 assign c_error=kc_error;
 assign cmd_ready=!rst && !flush && state==IDLE && !c_valid && kcmd_ready;
 assign s_ready=!rst && state==FEED && ks_ready;
 assign m_valid=!rst && ((top_token && km_valid && !child_bad)||lower_token);
 assign m_data=lower_token?lower_q[7:0]:km_data;
 assign m_clip=lower_token?lower_q[8]:km_clip;
 assign m_inexact=lower_token?lower_q[9]:km_inexact;
 assign m_x=lower_token?lower_x:(sx<<1)+dx;
 assign m_y=(sy<<1)+(lower_token?16'd1:16'd0);
 assign m_channel=lower_token?lower_channel:lane;
 assign m_tag=tag;
 assign m_sof=!lower_token && sx==0 && sy==0 && !dx && lane==0;
 assign m_eol=lower_token?(lower_x==(width<<1)-1'b1 && lower_channel==ochannels-1'b1):
                          (sx==width-1'b1 && dx && lane==ochannels-1'b1);
 assign m_last=lower_token && sy==height-1'b1 && lower_x==(width<<1)-1'b1 && lower_channel==ochannels-1'b1;
 assign rsp_valid=!rst && state==DONE;
 assign rsp_tag=tag;
 assign busy=state!=IDLE || kbusy;
 int4_weight_matvec #(.MAX_ROWS(4*MAX_OUT_CHANNELS),.MAX_COLS(MAX_IN_CHANNELS),.TAG_W(TAG_W)) matrix(
  .clk(clk),.rst(child_rst),.c_valid(c_valid && state==IDLE && !flush),.c_ready(kc_ready),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(kc_valid),
  .c_rsp_ready(c_rsp_ready && state==IDLE),.c_error(kc_error),
  .cmd_valid(state==START),.cmd_ready(kcmd_ready),.cmd_rows(ochannels<<2),.cmd_cols(ichannels),
  .cmd_x_zero(x_zero),.cmd_tag(tag),.s_valid(state==FEED && s_valid && !bad_marker),
  .s_ready(ks_ready),.s_data(s_data),.s_last(ic==ichannels-1'b1),
  .m_valid(km_valid),.m_ready(km_ready),.m_data(km_data),.m_row(km_row),.m_tag(km_tag),
  .m_last(km_last),.m_clip(km_clip),.m_inexact(km_inexact),.m_error(km_error),.busy(kbusy));
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;flush<=0;width<=0;height<=0;ichannels<=0;ochannels<=0;sx<=0;sy<=0;
   ic<=0;lane<=0;expected_row<=0;dx<=0;dy<=0;lower_x<=0;lower_channel<=0;
   write_addr<=0;read_addr<=0;lower_q<=0;x_zero<=0;tag<=0;rsp_error<=0;rsp_inputs<=0;rsp_outputs<=0;
  end else begin
   if(m_valid && m_ready) rsp_outputs<=rsp_outputs+1'b1;
   if((state==FEED || state==COLLECT) && km_valid && km_ready && child_bad) begin
    if(km_error==2) begin rsp_error<=2;state<=DONE;end
    else begin rsp_error<=4;flush<=1;state<=FLUSH;end
   end else case(state)
    IDLE: if(cmd_valid && cmd_ready) begin
     width<=cmd_width;height<=cmd_height;ichannels<=cmd_in_channels;ochannels<=cmd_out_channels;
     x_zero<=cmd_x_zero;tag<=cmd_tag;sx<=0;sy<=0;ic<=0;lane<=0;expected_row<=0;dx<=0;dy<=0;
     write_addr<=0;read_addr<=0;lower_x<=0;lower_channel<=0;rsp_inputs<=0;rsp_outputs<=0;rsp_error<=0;
     if(cmd_width==0 || cmd_height==0 || cmd_width>MAX_WIDTH || cmd_height>MAX_HEIGHT ||
        cmd_in_channels==0 || cmd_in_channels>MAX_IN_CHANNELS || cmd_out_channels==0 || cmd_out_channels>MAX_OUT_CHANNELS) begin
      rsp_error<=1;state<=DONE;
     end else state<=START;
    end
    START: if(kcmd_ready) state<=FEED;
    FEED: if(s_valid && s_ready) begin
     rsp_inputs<=rsp_inputs+1'b1;
     if(bad_marker) begin rsp_error<=3;flush<=1;state<=FLUSH;end
     else if(ic==ichannels-1'b1) begin ic<=0;state<=COLLECT;end
     else ic<=ic+1'b1;
    end
    COLLECT: if(km_valid && km_ready) begin
     if(dy) begin
      lower_mem[write_addr]<={km_inexact,km_clip,km_data};
      write_addr<=write_addr+1'b1;
     end
     expected_row<=expected_row+1'b1;
     if(lane==ochannels-1'b1) begin
      lane<=0;
      if(dx) begin dx<=0;dy<=!dy;end
      else dx<=1;
     end else lane<=lane+1'b1;
     if(km_last) begin
      expected_row<=0;lane<=0;dx<=0;dy<=0;
      if(sx==width-1'b1) begin
       read_addr<=0;lower_x<=0;lower_channel<=0;state<=LOWER_RD;
      end else begin sx<=sx+1'b1;state<=START;end
     end
    end
    LOWER_RD: begin lower_q<=lower_mem[read_addr];state<=LOWER_SEND;end
    LOWER_SEND: if(m_ready) begin
     if(lower_x==(width<<1)-1'b1 && lower_channel==ochannels-1'b1) begin
      if(sy==height-1'b1) state<=DONE;
      else begin sy<=sy+1'b1;sx<=0;write_addr<=0;state<=START;end
     end else begin
      read_addr<=read_addr+1'b1;
      if(lower_channel==ochannels-1'b1) begin lower_channel<=0;lower_x<=lower_x+1'b1;end
      else lower_channel<=lower_channel+1'b1;
      state<=LOWER_RD;
     end
    end
    DONE: if(rsp_ready) state<=IDLE;
    FLUSH: begin flush<=0;state<=DONE;end
    default: begin rsp_error<=4;flush<=1;state<=FLUSH;end
   endcase
  end
 end
endmodule
