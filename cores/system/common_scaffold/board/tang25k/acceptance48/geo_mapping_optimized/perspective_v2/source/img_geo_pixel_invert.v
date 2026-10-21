// Development draft; no simulation, synthesis, or board validation performed.
// Inversion is per packed unsigned pixel lane: max_value - sample.
module img_geo_pixel_invert #(
    parameter DATA_W = 24
)(
    input wire clk, rst_n, clk_en,
    input wire s_valid,
    output wire s_ready,
    input wire [DATA_W-1:0] s_data,
    input wire s_sof, s_eol,
    input wire s_invert,
    output reg m_valid,
    input wire m_ready,
    output reg [DATA_W-1:0] m_data,
    output reg m_sof, m_eol
);
assign s_ready = rst_n && (!m_valid || m_ready);
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        m_valid <= 1'b0;
        m_data <= 0;
        m_sof <= 0;
        m_eol <= 0;
    end else if (clk_en && s_ready) begin
        m_valid <= s_valid;
        if (s_valid) begin
            m_data <= s_invert ? ~s_data : s_data;
            m_sof <= s_sof;
            m_eol <= s_eol;
        end
    end
end
endmodule
