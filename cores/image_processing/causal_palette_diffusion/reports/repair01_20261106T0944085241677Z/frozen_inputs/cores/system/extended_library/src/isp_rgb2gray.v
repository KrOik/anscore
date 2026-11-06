// ============================================================================
// isp_rgb2gray -- BT.601 luma from RGB888, streaming.
//   Y = (77*R + 150*G + 29*B) >> 8          (coefficients sum to 256 -> [0,255])
// 77 = 64+8+4+1, 150 = 128+16+4+2, 29 = 16+8+4+1 -- shift-add only (T4).
// Registered output, one clk_en beat latency.  All registers clk_en gated.
// ============================================================================
module isp_rgb2gray (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [23:0] pix24,        // {R,G,B}
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] r = pix24[23:16];
    wire [7:0] g = pix24[15:8];
    wire [7:0] b = pix24[7:0];

    wire [16:0] ys = (r << 6) + (r << 3) + (r << 2) + r
                   + (g << 7) + (g << 4) + (g << 2) + (g << 1)
                   + (b << 4) + (b << 3) + (b << 2) + b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= ys[16:8];
            out_valid <= pix_valid;
            nl_out    <= new_line;
        end
    end
endmodule
