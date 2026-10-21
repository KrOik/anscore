// Complete bounded-frame patch-distance NLM with synchronous frame storage.
// cfg_h_q8 declares raw pixel amplitude in unsigned Q(PIXEL_W).8.
module img_filter_nlm #(parameter PIXEL_W=8,parameter MAX_WIDTH=64,parameter MAX_HEIGHT=64)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    input wire [15:0] cfg_width, cfg_height,
    input wire [7:0] cfg_patch_radius, cfg_search_radius,
    input wire [PIXEL_W+7:0] cfg_h_q8,
    output wire rsp_valid, input wire rsp_ready,
    output wire [7:0] rsp_tag, rsp_error,
    input wire [PIXEL_W-1:0] s_data,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    img_filter_nlm_serial_engine #(.PIXEL_W(PIXEL_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.OP(2)) frame (
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),.cmd_tag(cmd_tag),
        .cfg_width(cfg_width),.cfg_height(cfg_height),
        .cfg_structuring_element(9'h1ff),
        .cfg_patch_radius(cfg_patch_radius),.cfg_search_radius(cfg_search_radius),
        .cfg_h_q8(cfg_h_q8),
        .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),.rsp_error(rsp_error),
        .s_data(s_data),.s_valid(s_valid),.s_ready(s_ready),.s_sof(s_sof),.s_eol(s_eol),
        .m_data(m_data),.m_valid(m_valid),.m_ready(m_ready),.m_sof(m_sof),.m_eol(m_eol)
    );
endmodule
