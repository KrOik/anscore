// End-to-end completion includes the statistics stage's final pixel output.
module isp_stream_with_statistics #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_frame_id,input wire [1:0] cmd_pattern,
 input wire [4*RAW_BITS-1:0] cmd_levels,input wire [RAW_BITS-1:0] cmd_target,input wire cmd_blc_bypass,
 input wire [47:0] cmd_gains,input wire [191:0] cmd_matrix,input wire cmd_gamma_enable,
 input wire lut_valid,output wire lut_ready,input wire [1:0] lut_channel,input wire [7:0] lut_address,lut_value,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,output wire m_sof,m_eol,m_eof,
 output wire [15:0] m_frame_id,output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height,
 output wire stats_valid,input wire stats_ready,output wire [47:0] sum_r,sum_g,sum_b,
 output wire [31:0] pixel_count,line_count,output wire [15:0] stats_frame_id,
 output wire stats_overflow,stats_protocol_error,input wire cmd_bayer_bypass
);
 reg active,flush,output_done,stats_seen,publish_enable;
 wire stage_reset=rst_n&&!flush;
 wire core_cmd_ready,core_rsp_valid,core_mv,core_mr,core_sof,core_eol,core_eof;
 wire [3:0] core_error;wire [23:0] core_data;wire [15:0] core_id;
 wire internal_stats_valid;
 assign cmd_ready=core_cmd_ready&&!active&&!internal_stats_valid&&!flush;
 assign stats_valid=internal_stats_valid&&publish_enable;
 assign rsp_error=core_error;
 assign rsp_valid=active&&core_rsp_valid&&(core_error!=0?!m_valid:(output_done&&stats_seen));
 isp_stream_core #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) core(
 .clk(clk),.rst_n(rst_n),.cmd_valid(cmd_valid&&!active&&!internal_stats_valid&&!flush),.cmd_ready(core_cmd_ready),
 .cmd_width(cmd_width),.cmd_height(cmd_height),.cmd_frame_id(cmd_frame_id),.cmd_pattern(cmd_pattern),
 .cmd_levels(cmd_levels),.cmd_target(cmd_target),.cmd_blc_bypass(cmd_blc_bypass),.cmd_bayer_bypass(cmd_bayer_bypass),.cmd_gains(cmd_gains),.cmd_matrix(cmd_matrix),.cmd_gamma_enable(cmd_gamma_enable),
 .lut_valid(lut_valid&&!active&&!flush),.lut_ready(lut_ready),.lut_channel(lut_channel),.lut_address(lut_address),.lut_value(lut_value),
 .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(core_mv),.m_ready(core_mr),.m_data(core_data),.m_sof(core_sof),.m_eol(core_eol),.m_eof(core_eof),.m_frame_id(core_id),
 .rsp_valid(core_rsp_valid),.rsp_ready(rsp_valid&&rsp_ready),.rsp_error(core_error),.out_width(out_width),.out_height(out_height));
 rgb_frame_statistics statistics(
 .clk(clk),.rst_n(stage_reset),.s_valid(core_mv),.s_ready(core_mr),.s_data(core_data),.s_sof(core_sof),.s_eol(core_eol),.s_eof(core_eof),.s_frame_id(core_id),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_frame_id(m_frame_id),
 .stats_valid(internal_stats_valid),.stats_ready(stats_ready&&publish_enable),.sum_r(sum_r),.sum_g(sum_g),.sum_b(sum_b),
 .pixel_count(pixel_count),.line_count(line_count),.stats_frame_id(stats_frame_id),.overflow(stats_overflow),.protocol_error(stats_protocol_error));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;flush<=0;output_done<=0;stats_seen<=0;publish_enable<=0;end
  else begin
   flush<=0;
   if(cmd_valid&&cmd_ready)begin active<=1;output_done<=0;stats_seen<=0;publish_enable<=0;end
   if(active&&internal_stats_valid)stats_seen<=1;
   if(active&&core_rsp_valid&&core_error==0)publish_enable<=1;
   if(m_valid&&m_ready&&m_eof)output_done<=1;
   if(rsp_valid&&rsp_ready)begin active<=0;if(core_error!=0)begin flush<=1;publish_enable<=0;end end
  end
 end
endmodule
