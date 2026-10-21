// implementation_draft_unverified. Canny non-maximum suppression stage only.
// Inputs are nine gradient magnitudes and the CENTER's quantized direction:
// 0 = horizontal, 1 = NW/SE, 2 = vertical, 3 = NE/SW in image coordinates.
// Ties are retained. Direction quantization and magnitude window are external.
module img_edge_nonmax3x3 #(parameter MAG_W = 12)(
    input wire clk, rst_n, clk_en,
    input wire [9*MAG_W-1:0] s_taps,
    input wire [1:0] s_direction,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [MAG_W-1:0] m_data,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    wire [MAG_W-1:0] center = s_taps[4*MAG_W +: MAG_W];
    reg [MAG_W-1:0] first, second, result;
    always @* begin
        first = {MAG_W{1'b0}}; second = {MAG_W{1'b0}};
        case (s_direction)
            2'd0: begin first=s_taps[3*MAG_W +: MAG_W]; second=s_taps[5*MAG_W +: MAG_W]; end
            2'd1: begin first=s_taps[0*MAG_W +: MAG_W]; second=s_taps[8*MAG_W +: MAG_W]; end
            2'd2: begin first=s_taps[1*MAG_W +: MAG_W]; second=s_taps[7*MAG_W +: MAG_W]; end
            2'd3: begin first=s_taps[2*MAG_W +: MAG_W]; second=s_taps[6*MAG_W +: MAG_W]; end
        endcase
        result = (center >= first && center >= second) ? center : {MAG_W{1'b0}};
    end
    img_filter_stream_register #(.DATA_W(MAG_W)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data(result), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(m_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
