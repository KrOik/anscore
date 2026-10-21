// ============================================================================
// canny_grad -- wave2 idx6 (CGR): Sobel gradient magnitude + direction,
// first stage of the Canny edge-detector chain.
//
//   Input  : image stream, input-side convention (per row: 1 dedicated
//            new_line beat without pix_valid, then IMG_W pix_valid+pix beats).
//            Feeds the shared win3x3_gen window generator internally.
//   Output : per input pixel (one clk_en beat after each emitted window):
//              mag_out[7:0] = min(|Gx| + |Gy|, 255)     -- saturated L1 mag
//              dir_out[1:0] = gradient orientation class:
//                0 = ~0deg   (8*|Gy| <= 3*|Gx|, |Gx| dominant)
//                2 = ~90deg  (8*|Gx| <= 3*|Gy|, |Gy| dominant)
//                1 = ~45deg  (diagonal, sign(Gx) == sign(Gy))
//                3 = ~135deg (diagonal, opposite signs)
//              Both axis tests can only hold simultaneously when Gx=Gy=0,
//              which resolves to dir 0 (0deg check has priority).
//              out_valid / nl_out flag the stream (nl_out coincides with the
//              first valid pixel of each output row -- output-side convention);
//              done rises with the last output beat and holds.
//   Window : edge replication (clamp) via win3x3_gen.
//
// All arithmetic is shift/add (T4); every register is clk_en gated (T2).
// ============================================================================
module canny_grad #(
    parameter IMG_W = 32,
    parameter IMG_H = 32
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [7:0]  mag_out,
    output reg  [1:0]  dir_out,
    output reg         out_valid,
    output reg         nl_out,
    output reg         done
);
    // ------------------------------------------------------------------
    // 3x3 window source (edge-replicated, row-major emit)
    // ------------------------------------------------------------------
    wire [71:0] win;
    wire        win_valid, win_nlo, win_done;

    win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_win (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n),
        .pix(pix), .pix_valid(pix_valid), .new_line(new_line),
        .win(win), .win_valid(win_valid), .new_line_out(win_nlo),
        .done(win_done)
    );

    // ------------------------------------------------------------------
    // Sobel gradients (shift-add only)
    //   Gx = (w2 + 2*w5 + w8) - (w0 + 2*w3 + w6)   right col - left col
    //   Gy = (w6 + 2*w7 + w8) - (w0 + 2*w1 + w2)   bottom row - top row
    // ------------------------------------------------------------------
    wire [7:0] w0 = win[7:0],    w1 = win[15:8],   w2 = win[23:16];
    wire [7:0] w3 = win[31:24],                     w5 = win[47:40];
    wire [7:0] w6 = win[55:48],  w7 = win[63:56],  w8 = win[71:64];

    wire [10:0] gx_p = {3'b0, w2} + ({3'b0, w5} << 1) + {3'b0, w8};
    wire [10:0] gx_n = {3'b0, w0} + ({3'b0, w3} << 1) + {3'b0, w6};
    wire [10:0] gy_p = {3'b0, w6} + ({3'b0, w7} << 1) + {3'b0, w8};
    wire [10:0] gy_n = {3'b0, w0} + ({3'b0, w1} << 1) + {3'b0, w2};

    wire        gx_neg = (gx_p <  gx_n);
    wire        gy_neg = (gy_p <  gy_n);
    wire [10:0] agx    = gx_neg ? (gx_n - gx_p) : (gx_p - gx_n);
    wire [10:0] agy    = gy_neg ? (gy_n - gy_p) : (gy_p - gy_n);

    wire [11:0] mag  = {1'b0, agx} + {1'b0, agy};            // <= 2040
    wire [7:0]  mag8 = (mag > 12'd255) ? 8'd255 : mag[7:0];

    // dominant-axis direction compare: tan(22.5deg) ~= 3/8
    wire [13:0] agy8 = {3'b0, agy} << 3;
    wire [13:0] agx8 = {3'b0, agx} << 3;
    wire [13:0] agx3 = {3'b0, agx} + ({3'b0, agx} << 1);
    wire [13:0] agy3 = {3'b0, agy} + ({3'b0, agy} << 1);

    wire [1:0] dir_c = (agy8 <= agx3) ? 2'd0 :
                       (agx8 <= agy3) ? 2'd2 :
                       (gx_neg == gy_neg) ? 2'd1 : 2'd3;

    // ------------------------------------------------------------------
    // registered output stage (1 clk_en beat after the window)
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mag_out   <= 8'd0;
            dir_out   <= 2'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            mag_out   <= mag8;
            dir_out   <= dir_c;
            out_valid <= win_valid;
            nl_out    <= win_nlo;
            done      <= win_done;
        end
    end
endmodule
