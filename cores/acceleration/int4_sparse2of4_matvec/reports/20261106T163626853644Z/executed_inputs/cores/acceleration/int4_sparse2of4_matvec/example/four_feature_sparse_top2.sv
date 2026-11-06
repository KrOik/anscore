// SPDX-License-Identifier: Apache-2.0
// Fixed 2:4 differential feature projection -> existing stable signed Top-2.
module four_feature_sparse_top2 #(parameter TAG_W=8)(
 input wire clk,rst,input wire s_valid,output wire s_ready,
 input wire [31:0] s_features,input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_score,
 output wire [1:0] m_index,output wire [TAG_W-1:0] m_tag,output wire m_last
);
 localparam BOOT_SEND=0,BOOT_ACK=1,READY=2,LOAD=3,RANK=4;
 reg [2:0] state;
 reg [1:0] boot_row,input_index;
 reg boot_meta;
 reg [31:0] features;
 wire cfg_ready,cfg_valid,core_cmd_ready,core_s_ready,core_m_valid,core_m_ready;
 wire [1:0] cfg_error,core_error;
 wire [7:0] core_score;
 wire [15:0] core_row;
 wire [TAG_W-1:0] core_tag;
 wire core_last,core_clip,core_inexact,core_busy;
 wire [TAG_W+1:0] ranked_tag;
 wire [2:0] pattern=boot_row==0?3'd0:boot_row==1?3'd1:boot_row==2?3'd4:3'd5;
 assign s_ready=!rst && state==READY && core_cmd_ready;
 assign m_index=ranked_tag[1:0];assign m_tag=ranked_tag[TAG_W+1:2];
 int4_sparse2of4_matvec #(.MAX_ROWS(4),.MAX_COLS(4),.TAG_W(TAG_W)) projection(
  .clk(clk),.rst(rst),.c_valid(state==BOOT_SEND),.c_ready(cfg_ready),
  .c_op(boot_meta?2'd1:2'd0),.c_row({14'd0,boot_row}),.c_group(16'd0),
  .c_pattern(pattern),.c_weights(8'hf1),.c_bias(32'sd0),.c_scale(16'd1),
  .c_shift(5'd1),.c_zero(8'sd0),.c_rsp_valid(cfg_valid),
  .c_rsp_ready(state==BOOT_ACK),.c_error(cfg_error),
  .cmd_valid(s_valid && state==READY),.cmd_ready(core_cmd_ready),
  .cmd_rows(16'd4),.cmd_cols(16'd4),.cmd_x_zero(8'd128),.cmd_tag(s_tag),
  .s_valid(state==LOAD),.s_ready(core_s_ready),.s_data(features[input_index*8+:8]),
  .s_last(input_index==3),.m_valid(core_m_valid),.m_ready(core_m_ready),
  .m_data(core_score),.m_row(core_row),.m_tag(core_tag),.m_last(core_last),
  .m_clip(core_clip),.m_inexact(core_inexact),.m_error(core_error),.busy(core_busy));
 stream_topk #(.SCORE_W(8),.TAG_W(TAG_W+2),.K(2),.SIGNED_SCORE(1)) ranking(
  .clk(clk),.rst(rst),.s_valid(core_m_valid),.s_ready(core_m_ready),
  .s_score(core_score),.s_tag({core_tag,core_row[1:0]}),.s_last(core_last),
  .m_valid(m_valid),.m_ready(m_ready),.m_score(m_score),.m_tag(ranked_tag),.m_last(m_last));
 always @(posedge clk)begin
  if(rst)begin state<=BOOT_SEND;boot_row<=0;boot_meta<=0;input_index<=0;features<=0;end
  else case(state)
   BOOT_SEND:if(cfg_ready)state<=BOOT_ACK;
   BOOT_ACK:if(cfg_valid)begin
    if(!boot_meta)begin boot_meta<=1;state<=BOOT_SEND;end
    else if(boot_row==3)state<=READY;
    else begin boot_row<=boot_row+1'b1;boot_meta<=0;state<=BOOT_SEND;end
   end
   READY:if(s_valid && s_ready)begin features<=s_features;input_index<=0;state<=LOAD;end
   LOAD:if(core_s_ready)begin
    if(input_index==3)state<=RANK;else input_index<=input_index+1'b1;
   end
   RANK:if(m_valid && m_ready && m_last)state<=READY;
   default:state<=BOOT_SEND;
  endcase
 end
endmodule
