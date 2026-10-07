// ============================================================================
// feat_hog -- HOG 8x8-cell gradient-direction histogram, 4 bins (wave2 idx13).
//
// Per emitted 3x3 window (win3x3_gen contract) the gradient is a plain
// central difference:
//   dx = w5 - w3,  dy = w7 - w1        (signed, range +-255)
// Unsigned orientation (gradient and its negation are the same line):
//   u = |dx| ;  v = (dx < 0) ? -dy : dy ;  av = |v|
//   steep = (av >= u)
//   bin   = steep ? (v < 0 ? 2 : 1) : (v < 0 ? 3 : 0)
// (bin0 ~[0,45), bin1 ~[45,90], bin2 ~(90,135], bin3 ~(135,180); zero
//  gradient lands in bin1 -- documented behaviour, golden matches.)
// One vote per window into the 8x8 cell addressed by the window column/row
// counters; cell-column accumulators persist across the 8 rows of a cell
// band (4 accumulators of {b3,b2,b1,b0} = 4 x 32-bit regs, no RAM).  When
// column%8==7 AND row%8==7 the cell is complete: counts are packed into
// cell_bins = {b3,b2,b1,b0} and cell_valid pulses one beat later.
// 32x32 frame -> 16 cells emitted in row-major order.
// Shift/add only; no RAM, no multipliers.
// ============================================================================
module feat_hog #(
    parameter IMG_W = 32                     // must be a multiple of 8
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [31:0] cell_bins,            // [7:0]=b0 ... [31:24]=b3
    output reg         cell_valid,
    output reg         nl_out                // pulses with cell col 0 emit
);
    wire [7:0] w1 = win[15:8],  w3 = win[31:24], w4 = win[39:32];
    wire [7:0] w5 = win[47:40], w7 = win[63:56];

    wire signed [9:0] dx = $signed({2'b00, w5}) - $signed({2'b00, w3});
    wire signed [9:0] dy = $signed({2'b00, w7}) - $signed({2'b00, w1});

    wire [8:0] u  = dx[9] ? (~dx[8:0] + 9'd1) : dx[8:0];          // |dx|
    wire signed [9:0] v = dx[9] ? -dy : dy;                       // folded dy
    wire [8:0] av = v[9] ? (~v[8:0] + 9'd1) : v[8:0];             // |v|
    wire steep = (av >= u);
    wire [1:0] bin = steep ? (v[9] ? 2'd2 : 2'd1)
                           : (v[9] ? 2'd3 : 2'd0);

    reg [4:0]  x;                    // window column 0..IMG_W-1 (wraps)
    reg [4:0]  y;                    // window row (advances on x wrap)
    // per-cell-column accumulators: acc<cc> = {b3,b2,b1,b0} counts
    reg [31:0] acc0, acc1, acc2, acc3;

    wire [1:0]  cc  = x[4:3];        // current cell column
    wire [31:0] acc = (cc == 2'd0) ? acc0 :
                      (cc == 2'd1) ? acc1 :
                      (cc == 2'd2) ? acc2 : acc3;
    wire [31:0] acc_n = acc + (32'd1 << {bin, 3'b000});  // ++acc[bin*8 +: 8]
    wire        emit  = (x[2:0] == 3'd7) && (y[2:0] == 3'd7);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x          <= 5'd0;
            y          <= 5'd0;
            acc0       <= 32'd0;
            acc1       <= 32'd0;
            acc2       <= 32'd0;
            acc3       <= 32'd0;
            cell_bins  <= 32'd0;
            cell_valid <= 1'b0;
            nl_out     <= 1'b0;
        end else if (clk_en) begin
            cell_valid <= 1'b0;
            nl_out     <= 1'b0;
            if (win_valid) begin
                if (emit) begin
                    cell_bins  <= acc_n;
                    cell_valid <= 1'b1;
                    nl_out     <= (x == 5'd7);  // first cell of the band
                end
                case (cc)
                    2'd0: acc0 <= emit ? 32'd0 : acc_n;
                    2'd1: acc1 <= emit ? 32'd0 : acc_n;
                    2'd2: acc2 <= emit ? 32'd0 : acc_n;
                    default: acc3 <= emit ? 32'd0 : acc_n;
                endcase
                x <= new_line_out ? 5'd1 :
                     (x == IMG_W - 1) ? 5'd0 : x + 5'd1;
                if (x == IMG_W - 1) y <= y + 5'd1;
            end
        end
    end
endmodule
