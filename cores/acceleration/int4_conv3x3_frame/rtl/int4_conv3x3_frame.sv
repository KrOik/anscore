// SPDX-License-Identifier: Apache-2.0
// U8 single-channel raster -> cropped 3x3 cross-correlation -> signed8 channels.
module int4_conv3x3_frame #(
 parameter MAX_CHANNELS=8,MAX_WIDTH=64,MAX_HEIGHT=64,TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [1:0] c_op,
 input wire [15:0] c_row,c_word,input wire [31:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,
 input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_channels,
 input wire [7:0] cmd_x_zero,input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_sof,s_eol,s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_x,m_y,m_channel,output wire [TAG_W-1:0] m_tag,
 output wire m_sof,m_eol,m_last,m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output reg [3:0] rsp_error,
 output reg [31:0] rsp_outputs,output wire [TAG_W-1:0] rsp_tag,
 output wire busy
);
 localparam IDLE=0,MAT_CMD=1,PREFLIGHT=2,WIN_CFG=3,WAIT_PATCH=4,
            FEED=5,RESULT=6,FINISH=7,RESPONSE=8;
 reg [3:0] state;
 reg [15:0] width,height,channels,input_x,input_y,patch_x,patch_y;
 reg [7:0] x_zero;
 reg [TAG_W-1:0] tag;
 reg [71:0] patch;
 reg [3:0] tap;
 reg patch_sof,patch_eol,patch_eof,marker_error,window_seen,window_started;
 reg window_reset;
 reg [3:0] window_error;
 wire wc_ready,ws_ready,wm_valid,wm_ready,wr_valid;
 wire [3:0] wr_error;
 wire [71:0] wm_taps;
 wire [15:0] wm_x,wm_y;
 wire wm_sof,wm_eol,wm_eof;
 wire mat_c_ready,mat_c_rsp_valid,mat_cmd_ready,mat_s_ready,mat_valid,mat_ready;
 wire signed [7:0] mat_data;
 wire [15:0] mat_row;
 wire [TAG_W-1:0] mat_tag;
 wire mat_last,mat_clip,mat_inexact,mat_busy;
 wire [1:0] mat_error;
 wire active=state!=IDLE && state!=RESPONSE;
 wire input_fire=s_valid && s_ready;
 wire output_fire=m_valid && m_ready;
 generate if(MAX_CHANNELS<1 || MAX_CHANNELS>64 || MAX_WIDTH<3 || MAX_WIDTH>1024 ||
             MAX_HEIGHT<3 || MAX_HEIGHT>1024 || TAG_W<1 || TAG_W>32)begin: invalid
  int4_conv3x3_frame_invalid_parameters__see_README bad_parameters();
 end endgenerate
 assign c_ready=!rst && state==IDLE && mat_c_ready;
 assign c_rsp_valid=!rst && state==IDLE && mat_c_rsp_valid;
 assign cmd_ready=!rst && state==IDLE && mat_cmd_ready && !c_valid;
 assign s_ready=!rst && active && window_started && ws_ready;
 assign wm_ready=state==WAIT_PATCH;
 assign m_valid=!rst && state==RESULT && mat_valid && mat_error==0;
 assign mat_ready=state==PREFLIGHT || (state==RESULT && (mat_error!=0 || m_ready));
 assign m_data=mat_data;assign m_x=patch_x;assign m_y=patch_y;
 assign m_channel=mat_row;assign m_tag=mat_tag;
 assign m_sof=patch_sof && mat_row==0;
 assign m_eol=patch_eol && mat_last;assign m_last=patch_eof && mat_last;
 assign m_clip=mat_clip;assign m_inexact=mat_inexact;
 assign rsp_valid=!rst && state==RESPONSE;
 assign rsp_tag=tag;
 assign busy=state!=IDLE || mat_busy;
 img_window3x3_valid_draft #(.PIXEL_W(8),.MAX_WIDTH(MAX_WIDTH)) window_core(
  .clk(clk),.rst_n(!rst && !window_reset),.clk_en(1'b1),
  .cfg_valid(state==WIN_CFG),.cfg_ready(wc_ready),.cfg_width(width),.cfg_height(height),
  .rsp_valid(wr_valid),.rsp_ready(active && !window_seen),.rsp_error(wr_error),
  .s_data(s_data),.s_valid(s_valid && active && window_started),.s_sof(s_sof),.s_eol(s_eol),.s_ready(ws_ready),
  .m_taps(wm_taps),.m_center(),.m_x(wm_x),.m_y(wm_y),.m_valid(wm_valid),
  .m_sof(wm_sof),.m_eol(wm_eol),.m_eof(wm_eof),.m_ready(wm_ready));
 int4_weight_matvec #(.MAX_ROWS(MAX_CHANNELS),.MAX_COLS(9),.TAG_W(TAG_W)) matrix_core(
  .clk(clk),.rst(rst),.c_valid(c_valid && state==IDLE),.c_ready(mat_c_ready),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),.c_rsp_valid(mat_c_rsp_valid),
  .c_rsp_ready(c_rsp_ready && state==IDLE),.c_error(c_error),
  .cmd_valid(state==MAT_CMD),.cmd_ready(mat_cmd_ready),.cmd_rows(channels),.cmd_cols(16'd9),
  .cmd_x_zero(x_zero),.cmd_tag(tag),.s_valid(state==FEED),.s_ready(mat_s_ready),
  .s_data(patch[tap*8+:8]),.s_last(tap==8),.m_valid(mat_valid),.m_ready(mat_ready),
  .m_data(mat_data),.m_row(mat_row),.m_tag(mat_tag),.m_last(mat_last),
  .m_clip(mat_clip),.m_inexact(mat_inexact),.m_error(mat_error),.busy(mat_busy));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;width<=0;height<=0;channels<=0;input_x<=0;input_y<=0;
   patch_x<=0;patch_y<=0;x_zero<=0;tag<=0;patch<=0;tap<=0;
   patch_sof<=0;patch_eol<=0;patch_eof<=0;marker_error<=0;
   window_seen<=0;window_started<=0;window_reset<=1;window_error<=0;
   rsp_error<=0;rsp_outputs<=0;
  end else begin
   if(input_fire)begin
    if(s_last!=((input_x==width-1'b1)&&(input_y==height-1'b1)))marker_error<=1;
    if(input_x==width-1'b1)begin input_x<=0;input_y<=input_y+1'b1;end
    else input_x<=input_x+1'b1;
   end
   if(wr_valid && active && !window_seen)begin window_seen<=1;window_error<=wr_error;end
   if(output_fire)rsp_outputs<=rsp_outputs+1'b1;
   case(state)
    IDLE:if(cmd_valid && cmd_ready)begin
     width<=cmd_width;height<=cmd_height;channels<=cmd_channels;x_zero<=cmd_x_zero;tag<=cmd_tag;
     input_x<=0;input_y<=0;marker_error<=0;window_seen<=0;window_started<=0;
     window_error<=0;rsp_outputs<=0;rsp_error<=0;
     if(cmd_width<3 || cmd_width>MAX_WIDTH || cmd_height<3 || cmd_height>MAX_HEIGHT ||
        cmd_channels==0 || cmd_channels>MAX_CHANNELS)begin rsp_error<=1;state<=RESPONSE;end
     else begin window_reset<=0;state<=MAT_CMD;end
    end
    MAT_CMD:if(mat_cmd_ready)state<=PREFLIGHT;
    PREFLIGHT:begin
     // Matrix LOAD readiness proves every selected row and both words exist.
     // The first patch command remains live until actual image taps arrive.
     if(mat_valid)begin rsp_error<=mat_error==2?4'd2:4'd4;window_reset<=1;state<=RESPONSE;end
     else if(mat_s_ready)state<=window_started?WAIT_PATCH:WIN_CFG;
    end
    WIN_CFG:if(wc_ready)begin window_started<=1;state<=WAIT_PATCH;end
    WAIT_PATCH:if(wm_valid)begin
     patch<=wm_taps;patch_x<=wm_x-1'b1;patch_y<=wm_y-1'b1;
     patch_sof<=wm_sof;patch_eol<=wm_eol;patch_eof<=wm_eof;tap<=0;state<=FEED;
    end
    FEED:if(mat_s_ready)begin
     if(tap==8)state<=RESULT;else tap<=tap+1'b1;
    end
    RESULT:if(mat_valid && mat_ready)begin
     if(mat_error!=0)begin rsp_error<=4;window_reset<=1;state<=RESPONSE;end
     else if(mat_last)state<=patch_eof?FINISH:MAT_CMD;
    end
    FINISH:if(window_seen)begin
     rsp_error<=(window_error==2 || marker_error)?4'd3:window_error!=0?4'd4:4'd0;
     window_reset<=1;state<=RESPONSE;
    end
    RESPONSE:if(rsp_ready)state<=IDLE;
    default:begin rsp_error<=4;window_reset<=1;state<=RESPONSE;end
   endcase
  end
 end
endmodule
