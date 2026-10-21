// Approximate BT.601 full-range digital
// YCbCr (YUV naming), 4:4:4. RGB packed R:G:B; YUV packed Y:Cb:Cr.
module img_isp_colorspace (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire cfg_commit,
    input wire cfg_yuv_to_rgb,
    output wire cfg_ready, output reg cfg_pending
);
    reg shadow_direction, active_direction;
    wire apply = cfg_pending && s_sof;
    wire direction = apply ? shadow_direction : active_direction;
    assign s_ready = clk_en && (!m_valid || m_ready);
    assign cfg_ready = clk_en && !cfg_pending;

    function [7:0] clip;
        input signed [31:0] value;
        begin
            if (value < 0) clip = 0;
            else if (value > 255) clip = 255;
            else clip = value[7:0];
        end
    endfunction

    function [23:0] convert;
        input [23:0] pixel;
        input inverse;
        reg signed [31:0] c0, c1, c2, a, b, c;
        begin
            c0 = $signed({1'b0, pixel[23:16]});
            c1 = $signed({1'b0, pixel[15:8]});
            c2 = $signed({1'b0, pixel[7:0]});
            if (!inverse) begin
                a = (77*c0 + 150*c1 + 29*c2 + 128) >>> 8;
                b = ((-43*c0 - 85*c1 + 128*c2 + 128) >>> 8) + 128;
                c = ((128*c0 - 107*c1 - 21*c2 + 128) >>> 8) + 128;
            end else begin
                c1 = c1 - 128;
                c2 = c2 - 128;
                a = c0 + ((359*c2 + 128) >>> 8);
                b = c0 + ((-88*c1 - 183*c2 + 128) >>> 8);
                c = c0 + ((454*c1 + 128) >>> 8);
            end
            convert = {clip(a), clip(b), clip(c)};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_data <= 0; m_valid <= 0; m_sof <= 0; m_eol <= 0;
            cfg_pending <= 0; shadow_direction <= 0; active_direction <= 0;
        end else if (clk_en) begin
            if (cfg_we && cfg_ready) shadow_direction <= cfg_yuv_to_rgb;
            if (cfg_commit && cfg_ready) cfg_pending <= 1;
            if (s_ready) begin
                m_valid <= s_valid;
                if (s_valid) begin
                    m_data <= convert(s_data, direction);
                    m_sof <= s_sof; m_eol <= s_eol;
                    if (apply) begin
                        active_direction <= shadow_direction;
                        cfg_pending <= 0;
                    end
                end
            end
        end
    end
endmodule
