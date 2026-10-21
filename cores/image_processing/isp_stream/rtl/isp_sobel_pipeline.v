// RAW-to-color statistics followed by grayscale Sobel; luma=(R+2G+B)>>2.
module isp_sobel_pipeline #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_width,cmd_height,cmd_frame_id,input wire [1:0] cmd_pattern,
 input wire [4*RAW_BITS-1:0] cmd_levels,input wire [RAW_BITS-1:0] cmd_target,input wire cmd_blc_bypass,
 input wire [47:0] cmd_gains,input wire [191:0] cmd_matrix,input wire cmd_gamma_enable,
 input wire cmd_sobel_bypass,
 input wire lut_valid,output wire lut_ready,input wire [1:0] lut_channel,input wire [7:0] lut_address,lut_value,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [7:0] m_data,output wire m_sof,m_eol,m_eof,
 output wire [15:0] m_frame_id,output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height,
 output wire stats_valid,input wire stats_ready,output wire [47:0] sum_r,sum_g,sum_b,
 output wire [31:0] pixel_count,line_count,output wire [15:0] stats_frame_id,
 output wire stats_overflow,stats_protocol_error,input wire cmd_bayer_bypass
);
 reg active,reject,flush;
 reg [15:0] width,height;
 wire core_ready,gray_ready,core_rsp,gray_rsp,core_mv,core_mr,core_sof,core_eol,core_eof,gray_drained,core_lut_ready;
 wire [23:0] rgb;wire [15:0] rgb_id;wire [3:0] core_error,gray_error;
 wire valid_size=cmd_width>=5&&cmd_height>=5&&cmd_width<=MAX_WIDTH;
 wire launch=cmd_valid&&cmd_ready&&valid_size;
 wire done=rsp_valid&&rsp_ready;
 wire [9:0] luma_sum={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
 assign cmd_ready=rst_n&&!active&&!flush&&core_ready&&gray_ready;
 assign lut_ready=core_lut_ready&&!active&&!flush;
 assign rsp_valid=active&&(reject||(core_rsp&&(core_error!=0?gray_drained:gray_rsp)));
 assign rsp_error=reject?4'd1:core_error!=0?core_error:gray_error;
 assign out_width=width>=5?width-4:0;
 assign out_height=height>=5?height-4:0;
 isp_stream_with_statistics #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) color(
 .clk(clk),.rst_n(rst_n),.cmd_valid(launch),.cmd_ready(core_ready),
 .cmd_width(cmd_width),.cmd_height(cmd_height),.cmd_frame_id(cmd_frame_id),.cmd_pattern(cmd_pattern),
 .cmd_levels(cmd_levels),.cmd_target(cmd_target),.cmd_blc_bypass(cmd_blc_bypass),.cmd_bayer_bypass(cmd_bayer_bypass),.cmd_gains(cmd_gains),.cmd_matrix(cmd_matrix),.cmd_gamma_enable(cmd_gamma_enable),
 .lut_valid(lut_valid&&!active&&!flush),.lut_ready(core_lut_ready),.lut_channel(lut_channel),.lut_address(lut_address),.lut_value(lut_value),
 .s_valid(s_valid&&active&&!reject),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(core_mv),.m_ready(core_mr),.m_data(rgb),.m_sof(core_sof),.m_eol(core_eol),.m_eof(core_eof),.m_frame_id(rgb_id),
 .rsp_valid(core_rsp),.rsp_ready(done&&!reject),.rsp_error(core_error),.out_width(),.out_height(),
 .stats_valid(stats_valid),.stats_ready(stats_ready),.sum_r(sum_r),.sum_g(sum_g),.sum_b(sum_b),.pixel_count(pixel_count),.line_count(line_count),
 .stats_frame_id(stats_frame_id),.stats_overflow(stats_overflow),.stats_protocol_error(stats_protocol_error));
 gray_sobel_stream #(.MAX_WIDTH(MAX_WIDTH)) edge_stage(
 .clk(clk),.rst_n(rst_n&&!flush),.cmd_valid(launch),.cmd_ready(gray_ready),
 .cmd_width(cmd_width-16'd2),.cmd_height(cmd_height-16'd2),.cmd_frame_id(cmd_frame_id),.cmd_bypass(cmd_sobel_bypass),
 .s_valid(core_mv),.s_ready(core_mr),.s_data(luma_sum[9:2]),.s_sof(core_sof),.s_eol(core_eol),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_frame_id(m_frame_id),
 .rsp_valid(gray_rsp),.rsp_ready(done&&!reject),.rsp_error(gray_error),.out_width(),.out_height(),.drained(gray_drained));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;reject<=0;flush<=0;width<=0;height<=0;end
  else begin
   flush<=0;
   if(cmd_valid&&cmd_ready)begin active<=1;reject<=!valid_size;width<=cmd_width;height<=cmd_height;end
   if(done)begin active<=0;reject<=0;if(!reject&&core_error!=0)flush<=1;end
  end
 end
endmodule
