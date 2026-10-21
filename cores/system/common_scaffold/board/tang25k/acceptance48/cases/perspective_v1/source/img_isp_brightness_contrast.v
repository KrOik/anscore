// Candidate: three elastic stages, unchanged integer formula and SOF commit.
module img_isp_brightness_contrast (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire cfg_commit,
    input wire signed [9:0] cfg_brightness,
    input wire [15:0] cfg_contrast,
    output wire cfg_ready, output reg cfg_pending
);
    reg signed [9:0] shadow_brightness, active_brightness;
    reg [15:0] shadow_contrast, active_contrast;
    wire apply = cfg_pending && s_sof;
    wire signed [9:0] brightness = apply ? shadow_brightness : active_brightness;
    wire [15:0] contrast = apply ? shadow_contrast : active_contrast;
    reg input_valid, input_sof, input_eol;
    reg signed [8:0] delta_r, delta_g, delta_b;
    reg [15:0] gain_q;
    reg signed [9:0] offset_q;
    reg product_valid, product_sof, product_eol;
    reg signed [25:0] product_r, product_g, product_b;
    reg signed [9:0] product_offset;
    wire output_ready = !m_valid || m_ready;
    wire product_ready = !product_valid || output_ready;
    wire input_ready = !input_valid || product_ready;
    assign s_ready = clk_en && input_ready;
    assign cfg_ready = clk_en && !cfg_pending;

    function [7:0] finish;
        input signed [25:0] product;
        input signed [9:0] offset;
        reg signed [25:0] adjusted;
        begin
            // Signed 9-bit delta times positive 17-bit gain fits 26 bits.
            adjusted = ((product + 26'sd128) >>> 8) + 26'sd128 + offset;
            if (adjusted < 0) finish = 0;
            else if (adjusted > 255) finish = 255;
            else finish = adjusted[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0;
            input_valid <= 0; input_sof <= 0; input_eol <= 0;
            delta_r <= 0; delta_g <= 0; delta_b <= 0;
            gain_q <= 0; offset_q <= 0;
            product_valid <= 0; product_sof <= 0; product_eol <= 0;
            product_r <= 0; product_g <= 0; product_b <= 0; product_offset <= 0;
            shadow_brightness <= 0; active_brightness <= 0;
            shadow_contrast <= 256; active_contrast <= 256;
            cfg_pending <= 0;
        end else if (clk_en) begin
            if (cfg_we && cfg_ready) begin
                shadow_brightness <= cfg_brightness;
                shadow_contrast <= cfg_contrast;
            end
            if (cfg_commit && cfg_ready) cfg_pending <= 1;
            if (output_ready) begin
                m_valid <= product_valid;
                if (product_valid) begin
                    m_data <= {finish(product_r, product_offset),
                               finish(product_g, product_offset),
                               finish(product_b, product_offset)};
                    m_sof <= product_sof; m_eol <= product_eol;
                end
            end
            if (product_ready) begin
                product_valid <= input_valid;
                if (input_valid) begin
                    product_r <= delta_r * $signed({1'b0, gain_q});
                    product_g <= delta_g * $signed({1'b0, gain_q});
                    product_b <= delta_b * $signed({1'b0, gain_q});
                    product_offset <= offset_q;
                    product_sof <= input_sof; product_eol <= input_eol;
                end
            end
            if (input_ready) begin
                input_valid <= s_valid;
                if (s_valid) begin
                    delta_r <= $signed({1'b0, s_data[23:16]}) - 9'sd128;
                    delta_g <= $signed({1'b0, s_data[15:8]}) - 9'sd128;
                    delta_b <= $signed({1'b0, s_data[7:0]}) - 9'sd128;
                    gain_q <= contrast; offset_q <= brightness;
                    input_sof <= s_sof; input_eol <= s_eol;
                    if (apply) begin
                        active_brightness <= shadow_brightness;
                        active_contrast <= shadow_contrast;
                        cfg_pending <= 0;
                    end
                end
            end
        end
    end
endmodule
