// Implementation draft, unverified. t = clamp(1 - omega*dark/A, 0, 1).
// t, omega and t0 use unsigned Q1.15 (unity = 32768). Controls are per-pixel
// metadata, supplied by an upstream frame-commit controller. Division is a
// direct combinational draft and has NOT been evaluated for area or timing.
module img_dh_transmission (
    input wire clk, rst_n, clk_en,
    input wire [7:0] s_dark, s_airlight_gray,
    input wire [23:0] s_rgb, s_airlight_rgb,
    input wire [15:0] s_omega, s_t0,
    input wire s_valid, s_sof, s_eol,
    output wire s_ready,
    output reg [15:0] m_t, m_t0,
    output reg [23:0] m_rgb, m_airlight_rgb,
    output reg m_valid, m_sof, m_eol,
    input wire m_ready,
    output wire unsupported,
    output reg error
);
    reg [31:0] loss;
    reg [15:0] t_value;
    assign unsupported = (s_airlight_gray == 0) || (s_omega > 16'd32768) ||
                         (s_t0 == 0) || (s_t0 > 16'd32768);
    assign s_ready = clk_en && (!m_valid || m_ready) && !unsupported;
    always @* begin
        loss = 0; t_value = 0;
        if (s_airlight_gray != 0) begin
            loss = (s_omega * s_dark + (s_airlight_gray >> 1)) / s_airlight_gray;
            t_value = (loss >= 32768) ? 16'd0 : (16'd32768 - loss);
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_t <= 0; m_t0 <= 1; m_rgb <= 0; m_airlight_rgb <= 0;
            m_valid <= 0; m_sof <= 0; m_eol <= 0; error <= 0;
        end else if (clk_en) begin
            if (s_valid && unsupported) error <= 1;
            if (!m_valid || m_ready) begin
                m_valid <= s_valid && !unsupported;
                if (s_valid && !unsupported) begin
                    m_t <= t_value; m_t0 <= s_t0;
                    m_rgb <= s_rgb; m_airlight_rgb <= s_airlight_rgb;
                    m_sof <= s_sof; m_eol <= s_eol;
                end
            end
        end
    end
endmodule
