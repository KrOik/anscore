// implementation_draft_unverified. See img_edge_gradient3x3 for scaling.
module img_edge_prewitt3x3 #(parameter PIXEL_W = 8, parameter MAG_SHIFT = 0)(
    input wire clk, rst_n, clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire signed [PIXEL_W+3:0] m_gx, m_gy,
    output wire [PIXEL_W+3:0] m_magnitude,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    img_edge_gradient3x3 #(.PIXEL_W(PIXEL_W), .KERNEL(1), .MAG_SHIFT(MAG_SHIFT)) kernel (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en), .s_taps(s_taps),
        .s_valid(s_valid), .s_ready(s_ready), .s_sof(s_sof), .s_eol(s_eol),
        .m_data(m_data), .m_gx(m_gx), .m_gy(m_gy), .m_magnitude(m_magnitude),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
