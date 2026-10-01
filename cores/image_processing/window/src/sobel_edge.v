// ============================================================================
// sobel_edge -- 3x3 Sobel edge detector.
//   Gx = (w2 + 2*w5 + w8) - (w0 + 2*w3 + w6)
//   Gy = (w6 + 2*w7 + w8) - (w0 + 2*w1 + w2)
//   mag = min(|Gx| + |Gy|, 255)   (saturating 8-bit)
//   bin = (mag >= THRESH)
// Shift-add only.  One clk_en beat latency.
// ============================================================================
module sobel_edge #(
    parameter [7:0] THRESH = 8'd96
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [7:0]  mag_out,
    output reg  [7:0]  bin_out,     // 8'hFF / 8'h00
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] w0 = win[7:0],    w1 = win[15:8],   w2 = win[23:16];
    wire [7:0] w3 = win[31:24],  w4 = win[39:32],  w5 = win[47:40];
    wire [7:0] w6 = win[55:48],  w7 = win[63:56],  w8 = win[71:64];

    // positive/negative halves, each <= 4*255 = 1020 (10 bits)
    wire [10:0] gx_p = {3'b0, w2} + ({3'b0, w5} << 1) + {3'b0, w8};
    wire [10:0] gx_n = {3'b0, w0} + ({3'b0, w3} << 1) + {3'b0, w6};
    wire [10:0] gy_p = {3'b0, w6} + ({3'b0, w7} << 1) + {3'b0, w8};
    wire [10:0] gy_n = {3'b0, w0} + ({3'b0, w1} << 1) + {3'b0, w2};

    wire [10:0] agx = (gx_p >= gx_n) ? (gx_p - gx_n) : (gx_n - gx_p);
    wire [10:0] agy = (gy_p >= gy_n) ? (gy_p - gy_n) : (gy_n - gy_p);
    wire [11:0] mag = {1'b0, agx} + {1'b0, agy};          // <= 2040
    wire [7:0]  mag8 = (mag > 12'd255) ? 8'd255 : mag[7:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mag_out   <= 8'd0;
            bin_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            mag_out   <= mag8;
            bin_out   <= (mag8 >= THRESH) ? 8'hFF : 8'h00;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
