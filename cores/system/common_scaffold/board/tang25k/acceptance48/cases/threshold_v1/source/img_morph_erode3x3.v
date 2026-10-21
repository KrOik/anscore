// implementation_draft_unverified. Grayscale erosion, unsigned minimum.
// Binary 0/all-ones images are supported by the same operation.
module img_morph_erode3x3 #(
    parameter PIXEL_W = 8, parameter [8:0] SE_MASK = 9'h1ff
)(
    input wire clk, rst_n, clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    img_filter_kernel3x3 #(.PIXEL_W(PIXEL_W), .OP(3), .SE_MASK(SE_MASK)) kernel (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_ready(s_ready), .s_sof(s_sof), .s_eol(s_eol),
        .m_data(m_data), .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
