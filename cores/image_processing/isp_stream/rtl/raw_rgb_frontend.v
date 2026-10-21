// Compose manual streaming BLC with unchanged canonical synchronous Bayer core.
// Frame command precedes payload; one frame is in flight, border crop is explicit.
module raw_rgb_frontend #(parameter RAW_BITS=10,MAX_WIDTH=640)(
 input wire clk,rst_n,cfg_valid,output wire cfg_ready,
 input wire [15:0] cfg_width,cfg_height,cfg_frame_id,input wire [1:0] cfg_pattern,
 input wire [4*RAW_BITS-1:0] cfg_levels,input wire [RAW_BITS-1:0] cfg_target,input wire cfg_blc_bypass,
 input wire s_valid,output wire s_ready,input wire [RAW_BITS-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [23:0] m_data,
 output wire m_sof,m_eol,m_eof,output wire [15:0] m_frame_id,
 output wire rsp_valid,input wire rsp_ready,output wire [3:0] rsp_error,
 output wire [15:0] out_width,out_height,input wire cfg_bayer_bypass
);
 wire bc_ready,fc_ready,bc_sr,bc_mv,bc_mr,bc_sof,bc_eol;
 wire [RAW_BITS-1:0] bc_data;
 reg active,flush;
 reg [15:0] frame_id;
 reg [15:0] width,height,input_x,input_y;
 wire blc_reset=rst_n&&!flush;
 assign cfg_ready=bc_ready&&fc_ready;
 assign s_ready=active&&bc_sr;
 assign m_frame_id=frame_id;
 raw_black_level_stream #(.RAW_BITS(RAW_BITS)) black(
 .clk(clk),.rst_n(blc_reset),.cfg_valid(cfg_valid&&fc_ready),.cfg_ready(bc_ready),
 .cfg_pattern(cfg_pattern),.cfg_levels(cfg_levels),.cfg_target(cfg_target),.cfg_bypass(cfg_blc_bypass),
 .s_valid(s_valid&&active),.s_ready(bc_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_frame_id(frame_id),
 .m_valid(bc_mv),.m_ready(bc_mr),.m_data(bc_data),.m_sof(bc_sof),.m_eol(bc_eol));
 raw_bayer_mode_stream #(.RAW_BITS(RAW_BITS),.MAX_WIDTH(MAX_WIDTH)) bayer(
 .clk(clk),.rst_n(rst_n),.cmd_valid(cfg_valid&&bc_ready),.cmd_ready(fc_ready),
 .cmd_width(cfg_width),.cmd_height(cfg_height),.cmd_frame_id(cfg_frame_id),.cmd_pattern(cfg_pattern),.cmd_bypass(cfg_bayer_bypass),
 .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_error(rsp_error),.out_width(out_width),.out_height(out_height),
 .s_data(bc_data),.s_valid(bc_mv),.s_sof(bc_sof),.s_eol(bc_eol),.s_ready(bc_mr),
 .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_eof(m_eof),.m_frame_id(),.m_ready(m_ready));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin active<=0;flush<=0;frame_id<=0;width<=0;height<=0;input_x<=0;input_y<=0;end
  else begin
   flush<=0;
   if(cfg_valid&&cfg_ready)begin
    active<=cfg_width>=3&&cfg_height>=3&&cfg_width<=MAX_WIDTH;
    frame_id<=cfg_frame_id;
    width<=cfg_width;height<=cfg_height;input_x<=0;input_y<=0;
   end
   if(s_valid&&s_ready)begin
    if(input_x==width-1)begin
     input_x<=0;input_y<=input_y+1'b1;
     if(input_y==height-1)active<=0;
    end else input_x<=input_x+1'b1;
   end
   if(rsp_valid&&rsp_ready)begin active<=0;flush<=1;end
  end
 end
endmodule
