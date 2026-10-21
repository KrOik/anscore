// ============================================================================
// isp_awb -- gray-world auto white balance, streaming.
//
// Policy (documented per SPEC): gains are learned on the FLY from the frame
// currently streaming and applied to the NEXT frame.  While the first frame
// streams, gains hold their reset value 0x100 (1.0 in 2.8 fixed point), so
// frame 0 passes through unmodified; the learned gains take effect from the
// first pixel of frame 1 (stats latch on the last-pixel beat, the
// combinational divider settles during the new_line gap, gains register one
// beat later -- two beats before the next frame's first pixel).
//
//   sum_x  = Sigma channel over the frame (18 bits for NP <= 1024)
//   mean_x = sum_x >> log2(NP)              (NP must be a power of two)
//   gain_r = clamp((mean_g << 8) / mean_r, 10'h3FF);  mean==0 -> 0x3FF
//   out    = min(255, (pix * gain) >> 8)    applied to R and B; G passes.
//
// The divider is an unrolled 16-iteration restoring shift/subtract network
// and the pixel*gain product is a 10-term shift-add -- NO `*` operators, so
// zero DSPs (T4).  All registers clk_en gated (T2).
// ============================================================================
module isp_awb #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter NP    = IMG_W * IMG_H,             // must be a power of two
    parameter LGN   = $clog2(NP),
    parameter PW    = (NP > 1) ? $clog2(NP) : 1
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [23:0] pix24,        // {R,G,B}
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [23:0] pix24_out,    // {R',G,B'}
    output reg         out_valid,
    output reg         nl_out,
    output wire [9:0]  gain_r,       // learned gains (2.8), observability
    output wire [9:0]  gain_b
);
    localparam [PW-1:0] NP_M1 = NP - 1;

    // ------------------------------------------------------------------
    // combinational helpers (shift-add only)
    // ------------------------------------------------------------------
    // exact floor division (num<<8)/den saturated to 10 bits; den==0 -> max
    function [9:0] div_gain;
        input [7:0] num;
        input [7:0] den;
        integer i;
        reg [8:0]  rem;
        reg [15:0] q;
        reg [15:0] n;
        begin
            if (den == 8'd0) begin
                div_gain = 10'h3FF;
            end else begin
                n   = {num, 8'b0};
                rem = 9'd0;
                q   = 16'd0;
                for (i = 15; i >= 0; i = i - 1) begin
                    rem = {rem[7:0], n[i]};
                    if (rem >= {1'b0, den}) begin
                        rem  = rem - {1'b0, den};
                        q[i] = 1'b1;
                    end
                end
                div_gain = (q > 16'h03FF) ? 10'h3FF : q[9:0];
            end
        end
    endfunction

    // v * g >> 8 clamped to 8 bits; g is 2.8 fixed point, 10-term shift-add
    function [7:0] apply_gain;
        input [7:0] v;
        input [9:0] g;
        integer i;
        reg [17:0] p;
        begin
            p = 18'd0;
            for (i = 0; i < 10; i = i + 1)
                if (g[i]) p = p + ({10'd0, v} << i);
            apply_gain = (p[17:8] > 10'd255) ? 8'd255 : p[15:8];
        end
    endfunction

    // ------------------------------------------------------------------
    // frame statistics
    // ------------------------------------------------------------------
    reg [17:0] sum_r, sum_g, sum_b;      // NP*255 <= 2^18 for NP<=1024
    reg [PW-1:0] pcnt;
    reg [7:0]  mean_r, mean_g, mean_b;
    reg        upd;                      // gains update one beat after EOF
    reg [9:0]  gr, gb;

    assign gain_r = gr;
    assign gain_b = gb;

    wire [7:0] r_in = pix24[23:16];
    wire [7:0] g_in = pix24[15:8];
    wire [7:0] b_in = pix24[7:0];

    wire [9:0] gr_w = div_gain(mean_g, mean_r);
    wire [9:0] gb_w = div_gain(mean_g, mean_b);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sum_r      <= 18'd0;
            sum_g      <= 18'd0;
            sum_b      <= 18'd0;
            pcnt       <= {PW{1'b0}};
            mean_r     <= 8'd0;
            mean_g     <= 8'd0;
            mean_b     <= 8'd0;
            upd        <= 1'b0;
            gr         <= 10'h100;       // unity: first frame passes through
            gb         <= 10'h100;
            pix24_out  <= 24'd0;
            out_valid  <= 1'b0;
            nl_out     <= 1'b0;
        end else if (clk_en) begin
            // stream path (registered, one beat latency)
            pix24_out <= {apply_gain(r_in, gr), g_in, apply_gain(b_in, gb)};
            out_valid <= pix_valid;
            nl_out    <= new_line;
            // gain latch one beat after each end-of-frame
            if (upd) begin
                upd <= 1'b0;
                gr  <= gr_w;
                gb  <= gb_w;
            end
            // statistics
            if (pix_valid) begin
                if (pcnt == NP_M1) begin
                    mean_r <= (sum_r + {10'd0, r_in}) >> LGN;
                    mean_g <= (sum_g + {10'd0, g_in}) >> LGN;
                    mean_b <= (sum_b + {10'd0, b_in}) >> LGN;
                    sum_r  <= 18'd0;
                    sum_g  <= 18'd0;
                    sum_b  <= 18'd0;
                    pcnt   <= {PW{1'b0}};
                    upd    <= 1'b1;
                end else begin
                    sum_r <= sum_r + {10'd0, r_in};
                    sum_g <= sum_g + {10'd0, g_in};
                    sum_b <= sum_b + {10'd0, b_in};
                    pcnt  <= pcnt + 1'b1;
                end
            end
        end
    end
endmodule
