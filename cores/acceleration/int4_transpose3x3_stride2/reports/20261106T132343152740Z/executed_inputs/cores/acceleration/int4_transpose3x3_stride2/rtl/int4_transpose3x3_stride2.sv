// SPDX-License-Identifier: Apache-2.0
// Full 3x3 stride2 transposed convolution through a four-neighbour polyphase map.
// Packed matrix configuration follows README.md; unused phase groups MUST be zero.
module int4_transpose3x3_stride2 #(
 parameter MAX_IN_CHANNELS=4, MAX_OUT_CHANNELS=4,
 parameter MAX_WIDTH=64, MAX_HEIGHT=64, TAG_W=16
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
 localparam DEPTH=MAX_WIDTH*MAX_IN_CHANNELS,AW=DEPTH<2?1:$clog2(DEPTH);
 localparam IDLE=0,START=1,CAPTURE=2,GATHER_RD=3,GATHER_SEND=4,WAIT_DONE=5,DONE=6,FLUSH=7;
 generate if(MAX_IN_CHANNELS<1 || MAX_IN_CHANNELS>16 || MAX_OUT_CHANNELS<1 || MAX_OUT_CHANNELS>16 ||
             MAX_WIDTH<1 || MAX_WIDTH>1023 || MAX_HEIGHT<1 || MAX_HEIGHT>1023 || TAG_W<1 || TAG_W>32) begin:bad_parameters
  int4_transpose3x3_stride2_parameters_outside_contract unsupported();
 end endgenerate
 reg [2:0] state;
 reg flush;
 reg [15:0] width,height,ichannels,ochannels,anchor_x,anchor_y,cap_x,cap_channel,gather_channel;
 reg [1:0] gather_group;
 reg [AW-1:0] write_addr;
 reg [AW:0] pixel_base;
 reg [7:0] row_even[0:DEPTH-1],row_odd[0:DEPTH-1];
 reg [7:0] gather_q,x_zero;
 reg [TAG_W-1:0] tag;
 wire active=state!=IDLE && state!=DONE && state!=FLUSH;
 wire upper=gather_group[1],leftward=gather_group[0];
 wire row_present=upper?(anchor_y!=0):(anchor_y<height);
 wire column_present=leftward?(anchor_x!=0):(anchor_x<width);
 wire [AW:0] gather_address=pixel_base+(gather_channel)-(leftward?ichannels:16'd0);
 wire select_odd=anchor_y[0]^upper;
 wire cap_first=anchor_y==0 && cap_x==0 && cap_channel==0;
 wire cap_eol=cap_x==width-1'b1 && cap_channel==ichannels-1'b1;
 wire cap_last=anchor_y==height-1'b1 && cap_eol;
 wire bad_marker=(s_sof!=cap_first)||(s_eol!=cap_eol)||(s_last!=cap_last);
 wire group_last=gather_group==3 && gather_channel==ichannels-1'b1;
 wire kc_ready,kc_valid,kcmd_ready,ks_ready,km_valid,krsp_valid,kbusy;
 wire [1:0] kc_error;
 wire [2:0] krsp_error;
 wire signed [7:0] km_data;
 wire [15:0] km_x,km_y,km_channel;
 wire [TAG_W-1:0] km_tag;
 wire km_clip,km_inexact;
 wire keep=km_x<((width<<1)+16'd1) && km_y<((height<<1)+16'd1);
 wire km_ready=!rst && active && (keep?m_ready:1'b1);
 assign c_ready=!rst && !flush && state==IDLE && kc_ready;
 assign c_rsp_valid=!rst && !flush && state==IDLE && kc_valid;
 assign c_error=kc_error;
 assign cmd_ready=!rst && !flush && state==IDLE && !c_valid && kcmd_ready;
 // A row starts only after all child output from the preceding row has retired.
 // This prevents a malformed new row from withdrawing a stalled output on flush.
 assign s_ready=!rst && state==CAPTURE && !krsp_valid && ks_ready;
 assign m_valid=!rst && active && km_valid && keep;
 assign m_data=km_data;
 assign m_x=km_x;assign m_y=km_y;assign m_channel=km_channel;assign m_tag=km_tag;
 assign m_clip=km_clip;assign m_inexact=km_inexact;
 assign m_sof=km_x==0 && km_y==0 && km_channel==0;
 assign m_eol=km_x==(width<<1) && km_channel==ochannels-1'b1;
 assign m_last=m_eol && km_y==(height<<1);
 assign rsp_valid=!rst && state==DONE;
 assign rsp_tag=tag;
 assign busy=state!=IDLE || kbusy;
 int4_subpixel_upsample2x #(.MAX_IN_CHANNELS(4*MAX_IN_CHANNELS),.MAX_OUT_CHANNELS(MAX_OUT_CHANNELS),
  .MAX_WIDTH(MAX_WIDTH+1),.MAX_HEIGHT(MAX_HEIGHT+1),.TAG_W(TAG_W)) polyphase(
  .clk(clk),.rst(rst||flush),.c_valid(c_valid && state==IDLE && !flush),.c_ready(kc_ready),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(kc_valid),
  .c_rsp_ready(c_rsp_ready && state==IDLE),.c_error(kc_error),
  .cmd_valid(state==START),.cmd_ready(kcmd_ready),.cmd_width(width+16'd1),.cmd_height(height+16'd1),
  .cmd_in_channels(ichannels<<2),.cmd_out_channels(ochannels),.cmd_x_zero(x_zero),.cmd_tag(tag),
  .s_valid(state==GATHER_SEND && !krsp_valid),.s_ready(ks_ready),.s_data(gather_q),
  .s_sof(anchor_x==0 && anchor_y==0 && gather_group==0 && gather_channel==0),
  .s_eol(anchor_x==width && group_last),.s_last(anchor_x==width && anchor_y==height && group_last),
  .m_valid(km_valid),.m_ready(km_ready),.m_data(km_data),.m_x(km_x),.m_y(km_y),.m_channel(km_channel),
  .m_tag(km_tag),.m_clip(km_clip),.m_inexact(km_inexact),
  .rsp_valid(krsp_valid),.rsp_ready(active),.rsp_error(krsp_error),.busy(kbusy));
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;flush<=0;width<=0;height<=0;ichannels<=0;ochannels<=0;
   anchor_x<=0;anchor_y<=0;cap_x<=0;cap_channel<=0;gather_channel<=0;gather_group<=0;
   write_addr<=0;pixel_base<=0;gather_q<=0;x_zero<=0;tag<=0;
   rsp_error<=0;rsp_inputs<=0;rsp_outputs<=0;
  end else begin
   if(m_valid && m_ready) rsp_outputs<=rsp_outputs+1'b1;
   if(active && krsp_valid) begin
    if(krsp_error==2) begin rsp_error<=2;state<=DONE;end
    else if(krsp_error==0 && state==WAIT_DONE) begin rsp_error<=0;state<=DONE;end
    else begin rsp_error<=4;flush<=1;state<=FLUSH;end
   end else case(state)
    IDLE: if(cmd_valid && cmd_ready) begin
     width<=cmd_width;height<=cmd_height;ichannels<=cmd_in_channels;ochannels<=cmd_out_channels;
     x_zero<=cmd_x_zero;tag<=cmd_tag;anchor_x<=0;anchor_y<=0;cap_x<=0;cap_channel<=0;
     gather_channel<=0;gather_group<=0;pixel_base<=0;write_addr<=0;
     rsp_error<=0;rsp_inputs<=0;rsp_outputs<=0;
     if(cmd_width==0 || cmd_height==0 || cmd_width>MAX_WIDTH || cmd_height>MAX_HEIGHT ||
        cmd_in_channels==0 || cmd_in_channels>MAX_IN_CHANNELS ||
        cmd_out_channels==0 || cmd_out_channels>MAX_OUT_CHANNELS) begin rsp_error<=1;state<=DONE;end
     else state<=START;
    end
    START: if(kcmd_ready) state<=CAPTURE;
    CAPTURE: if(s_valid && s_ready) begin
     rsp_inputs<=rsp_inputs+1'b1;
     if(bad_marker) begin rsp_error<=3;flush<=1;state<=FLUSH;end
     else begin
      if(anchor_y[0]) row_odd[write_addr]<=s_data;else row_even[write_addr]<=s_data;
      write_addr<=write_addr+1'b1;
      if(cap_channel==ichannels-1'b1) begin
       cap_channel<=0;
       if(cap_x==width-1'b1) begin cap_x<=0;state<=GATHER_RD;end
       else cap_x<=cap_x+1'b1;
      end else cap_channel<=cap_channel+1'b1;
     end
    end
    GATHER_RD: begin
     // The first row/column and appended zero row/column never read stale RAM.
     if(!row_present || !column_present) gather_q<=x_zero;
     else if(select_odd) gather_q<=row_odd[gather_address[AW-1:0]];
     else gather_q<=row_even[gather_address[AW-1:0]];
     state<=GATHER_SEND;
    end
    GATHER_SEND: if(ks_ready) begin
     if(gather_channel==ichannels-1'b1) begin
      gather_channel<=0;
      if(gather_group==3) begin
       gather_group<=0;
       if(anchor_x==width) begin
        anchor_x<=0;pixel_base<=0;write_addr<=0;
        if(anchor_y==height) state<=WAIT_DONE;
        else begin
         anchor_y<=anchor_y+1'b1;
         if(anchor_y==height-1'b1) state<=GATHER_RD;
         else state<=CAPTURE;
        end
       end else begin anchor_x<=anchor_x+1'b1;pixel_base<=pixel_base+ichannels;state<=GATHER_RD;end
      end else begin gather_group<=gather_group+1'b1;state<=GATHER_RD;end
     end else begin gather_channel<=gather_channel+1'b1;state<=GATHER_RD;end
    end
    WAIT_DONE: begin end
    DONE: if(rsp_ready) state<=IDLE;
    FLUSH: begin flush<=0;state<=DONE;end
    default: begin rsp_error<=4;flush<=1;state<=FLUSH;end
   endcase
  end
 end
endmodule
