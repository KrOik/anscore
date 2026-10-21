// One frame command binds RAW geometry/BLC and the full color configuration.
// Normal completion waits for both RAW processing and final RGB consumption.
module isp_stream_core #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_frame_id,input wire [1:0] cmd_pattern,
 input wire [4*RAW_BITS-1:0] cmd_levels,input wire [RAW_BITS-1:0] cmd_target,input wire cmd_blc_bypass,
 input wire [47:0] cmd_gains,input wire [191:0] cmd_matrix,input wire cmd_gamma_enable,
 input wire lut_valid,output wire lut_ready,input wire [1:0] lut_channel,input wire [7:0] lut_address,lut_value,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,output wire m_sof,m_eol,m_eof,
 output wire [15:0] m_frame_id,output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height,input wire cmd_bayer_bypass
);
 reg active,flush;
 wire child_reset=rst_n&&!flush;
 wire raw_ready,color_ready,raw_sr,raw_mv,color_sr,raw_sof,raw_eol,raw_eof;
 wire [23:0] raw_data;wire [15:0] raw_id;
 wire raw_rsp,color_rsp;wire [3:0] raw_error,color_error;
 wire color_lut_ready,color_drained;
 wire fatal=(raw_rsp&&raw_error!=0)||(color_rsp&&color_error!=0);
 wire accept_response=rsp_valid&&rsp_ready;
 assign cmd_ready=rst_n&&!flush&&!active&&raw_ready&&color_ready;
 assign lut_ready=rst_n&&!flush&&!active&&color_lut_ready;
 assign s_ready=active&&!fatal&&raw_sr;
 assign rsp_valid=rst_n&&active&&((fatal&&color_drained)||(raw_rsp&&color_rsp));
 assign rsp_error=raw_rsp&&raw_error!=0?raw_error:color_rsp?color_error:4'd0;
 raw_rgb_frontend #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) frontend(
 .clk(clk),.rst_n(child_reset),.cfg_valid(cmd_valid&&!active&&color_ready&&!flush),.cfg_ready(raw_ready),
 .cfg_width(cmd_width),.cfg_height(cmd_height),.cfg_frame_id(cmd_frame_id),.cfg_pattern(cmd_pattern),
 .cfg_levels(cmd_levels),.cfg_target(cmd_target),.cfg_blc_bypass(cmd_blc_bypass),.cfg_bayer_bypass(cmd_bayer_bypass),
 .s_valid(s_valid&&active&&!fatal),.s_ready(raw_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(raw_mv),.m_ready(color_sr&&active&&!fatal),.m_data(raw_data),
 .m_sof(raw_sof),.m_eol(raw_eol),.m_eof(raw_eof),.m_frame_id(raw_id),
 .rsp_valid(raw_rsp),.rsp_ready(accept_response),.rsp_error(raw_error),.out_width(out_width),.out_height(out_height));
 rgb_color_chain color(
 .clk(clk),.rst_n(child_reset),.cmd_valid(cmd_valid&&!active&&raw_ready&&!flush),.cmd_ready(color_ready),
 .cmd_gains(cmd_gains),.cmd_matrix(cmd_matrix),.cmd_gamma_enable(cmd_gamma_enable),
 .lut_valid(lut_valid&&!active&&!flush),.lut_ready(color_lut_ready),.lut_channel(lut_channel),.lut_address(lut_address),.lut_value(lut_value),
 .s_valid(raw_mv&&active&&!fatal),.s_ready(color_sr),.s_data(raw_data),
 .s_sof(raw_sof),.s_eol(raw_eol),.s_eof(raw_eof),.s_frame_id(raw_id),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_frame_id(m_frame_id),
 .rsp_valid(color_rsp),.rsp_ready(accept_response),.rsp_error(color_error),.drained(color_drained));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;flush<=0;end
  else begin
   flush<=0;
   if(cmd_valid&&cmd_ready)active<=1;
   if(accept_response)begin active<=0;if(fatal)flush<=1;end
  end
 end
endmodule
