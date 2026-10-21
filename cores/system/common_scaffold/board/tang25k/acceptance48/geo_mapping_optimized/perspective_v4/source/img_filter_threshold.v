// implementation_draft_unverified. Configuration sampled per accepted pixel.
// select = (s_data >= cfg_threshold) XOR cfg_invert; outputs 0 or all ones.
module img_filter_threshold #(parameter PIXEL_W = 8)(
    input wire clk, rst_n, clk_en,
    input wire [PIXEL_W-1:0] s_data,
    input wire [PIXEL_W-1:0] cfg_threshold,
    input wire cfg_invert,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    wire selected = (s_data >= cfg_threshold) ^ cfg_invert;
    img_filter_stream_register #(.DATA_W(PIXEL_W), .PIPE_STAGES(3)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({PIXEL_W{selected}}), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(m_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
