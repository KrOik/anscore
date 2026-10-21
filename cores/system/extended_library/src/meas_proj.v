// ============================================================================
// meas_proj -- idx24 PRJ: row-sum / column-sum projections of a frame.
//
// Consumes one frame of the imgwin stream (new_line + IMG_W pix_valid beats
// per row, IMG_H rows; `fidx` accepted for interface uniformity, only the
// first frame seen is measured).  Input is an 8-bit pixel; for a binary mask
// feed 8'h00/8'h01 -- sums then stay <= IMG_W/IMG_H.
//
// Accumulates: rowsum per row (16-bit, stored per row), colsum[x] (16-bit,
// register array -- 32 x 16 DFF, no RAM needed at this size).
//
// Output stream after the frame ends, one byte per clk_en beat:
//   row sums y = 0..IMG_H-1   (lo byte, then hi byte)
//   col sums x = 0..IMG_W-1   (lo byte, then hi byte)
// `done` rises one beat after the last byte and holds.
//
// All registers clk_en gated (T2).  No multipliers.
// ============================================================================
module meas_proj #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter LW    = $clog2(IMG_W),
    parameter RW    = $clog2(IMG_H)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    input  wire [7:0]  fidx,
    output reg  [7:0]  out_byte,
    output reg         out_valid,
    output reg         done
);
    localparam NBYTES = 2*(IMG_W + IMG_H);

    reg  [LW-1:0]  x;
    reg  [RW-1:0]  y;
    reg  [7:0]     fidx_seen;
    reg  [15:0]    rowsum;
    reg  [15:0]    rows [0:IMG_H-1];
    reg  [15:0]    cols [0:IMG_W-1];

    reg            emitting;
    reg  [7:0]     emit_i;               // 0 .. NBYTES-1 (<=255 for 32+32)
    wire [6:0]     emit_n   = emit_i[7:1];
    // n < IMG_H -> rows[n]; else cols[n-IMG_H] == cols[n[LW-1:0]] since
    // n in [IMG_H, IMG_H+IMG_W) with IMG_H == IMG_W == 2^LW here.
    wire [15:0]    emit_val = (emit_n < IMG_H) ? rows[emit_n[RW-1:0]]
                                             : cols[emit_n[LW-1:0]];

    wire last_px = pix_valid && (x == IMG_W-1) && (y == IMG_H-1);

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x         <= {LW{1'b0}};
            y         <= {RW{1'b0}};
            fidx_seen <= 8'hFF;
            rowsum    <= 16'd0;
            for (k = 0; k < IMG_H; k = k + 1) rows[k] <= 16'd0;
            for (k = 0; k < IMG_W; k = k + 1) cols[k] <= 16'd0;
            emitting  <= 1'b0;
            emit_i    <= 8'd0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            out_valid <= 1'b0;
            // ---- raster position -------------------------------------------
            if (new_line) begin
                x <= {LW{1'b0}};
                if (fidx != fidx_seen) begin
                    y         <= {RW{1'b0}};
                    fidx_seen <= fidx;
                end else begin
                    y <= y + 1'b1;
                end
            end else if (pix_valid) begin
                x <= x + 1'b1;
            end
            // ---- accumulate --------------------------------------------------
            if (pix_valid) begin
                cols[x] <= cols[x] + {8'd0, pix};
                if (x == IMG_W-1) begin
                    rows[y] <= rowsum + {8'd0, pix};   // include last pixel
                    rowsum  <= 16'd0;
                end else begin
                    rowsum  <= rowsum + {8'd0, pix};
                end
            end
            // ---- frame end -> emit -------------------------------------------
            if (last_px) begin
                emitting <= 1'b1;
                emit_i   <= 8'd0;
            end
            if (emitting) begin
                out_valid <= 1'b1;
                out_byte  <= emit_i[0] ? emit_val[15:8] : emit_val[7:0];
                if (emit_i == NBYTES-1) begin
                    emitting <= 1'b0;
                    done     <= 1'b1;
                end else begin
                    emit_i <= emit_i + 8'd1;
                end
            end
        end
    end
endmodule
