// Two ordered RGB888 overlays using unchanged canonical elastic blend pipes.
// Each accepted pixel snapshots both layer controls; no live config leaks.
module dual_osd_stream(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire [23:0] s_base,s_aux0,s_aux1,s_key0,s_key1,
 input wire [8:0] s_alpha0,s_alpha1,
 input wire [1:0] s_enable,s_key_enable,
 input wire s_sof,s_eol,s_last,input wire [15:0] s_user,
 input wire [31:0] s_frame,input wire [7:0] s_error,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_sof,m_eol,m_last,output wire [15:0] m_user,
 output wire [31:0] m_frame,output wire [7:0] m_error
);
 wire use0=s_enable[0]&&!(s_key_enable[0]&&s_aux0==s_key0);
 wire use1=s_enable[1]&&!(s_key_enable[1]&&s_aux1==s_key1);
 wire[7:0] error=s_error|((s_enable[0]&&s_alpha0>256)||(s_enable[1]&&s_alpha1>256)?8'd1:8'd0);
 wire v,ready,sof,eol;wire[23:0] pixel;wire[50:0] tag;
 wire[31:0] frame;wire[7:0] stage_error;wire[16:0] result_tag;
 img_mf_rgb_blend_pipe #(.TAG_WIDTH(51),.FRAME_WIDTH(32)) layer0(
  clk,rst_n,1'b1,s_valid,s_ready,s_base,s_aux0,s_alpha0,use0,
  s_sof,s_eol,{s_last,use1,s_alpha1,s_aux1,s_user},s_frame,error,
  v,ready,pixel,sof,eol,tag,frame,stage_error);
 img_mf_rgb_blend_pipe #(.TAG_WIDTH(17),.FRAME_WIDTH(32)) layer1(
  clk,rst_n,1'b1,v,ready,pixel,tag[39:16],tag[48:40],tag[49],
  sof,eol,{tag[50],tag[15:0]},frame,stage_error,
  m_valid,m_ready,m_data,m_sof,m_eol,result_tag,m_frame,m_error);
 assign m_last=result_tag[16];assign m_user=result_tag[15:0];
endmodule
