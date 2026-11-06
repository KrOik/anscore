// SPDX-License-Identifier: Apache-2.0
// Four signed8 feature channels -> exact global means -> two INT4 logits.
module pooled_int4_classifier #(parameter MAX_PIXELS=256,TAG_W=16)(
 input wire clk,rst,
 input wire cmd_valid,output wire cmd_ready,input wire [16:0] cmd_pixels,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire signed [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_class,output wire [TAG_W-1:0] m_tag,
 output wire m_last,m_clip,m_inexact,
 output wire rsp_valid,input wire rsp_ready,output reg [1:0] rsp_error,
 output wire [TAG_W-1:0] rsp_tag,output wire busy
);
 localparam BOOT=0,BOOT_RSP=1,IDLE=2,MV_CMD=3,MV_CHECK=4,POOL_CMD=5,
            RUN=6,FLUSH=7,DONE=8;
 reg [3:0] state;
 reg [2:0] boot_index;
 reg [16:0] pixels;
 reg [TAG_W-1:0] tag;
 reg pool_done,class_done;
 wire c_ready,c_rsp_valid;
 wire [1:0] c_error;
 wire mv_cmd_ready,mv_s_ready,mv_valid,mv_last,mv_clip,mv_inexact;
 wire [1:0] mv_error;
 wire signed [7:0] mv_data;
 wire [15:0] mv_row;
 wire [TAG_W-1:0] mv_tag;
 wire pool_cmd_ready,pool_s_ready,pool_valid,pool_last,pool_rsp;
 wire signed [7:0] pool_data;
 wire [1:0] pool_error;
 wire flush=state==FLUSH;
 assign cmd_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==RUN && pool_s_ready;
 assign m_valid=!rst && state==RUN && mv_valid && mv_error==0;
 assign m_data=mv_data;assign m_class=mv_row;assign m_tag=mv_tag;
 assign m_last=mv_last;assign m_clip=mv_clip;assign m_inexact=mv_inexact;
 assign rsp_valid=!rst && state==DONE;
 assign rsp_tag=tag;assign busy=state!=IDLE;
 signed8_global_average_pool #(.MAX_CHANNELS(4),.MAX_PIXELS(MAX_PIXELS),.TAG_W(TAG_W)) pool(
  .clk(clk),.rst(rst||flush),.cmd_valid(state==POOL_CMD),.cmd_ready(pool_cmd_ready),
  .cmd_pixels(pixels),.cmd_channels(16'd4),.cmd_tag(tag),
  .s_valid(s_valid&&state==RUN),.s_ready(pool_s_ready),.s_data(s_data),.s_last(s_last),
  .m_valid(pool_valid),.m_ready(mv_s_ready&&state==RUN),.m_data(pool_data),
  .m_sum(),.m_channel(),.m_tag(),.m_last(pool_last),.m_inexact(),
  .rsp_valid(pool_rsp),.rsp_ready(state==RUN),.rsp_error(pool_error),
  .rsp_outputs(),.rsp_inputs(),.rsp_tag(),.busy());
 int4_weight_matvec #(.MAX_ROWS(2),.MAX_COLS(4),.TAG_W(TAG_W)) classifier(
  .clk(clk),.rst(rst||flush),
  .c_valid(state==BOOT),.c_ready(c_ready),.c_op(boot_index[0]?2'd1:2'd0),
  .c_row({15'd0,boot_index[1]}),.c_word(16'd0),
  .c_weights(boot_index[1]?32'h0000f100:32'h00000011),.c_bias(32'sd0),
  .c_scale(16'd1),.c_shift(5'd0),.c_zero(8'sd0),
  .c_rsp_valid(c_rsp_valid),.c_rsp_ready(state==BOOT_RSP),.c_error(c_error),
  .cmd_valid(state==MV_CMD),.cmd_ready(mv_cmd_ready),
  .cmd_rows(16'd2),.cmd_cols(16'd4),.cmd_x_zero(8'd128),.cmd_tag(tag),
  .s_valid(pool_valid&&state==RUN),.s_ready(mv_s_ready),
  .s_data(pool_data^8'h80),.s_last(pool_last),
  .m_valid(mv_valid),.m_ready(state==RUN?((mv_error==0)?m_ready:1'b1):state==MV_CHECK),
  .m_data(mv_data),.m_row(mv_row),.m_tag(mv_tag),.m_last(mv_last),
  .m_clip(mv_clip),.m_inexact(mv_inexact),.m_error(mv_error),.busy());
 always @(posedge clk) begin
  if(rst) begin
   state<=BOOT;boot_index<=0;pixels<=0;tag<=0;rsp_error<=0;pool_done<=0;class_done<=0;
  end else case(state)
   BOOT: if(c_ready) state<=BOOT_RSP;
   BOOT_RSP: if(c_rsp_valid) begin
    if(c_error!=0) begin rsp_error<=3;state<=FLUSH;end
    else if(boot_index==3) state<=IDLE;
    else begin boot_index<=boot_index+1'b1;state<=BOOT;end
   end
   IDLE: if(cmd_valid) begin
    pixels<=cmd_pixels;tag<=cmd_tag;rsp_error<=0;pool_done<=0;class_done<=0;
    if(cmd_pixels==0 || cmd_pixels>MAX_PIXELS) begin rsp_error<=1;state<=DONE;end
    else state<=MV_CMD;
   end
   MV_CMD: if(mv_cmd_ready) state<=MV_CHECK;
   MV_CHECK: begin
    if(mv_valid) begin rsp_error<=3;state<=FLUSH;end
    else if(mv_s_ready) state<=POOL_CMD;
   end
   POOL_CMD: if(pool_cmd_ready) state<=RUN;
   RUN: begin
    if(pool_rsp) begin
     pool_done<=1;
     if(pool_error!=0) begin rsp_error<=pool_error;state<=FLUSH;end
    end
    if(mv_valid && mv_error!=0) begin rsp_error<=3;state<=FLUSH;end
    if(m_valid && m_ready && m_last) class_done<=1;
    if(pool_done && class_done) state<=DONE;
   end
   FLUSH: state<=DONE;
   DONE: if(rsp_ready) begin
    // A cancelled matrix vector reset invalidates resident weights; reconfigure.
    if(rsp_error==2 || rsp_error==3) begin boot_index<=0;state<=BOOT;end
    else state<=IDLE;
   end
   default: begin boot_index<=0;state<=BOOT;end
  endcase
 end
endmodule
