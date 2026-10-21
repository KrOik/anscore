// implementation_draft_unverified. Canny classification; NO connectivity pass.
// m_class: 0 non-edge, 1 weak, 2 strong, 3 invalid thresholds (low > high).
// cfg thresholds are sampled with each accepted magnitude.
module img_edge_double_threshold #(parameter MAG_W = 12)(
    input wire clk, rst_n, clk_en,
    input wire [MAG_W-1:0] s_data, cfg_low, cfg_high,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [1:0] m_class,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    wire [1:0] classification = cfg_low > cfg_high ? 2'd3 :
                               s_data >= cfg_high ? 2'd2 :
                               s_data >= cfg_low ? 2'd1 : 2'd0;
    img_filter_stream_register #(.DATA_W(2)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data(classification), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(m_class),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
