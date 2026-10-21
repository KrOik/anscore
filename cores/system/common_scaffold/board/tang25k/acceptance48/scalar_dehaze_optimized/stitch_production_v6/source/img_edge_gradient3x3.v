// implementation_draft_unverified. KERNEL=0 Sobel, KERNEL=1 Prewitt.
// Signed Gx points right, Gy points down. Magnitude is abs(Gx)+abs(Gy).
// m_data = saturate(m_magnitude >> MAG_SHIFT); default preserves raw scale.
module img_edge_gradient3x3 #(
    parameter PIXEL_W = 8,
    parameter KERNEL = 0,
    parameter MAG_SHIFT = 0
)(
    input wire clk, rst_n, clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire signed [PIXEL_W+3:0] m_gx, m_gy,
    output wire [PIXEL_W+3:0] m_magnitude,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    localparam GRAD_W = PIXEL_W + 4;
    localparam BUS_W = PIXEL_W + 3*GRAD_W;
    wire [GRAD_W-1:0] p [0:8];
    wire [4*GRAD_W-1:0] sums_q;
    wire [2*GRAD_W-1:0] gradients_q;
    wire [GRAD_W-1:0] right_q, left_q, bottom_q, top_q;
    wire signed [GRAD_W-1:0] gx, gy;
    wire [GRAD_W-1:0] right_sum, left_sum, bottom_sum, top_sum;
    wire [GRAD_W-1:0] abs_gx, abs_gy, magnitude, scaled;
    wire [PIXEL_W-1:0] result;
    wire sums_valid, sums_ready, sums_sof, sums_eol;
    wire gradients_valid, gradients_ready, gradients_sof, gradients_eol;
    wire [BUS_W-1:0] packed_output;
    genvar i;
    generate
        for (i = 0; i < 9; i = i + 1) begin : taps
            assign p[i] = {4'b0, s_taps[i*PIXEL_W +: PIXEL_W]};
        end
    endgenerate
    // Stage 1: each positive/negative half of a convolution is a short sum.
    assign right_sum = p[2] + (p[5] << ((KERNEL == 0) ? 1 : 0)) + p[8];
    assign left_sum = p[0] + (p[3] << ((KERNEL == 0) ? 1 : 0)) + p[6];
    assign bottom_sum = p[6] + (p[7] << ((KERNEL == 0) ? 1 : 0)) + p[8];
    assign top_sum = p[0] + (p[1] << ((KERNEL == 0) ? 1 : 0)) + p[2];
    img_filter_stream_register #(.DATA_W(4*GRAD_W)) sums_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({right_sum,left_sum,bottom_sum,top_sum}), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(sums_q),
        .m_valid(sums_valid), .m_ready(sums_ready), .m_sof(sums_sof), .m_eol(sums_eol)
    );
    assign {right_q,left_q,bottom_q,top_q} = sums_q;
    // Stage 2: registered signed gradients. Full precision accompanies pixels.
    img_filter_stream_register #(.DATA_W(2*GRAD_W)) gradients_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({(right_q-left_q),(bottom_q-top_q)}), .s_valid(sums_valid), .s_ready(sums_ready),
        .s_sof(sums_sof), .s_eol(sums_eol), .m_data(gradients_q),
        .m_valid(gradients_valid), .m_ready(gradients_ready), .m_sof(gradients_sof), .m_eol(gradients_eol)
    );
    assign {gx,gy} = gradients_q;
    // Stage 3: L1 magnitude, shift and saturation; preserve baseline scaling.
    assign abs_gx = gx[GRAD_W-1] ? -gx : gx;
    assign abs_gy = gy[GRAD_W-1] ? -gy : gy;
    assign magnitude = abs_gx + abs_gy;
    assign scaled = magnitude >> MAG_SHIFT;
    assign result = (|scaled[GRAD_W-1:PIXEL_W]) ? {PIXEL_W{1'b1}} : scaled[PIXEL_W-1:0];
    img_filter_stream_register #(.DATA_W(BUS_W)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({gx, gy, magnitude, result}), .s_valid(gradients_valid), .s_ready(gradients_ready),
        .s_sof(gradients_sof), .s_eol(gradients_eol), .m_data(packed_output),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
    assign {m_gx, m_gy, m_magnitude, m_data} = packed_output;
`ifndef SYNTHESIS
    initial if (PIXEL_W < 1 || KERNEL < 0 || KERNEL > 1 || MAG_SHIFT < 0)
        $fatal(1, "img_edge_gradient3x3: unsupported parameter");
`endif
endmodule
