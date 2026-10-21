// Implementation draft, unverified. The caller supplies an aligned, padded
// window of min(R,G,B) bytes. This module contains no line or frame buffers.
module img_dh_window_min #(
    parameter integer TAPS = 9,
    parameter integer META_WIDTH = 64
) (
    input wire clk, rst_n, clk_en,
    input wire [TAPS*8-1:0] s_window,
    input wire [23:0] s_rgb,
    input wire [META_WIDTH-1:0] s_meta,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [7:0] m_dark,
    output reg [23:0] m_rgb,
    output reg [META_WIDTH-1:0] m_meta,
    output reg m_valid, m_sof, m_eol,
    input wire m_ready
);
    integer i;
    reg [7:0] window_min;
    always @* begin
        window_min = 8'hff;
        for (i = 0; i < TAPS; i = i + 1)
            if (s_window[i*8 +: 8] < window_min)
                window_min = s_window[i*8 +: 8];
    end
    assign s_ready = clk_en && (!m_valid || m_ready);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_dark <= 0; m_rgb <= 0; m_meta <= 0;
            m_valid <= 0; m_sof <= 0; m_eol <= 0;
        end else if (clk_en && s_ready) begin
            m_valid <= s_valid;
            if (s_valid) begin
                m_dark <= window_min; m_rgb <= s_rgb; m_meta <= s_meta;
                m_sof <= s_sof; m_eol <= s_eol;
            end
        end
    end
endmodule
