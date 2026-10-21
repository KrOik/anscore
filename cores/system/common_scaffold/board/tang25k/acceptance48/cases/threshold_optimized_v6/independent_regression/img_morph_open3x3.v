// Complete two-pass bounded-frame opening using synchronous intermediate RAM.
module img_morph_open3x3 #(parameter PIXEL_W=8,parameter MAX_WIDTH=64,parameter MAX_HEIGHT=64)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width, cfg_height,
    input wire [8:0] cfg_structuring_element,
    output wire rsp_valid, input wire rsp_ready,
    output wire [7:0] rsp_tag, rsp_error,
    input wire [PIXEL_W-1:0] s_data,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    img_filter_frame_engine #(.PIXEL_W(PIXEL_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.OP(0)) frame (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_tag(cmd_tag),
        .cfg_width(cfg_width),.cfg_height(cfg_height),
        .cfg_structuring_element(cfg_structuring_element),
        .cfg_patch_radius(8'd0),.cfg_search_radius(8'd0),
        .cfg_h_q8({ {(PIXEL_W-1){1'b0}},9'd256 }),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),.rsp_error(rsp_error),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),
        .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol)
    );
endmodule
