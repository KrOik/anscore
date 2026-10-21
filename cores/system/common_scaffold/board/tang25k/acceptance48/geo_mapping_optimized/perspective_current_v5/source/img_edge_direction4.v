// implementation_draft_unverified. Quantize gradient to four image directions.
// tan(22.5 deg) approximated by 106/256. Boundary ties choose axial direction.
// Direction values match img_edge_nonmax3x3: 0=E/W,1=NW/SE,2=N/S,3=NE/SW.
module img_edge_direction4 #(parameter GRAD_W = 12)(
    input wire clk, rst_n, clk_en,
    input wire signed [GRAD_W-1:0] s_gx, s_gy,
    input wire s_valid, s_sof, s_eol, output wire s_ready,
    output wire [1:0] m_direction,
    output wire m_valid, m_sof, m_eol, input wire m_ready
);
    reg [GRAD_W-1:0] abs_gx, abs_gy;
    reg [GRAD_W+7:0] gx_256, gy_256, gx_106, gy_106;
    reg [1:0] direction;
    always @* begin
        abs_gx = s_gx[GRAD_W-1] ? -s_gx : s_gx;
        abs_gy = s_gy[GRAD_W-1] ? -s_gy : s_gy;
        gx_256 = {abs_gx, 8'd0}; gy_256 = {abs_gy, 8'd0};
        gx_106 = {{8{1'b0}}, abs_gx} * 8'd106;
        gy_106 = {{8{1'b0}}, abs_gy} * 8'd106;
        if (gy_256 <= gx_106) direction = 2'd0;
        else if (gx_256 <= gy_106) direction = 2'd2;
        else if (s_gx[GRAD_W-1] == s_gy[GRAD_W-1]) direction = 2'd1;
        else direction = 2'd3;
    end
    img_filter_stream_register #(.DATA_W(2)) output_register (
        .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
        .s_data(direction), .s_valid(s_valid), .s_ready(s_ready),
        .s_sof(s_sof), .s_eol(s_eol), .m_data(m_direction),
        .m_valid(m_valid), .m_ready(m_ready), .m_sof(m_sof), .m_eol(m_eol)
    );
endmodule
