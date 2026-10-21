// Implementation draft, unverified. J = sat8((I-A)/max(t,t0) + A).
// t and t0 are unsigned Q1.15. Signed division truncates toward zero.
// Three direct signed divisions are intentionally unoptimized development RTL.
module img_dh_restore (
    input wire clk, rst_n, clk_en,
    input wire [23:0] s_rgb, s_airlight_rgb,
    input wire [15:0] s_t, s_t0,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [23:0] m_data,
    output reg m_valid, m_sof, m_eol,
    input wire m_ready,
    output wire unsupported,
    output reg error
);
    wire [15:0] denominator = (s_t < s_t0) ? s_t0 : s_t;
    assign unsupported = (s_t > 16'd32768) || (s_t0 == 0) ||
                         (s_t0 > 16'd32768);
    assign s_ready = clk_en && (!m_valid || m_ready) && !unsupported;
    function [7:0] restore_channel;
        input [7:0] pixel, airlight;
        input [15:0] t_floor;
        reg signed [31:0] delta, numerator, divisor, result;
        begin
            delta = $signed({1'b0,pixel}) - $signed({1'b0,airlight});
            numerator = delta * 32'sd32768;
            divisor = $signed({1'b0,t_floor});
            result = 0;
            if (t_floor != 0)
                result = numerator / divisor + $signed({1'b0,airlight});
            if (result < 0) restore_channel = 0;
            else if (result > 255) restore_channel = 255;
            else restore_channel = result[7:0];
        end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0; error <= 0;
        end else if (clk_en) begin
            if (s_valid && unsupported) error <= 1;
            if (!m_valid || m_ready) begin
                m_valid <= s_valid && !unsupported;
                if (s_valid && !unsupported) begin
                    m_data <= {restore_channel(s_rgb[23:16],s_airlight_rgb[23:16],denominator),
                               restore_channel(s_rgb[15:8],s_airlight_rgb[15:8],denominator),
                               restore_channel(s_rgb[7:0],s_airlight_rgb[7:0],denominator)};
                    m_sof <= s_sof; m_eol <= s_eol;
                end
            end
        end
    end
endmodule
