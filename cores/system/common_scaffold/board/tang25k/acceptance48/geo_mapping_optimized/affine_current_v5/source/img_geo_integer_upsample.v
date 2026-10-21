// Functional integer bilinear upsampling;
// NOT a learned super-resolution model. Synchronous internal frame storage.
module img_geo_integer_upsample #(
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
// A 16-bit dimension times the 4-bit scale (0..15) needs at most 20 bits.
wire [19:0] dest_w=cfg_width*cfg_scale,dest_h=cfg_height*cfg_scale;
// Invalid scale/packing uses the finite configuration error path.
wire invalid=cfg_scale==0 || dest_w>20'd65535 || dest_h>20'd65535 || DATA_W!=PIXEL_W*LANES;
img_geo_frame_buffered #(.PIXEL_W(PIXEL_W),.LANES(LANES),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) impl (
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(cfg_valid),.cfg_ready(cfg_ready),.cfg_tag(cfg_tag),
 .cfg_mode(4'd1),.cfg_filter(2'd1),.cfg_src_width(invalid?16'd0:cfg_width),.cfg_src_height(cfg_height),
 .cfg_dst_width(dest_w[15:0]),.cfg_dst_height(dest_h[15:0]),
 .cfg_h00(32'sd65536),.cfg_h01(32'sd0),.cfg_h02(32'sd0),.cfg_h10(32'sd0),.cfg_h11(32'sd65536),.cfg_h12(32'sd0),
 .cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd65536),
 .busy(),.rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),.rsp_error(rsp_error),.rsp_pixels(),
 .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_error(),.m_sof(m_sof),.m_eol(m_eol),.m_eof()
);
endmodule

