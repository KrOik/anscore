// ============================================================================
// img_crop -- ROI crop streamer (wave2 unit idx19, TAG CRP).
//
// Consumes an imgwin-style stream (new_line beat, then IMG_W pix_valid beats
// per row, IMG_H rows) and emits only pixels inside the ROI
//     x0 <= x < x0+cw  &&  y0 <= y < y0+ch
// as a new stream: one new_line_out beat per output row, then the row's
// pixels.  x0,y0,cw,ch are presented as input registers (sampled
// combinationally -- hold them stable during the frame).
//
// Timing note: the input new_line beat carries no pixel, so new_line_out is
// emitted on the beat right after input new_line -- always ahead of the
// first pixel of that row, no buffering required.  ROI is clipped
// automatically: columns/rows past the image edge simply never occur.
// Requires cw,ch >= 1.
// ============================================================================
module img_crop #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter LW    = $clog2(IMG_W),
    parameter LH    = $clog2(IMG_H)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  x0,
    input  wire [7:0]  y0,
    input  wire [7:0]  cw,
    input  wire [7:0]  ch,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         new_line_out,
    output reg         done
);
    reg [LW-1:0] x;
    reg [LH-1:0] y;
    reg          in_frame;
    reg  [1:0]   fin;            // drain shift after last input pixel

    // upcoming row index at a new_line beat (first new_line -> row 0)
    wire [15:0]   y_next = in_frame ? ({11'd0, y} + 16'd1) : 16'd0;
    wire          nl_roi = (y_next >= {8'd0, y0}) &&
                           (y_next <  {8'd0, y0} + {8'd0, ch});
    wire [15:0]   x_end  = {8'd0, x0} + {8'd0, cw};
    wire [15:0]   y_end  = {8'd0, y0} + {8'd0, ch};
    wire          in_roi = ({11'd0, x} >= {8'd0, x0}) &&
                           ({11'd0, x} <  x_end) &&
                           ({11'd0, y} >= {8'd0, y0}) &&
                           ({11'd0, y} <  y_end);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x            <= {LW{1'b0}};
            y            <= {LH{1'b0}};
            in_frame     <= 1'b0;
            fin          <= 2'd0;
            pix_out      <= 8'd0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            done         <= 1'b0;
        end else if (clk_en) begin
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            if (new_line) begin
                x <= {LW{1'b0}};
                if (!in_frame) begin
                    in_frame <= 1'b1;            // y stays 0 = row 0
                end else begin
                    y <= y + 1'b1;
                end
                if (nl_roi) new_line_out <= 1'b1;
            end else if (pix_valid) begin
                if (in_roi) begin
                    pix_out   <= pix;
                    out_valid <= 1'b1;
                end
                if (x == IMG_W-1) begin
                    if (y == IMG_H-1) fin <= 2'd1;
                    x <= {LW{1'b0}};
                end else begin
                    x <= x + 1'b1;
                end
            end
            if (fin != 2'd0) begin
                fin <= fin + 2'd1;               // drain: 2 beats for last
                if (fin == 2'd2) done <= 1'b1;   //   out_valid to retire
            end
        end
    end
endmodule
