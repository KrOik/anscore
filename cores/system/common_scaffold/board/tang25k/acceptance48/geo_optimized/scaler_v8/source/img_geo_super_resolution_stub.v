// Legacy module name, retained for source compatibility. The implementation is
// integer bilinear upsampling, not learned/model-based super-resolution.
module img_geo_super_resolution_stub #(
 parameter DATA_W=24,TAG_W=8,PIXEL_W=8,LANES=DATA_W/PIXEL_W,
 parameter MAX_WIDTH=64,MAX_HEIGHT=64
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,input wire [TAG_W-1:0] cfg_tag,
 input wire [15:0] cfg_width,cfg_height,input wire [3:0] cfg_scale,
 output wire rsp_valid,input wire rsp_ready,output wire [TAG_W-1:0] rsp_tag,output wire [3:0] rsp_error,
 input wire s_valid,output wire s_ready,input wire [DATA_W-1:0] s_data,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,output wire [DATA_W-1:0] m_data,output wire m_sof,m_eol
);
img_geo_integer_upsample #(.DATA_W(DATA_W),.TAG_W(TAG_W),.PIXEL_W(PIXEL_W),.LANES(LANES),
 .MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) impl (
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_tag(cfg_tag),
 .cfg_width(cfg_width),.cfg_height(cfg_height),.cfg_scale(cfg_scale),
 .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),.rsp_error(rsp_error),
 .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_sof(m_sof),.m_eol(m_eol)
);
endmodule
