// Implementation draft, unverified. RGB888 -> min(R,G,B), with RGB sidecar.
// Shared CE: transfers occur only on clk_en && valid && ready.
module img_dh_rgb_min (
    input wire clk, rst_n, clk_en,
    input wire [23:0] s_data,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [7:0] m_dark,
    output reg [23:0] m_rgb,
    output reg m_valid, m_sof, m_eol,
    input wire m_ready
);
    wire [7:0] rg_min = (s_data[23:16] < s_data[15:8]) ?
                            s_data[23:16] : s_data[15:8];
    assign s_ready = clk_en && (!m_valid || m_ready);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_dark <= 0; m_rgb <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0;
        end else if (clk_en && s_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_dark <= (rg_min < s_data[7:0]) ? rg_min : s_data[7:0];
                m_rgb <= s_data; m_sof <= s_sof; m_eol <= s_eol;
            end
        end
    end
endmodule
