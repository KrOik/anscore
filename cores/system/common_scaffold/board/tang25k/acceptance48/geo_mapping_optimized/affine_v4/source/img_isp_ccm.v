// Signed Q6.10 3x3 matrix and integer bias. Four enabled-edge pipeline stages.
// Coefficient shadow/active and commit-on-accepted-SOF semantics are preserved.
module img_isp_ccm (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire [23:0] s_data, input wire s_valid, output wire s_ready,
    input wire s_sof, input wire s_eol,
    output reg [23:0] m_data, output reg m_valid, input wire m_ready,
    output reg m_sof, output reg m_eol,
    input wire cfg_we, input wire cfg_commit,
    input wire [3:0] cfg_index, input wire signed [15:0] cfg_value,
    output wire cfg_ready, output reg cfg_pending, output reg cfg_error
);
    reg signed [15:0] shadow [0:11];
    reg signed [15:0] active [0:11];
    wire signed [15:0] selected [0:11];
    wire apply = cfg_pending && s_sof;
    integer i;
    genvar n;

    generate for (n = 0; n < 12; n = n + 1) begin : coeff_select
        assign selected[n] = apply ? shadow[n] : active[n];
    end endgenerate

    // Ready propagates backward through the elastic stages. clk_en qualifies
    // the external ready and gates every state update, so stalls hold all data.
    reg s0_valid, s1_valid, s2_valid;
    wire s3_ready = !m_valid || m_ready;
    wire s2_ready = !s2_valid || s3_ready;
    wire s1_ready = !s1_valid || s2_ready;
    wire s0_ready = !s0_valid || s1_ready;
    assign s_ready = clk_en && s0_ready;
    assign cfg_ready = clk_en && !cfg_pending;

    // Stage 0: select the active/shadow matrix on an accepted SOF and capture
    // the input pixel, its 12 signed coefficients/biases, and markers.
    reg [23:0] s0_pixel;
    reg s0_sof, s0_eol;
    reg signed [15:0] s0_c0, s0_c1, s0_c2;
    reg signed [15:0] s0_c3, s0_c4, s0_c5;
    reg signed [15:0] s0_c6, s0_c7, s0_c8;
    reg signed [15:0] s0_bias0, s0_bias1, s0_bias2;

    // Stage 1: nine full-width signed products. A component is unsigned 8-bit;
    // zero-extension to 32 bits before multiply preserves [0,255], while the
    // coefficient is sign-extended from Q6.10. Every product fits signed 25b.
    reg signed [31:0] s1_p0, s1_p1, s1_p2;
    reg signed [31:0] s1_p3, s1_p4, s1_p5;
    reg signed [31:0] s1_p6, s1_p7, s1_p8;
    reg signed [15:0] s1_bias0, s1_bias1, s1_bias2;
    reg s1_sof, s1_eol;

    // Stage 2: one signed 32-bit sum per output row. The worst possible sum
    // of three 8x16-bit products is below 2^25, so no intermediate wrap occurs.
    reg signed [31:0] s2_sum0, s2_sum1, s2_sum2;
    reg signed [15:0] s2_bias0, s2_bias1, s2_bias2;
    reg s2_sof, s2_eol;

    function signed [31:0] multiply_u8_s16;
        input [7:0] pixel;
        input signed [15:0] coefficient;
        reg signed [31:0] pixel_ext;
        reg signed [31:0] coefficient_ext;
        begin
            pixel_ext = $signed({24'd0, pixel});
            coefficient_ext = {{16{coefficient[15]}}, coefficient};
            multiply_u8_s16 = pixel_ext * coefficient_ext;
        end
    endfunction

    function [7:0] round_bias_saturate;
        input signed [31:0] accumulator;
        input signed [15:0] bias;
        reg signed [31:0] rounded;
        reg signed [31:0] biased;
        begin
            // Keep the frozen reference's exact negative rounding behavior:
            // add +512, then arithmetic-shift by 10, then add integer bias.
            rounded = (accumulator + 32'sd512) >>> 10;
            biased = rounded + {{16{bias[15]}}, bias};
            if (biased < 0) round_bias_saturate = 8'd0;
            else if (biased > 255) round_bias_saturate = 8'd255;
            else round_bias_saturate = biased[7:0];
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s0_valid <= 1'b0;
            s1_valid <= 1'b0;
            s2_valid <= 1'b0;
            m_data <= 24'd0;
            m_valid <= 1'b0;
            m_sof <= 1'b0;
            m_eol <= 1'b0;
            cfg_pending <= 1'b0;
            cfg_error <= 1'b0;
            for (i = 0; i < 12; i = i + 1) begin
                shadow[i] <= ((i == 0) || (i == 4) || (i == 8)) ? 16'sd1024 : 16'sd0;
                active[i] <= ((i == 0) || (i == 4) || (i == 8)) ? 16'sd1024 : 16'sd0;
            end
        end else if (clk_en) begin
            if (cfg_we && cfg_ready) begin
                if (cfg_index < 12) shadow[cfg_index] <= cfg_value;
                else cfg_error <= 1'b1;
            end
            if (cfg_commit && cfg_ready) cfg_pending <= 1'b1;

            // Stage 3: round, add integer bias, saturate, and hold the output
            // register whenever downstream backpressure blocks this stage.
            if (s3_ready) begin
                m_valid <= s2_valid;
                if (s2_valid) begin
                    m_data <= {
                        round_bias_saturate(s2_sum0, s2_bias0),
                        round_bias_saturate(s2_sum1, s2_bias1),
                        round_bias_saturate(s2_sum2, s2_bias2)
                    };
                    m_sof <= s2_sof;
                    m_eol <= s2_eol;
                end
            end

            // Stage 2: preserve all three signed row sums and aligned metadata.
            if (s2_ready) begin
                s2_valid <= s1_valid;
                if (s1_valid) begin
                    s2_sum0 <= (s1_p0 + s1_p1) + s1_p2;
                    s2_sum1 <= (s1_p3 + s1_p4) + s1_p5;
                    s2_sum2 <= (s1_p6 + s1_p7) + s1_p8;
                    s2_bias0 <= s1_bias0;
                    s2_bias1 <= s1_bias1;
                    s2_bias2 <= s1_bias2;
                    s2_sof <= s1_sof;
                    s2_eol <= s1_eol;
                end
            end

            // Stage 1: nine parallel pixel-by-coefficient products.
            if (s1_ready) begin
                s1_valid <= s0_valid;
                if (s0_valid) begin
                    s1_p0 <= multiply_u8_s16(s0_pixel[23:16], s0_c0);
                    s1_p1 <= multiply_u8_s16(s0_pixel[15:8],  s0_c1);
                    s1_p2 <= multiply_u8_s16(s0_pixel[7:0],   s0_c2);
                    s1_p3 <= multiply_u8_s16(s0_pixel[23:16], s0_c3);
                    s1_p4 <= multiply_u8_s16(s0_pixel[15:8],  s0_c4);
                    s1_p5 <= multiply_u8_s16(s0_pixel[7:0],   s0_c5);
                    s1_p6 <= multiply_u8_s16(s0_pixel[23:16], s0_c6);
                    s1_p7 <= multiply_u8_s16(s0_pixel[15:8],  s0_c7);
                    s1_p8 <= multiply_u8_s16(s0_pixel[7:0],   s0_c8);
                    s1_bias0 <= s0_bias0;
                    s1_bias1 <= s0_bias1;
                    s1_bias2 <= s0_bias2;
                    s1_sof <= s0_sof;
                    s1_eol <= s0_eol;
                end
            end

            // Stage 0: only an accepted SOF may consume pending configuration.
            if (s0_ready) begin
                s0_valid <= s_valid;
                if (s_valid) begin
                    s0_pixel <= s_data;
                    s0_sof <= s_sof;
                    s0_eol <= s_eol;
                    s0_c0 <= selected[0]; s0_c1 <= selected[1]; s0_c2 <= selected[2];
                    s0_c3 <= selected[3]; s0_c4 <= selected[4]; s0_c5 <= selected[5];
                    s0_c6 <= selected[6]; s0_c7 <= selected[7]; s0_c8 <= selected[8];
                    s0_bias0 <= selected[9];
                    s0_bias1 <= selected[10];
                    s0_bias2 <= selected[11];
                    if (apply) begin
                        for (i = 0; i < 12; i = i + 1) active[i] <= shadow[i];
                        cfg_pending <= 1'b0;
                    end
                end
            end
        end
    end
endmodule
