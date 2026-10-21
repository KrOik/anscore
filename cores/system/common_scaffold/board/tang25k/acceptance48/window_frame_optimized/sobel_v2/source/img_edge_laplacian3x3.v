// implementation_draft_unverified. Four-neighbour Laplacian: 4*C-N-S-E-W.
// Preserve signed response; display output is saturated absolute response.
module img_edge_laplacian3x3 #(
    parameter PIXEL_W = 8,
    parameter MAG_SHIFT = 0
)(
    input wire clk, rst_n, clk_en,
    input wire [9*PIXEL_W-1:0] s_taps,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output wire [PIXEL_W-1:0] m_data,
    output wire signed [PIXEL_W+3:0] m_response,
    output wire m_valid, m_sof, m_eol,
    input wire m_ready
);
    localparam RESP_W = PIXEL_W + 4;
    reg signed [RESP_W-1:0] p [0:8];
    reg signed [RESP_W-1:0] response;
    reg [RESP_W-1:0] magnitude, scaled;
    reg [PIXEL_W-1:0] result;
    wire [RESP_W+PIXEL_W-1:0] packed_output;
    integer i;
    always @* begin
        for (i=0; i<9; i=i+1) p[i] = $signed({4'b0000, s_taps[i*PIXEL_W +: PIXEL_W]});
        response = (p[4] <<< 2) - p[1] - p[3] - p[5] - p[7];
        magnitude = response[RESP_W-1] ? -response : response;
        scaled = magnitude >> MAG_SHIFT;
        result = (|scaled[RESP_W-1:PIXEL_W]) ? {PIXEL_W{1'b1}} : scaled[PIXEL_W-1:0];
    end
    img_filter_stream_register #(.DATA_W(RESP_W+PIXEL_W)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data({response, result}), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(packed_output),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
    assign {m_response, m_data} = packed_output;
endmodule
