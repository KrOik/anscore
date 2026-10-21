// ============================================================================
// mot_bbox -- idx22 BBOX: per-frame bounding box + pixel count of a binary
// mask stream (motion/blob measurement).
//
// Consumes a mask stream (imgwin contract: new_line beat then IMG_W pix_valid
// beats per row; `fidx` marks the frame).  A pixel counts as foreground when
// pix[0] == 1.  On the last pixel of each received frame the running stats are
// snapshotted and a 6-byte record is emitted, one byte per clk_en beat:
//     minx, miny, maxx, maxy, count_lo, count_hi
// (all coordinates 5-bit zero-extended; count is 16-bit, <= IMG_W*IMG_H).
// An empty frame emits six 0x00 bytes.
//
// `done` rises after the record of the NFR-th received frame and holds.
// Emit overlaps the next frame's stream safely (snapshot regs).
// All registers clk_en gated (T2).  No multipliers.
// ============================================================================
module mot_bbox #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter NFR   = 2,               // number of mask frames to expect
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
    reg  [LW-1:0]  x;
    reg  [RW-1:0]  y;
    reg  [7:0]     fidx_seen;

    // running stats for the current frame
    reg  [LW-1:0]  minx, maxx;
    reg  [RW-1:0]  miny, maxy;
    reg  [15:0]    cnt;

    // snapshot regs for the record being emitted
    reg  [7:0]     e_minx, e_miny, e_maxx, e_maxy;
    reg  [15:0]    e_cnt;
    reg            emitting;
    reg  [2:0]     emit_i;
    reg  [7:0]     fr_done;

    wire last_px = pix_valid && (x == IMG_W-1) && (y == IMG_H-1);
    wire hit     = pix_valid && pix[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x         <= {LW{1'b0}};
            y         <= {RW{1'b0}};
            fidx_seen <= 8'hFF;
            minx      <= {LW{1'b0}};
            maxx      <= {LW{1'b0}};
            miny      <= {RW{1'b0}};
            maxy      <= {RW{1'b0}};
            cnt       <= 16'd0;
            e_minx    <= 8'd0; e_miny <= 8'd0;
            e_maxx    <= 8'd0; e_maxy <= 8'd0;
            e_cnt     <= 16'd0;
            emitting  <= 1'b0;
            emit_i    <= 3'd0;
            fr_done   <= 8'd0;
            out_byte  <= 8'd0;
            out_valid <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            out_valid <= 1'b0;
            // ---- raster position tracking ----------------------------------
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
            // ---- accumulate -------------------------------------------------
            if (hit) begin
                cnt <= cnt + 16'd1;
                if (cnt == 16'd0) begin
                    minx <= x; maxx <= x;
                    miny <= y; maxy <= y;
                end else begin
                    if (x < minx) minx <= x;
                    if (x > maxx) maxx <= x;
                    if (y < miny) miny <= y;
                    if (y > maxy) maxy <= y;
                end
            end
            // ---- frame end: snapshot + start record emit --------------------
            if (last_px) begin
                emitting <= 1'b1;
                emit_i   <= 3'd0;
                if (hit) begin
                    // fold the last (foreground) pixel into the snapshot
                    e_minx <= {3'd0, ((cnt == 0) || (x < minx)) ? x : minx};
                    e_miny <= {3'd0, ((cnt == 0) || (y < miny)) ? y : miny};
                    e_maxx <= {3'd0, ((cnt == 0) || (x > maxx)) ? x : maxx};
                    e_maxy <= {3'd0, ((cnt == 0) || (y > maxy)) ? y : maxy};
                    e_cnt  <= cnt + 16'd1;
                end else if (cnt == 16'd0) begin
                    e_minx <= 8'd0; e_miny <= 8'd0;
                    e_maxx <= 8'd0; e_maxy <= 8'd0;
                    e_cnt  <= 16'd0;
                end else begin
                    e_minx <= {3'd0, minx};
                    e_miny <= {3'd0, miny};
                    e_maxx <= {3'd0, maxx};
                    e_maxy <= {3'd0, maxy};
                    e_cnt  <= cnt;
                end
                // clear stats for the next frame
                minx <= {LW{1'b0}}; maxx <= {LW{1'b0}};
                miny <= {RW{1'b0}}; maxy <= {RW{1'b0}};
                cnt  <= 16'd0;
            end
            // ---- record serializer ------------------------------------------
            if (emitting) begin
                out_valid <= 1'b1;
                case (emit_i)
                    3'd0: out_byte <= e_minx;
                    3'd1: out_byte <= e_miny;
                    3'd2: out_byte <= e_maxx;
                    3'd3: out_byte <= e_maxy;
                    3'd4: out_byte <= e_cnt[7:0];
                    3'd5: out_byte <= e_cnt[15:8];
                    default: out_byte <= 8'd0;
                endcase
                if (emit_i == 3'd5) begin
                    emitting <= 1'b0;
                    fr_done  <= fr_done + 8'd1;
                    if (fr_done == (NFR-1))
                        done <= 1'b1;
                end else begin
                    emit_i <= emit_i + 3'd1;
                end
            end
        end
    end
endmodule
