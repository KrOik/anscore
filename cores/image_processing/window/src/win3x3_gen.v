// ============================================================================
// win3x3_gen -- streaming 3x3 sliding-window generator (the shared base for
// all imgwin_20k kernels; also exposed as its own IP).
//
// Stream contract (one beat = one clk_en-qualified clock):
//   * Each input row: a dedicated 1-beat `new_line` pulse (no pix_valid that
//     beat), then IMG_W `pix_valid` beats carrying `pix`, contiguous or sparse.
//   * Exactly IMG_H rows per frame. Extra rows are ignored once `done`.
//   * After the last pixel of a row the generator internally inserts one
//     virtual "phantom column" beat (right-edge replication), so it needs at
//     least one beat without pix_valid after the last pixel of a row -- the
//     new_line beat satisfies this naturally.
//   * After the last input row the generator auto-flushes one virtual row
//     (bottom-edge replication); no further input is required.
//
// Output: IMG_H x IMG_W windows, one per clk_en beat, emitted strictly in
//   row-major order (y = 0..IMG_H-1, x = 0..IMG_W-1). `win_valid` marks each
//   emitted window; `new_line_out` pulses on the first window of each output
//   row (x == 0); `done` rises after the last window of the frame.
//
// BORDER POLICY: edge replication (clamp). The window emitted for output
//   pixel (y,x) samples input image I at
//       tap(r,c) = I[ clamp(y+r-1,0,IMG_H-1) ][ clamp(x+c-1,0,IMG_W-1) ]
//   for r,c in {0,1,2}.  Top edge: row 0 duplicated into line buffer 1 during
//   the first input row. Left edge: oldest tap muxed to centre tap at emit
//   when x == 0. Right edge: phantom column re-shifts the newest tap. Bottom
//   edge: flush row feeds lb0 (last row) as the bottom tap again.
//
// Window bus layout (72 bits, LSB-first): win[i*8 +: 8] = tap(i), i = r*3+c,
//   i.e. win[7:0]=top-left ... win[71:64]=bottom-right.
//
// Timing: lb read address is issued on the pixel beat; taps/shift/emit run
// one beat later through a 1-deep pipeline, so lb_q is always aligned with
// the column being shifted. No combinational path through the RAMs.
// ============================================================================
module win3x3_gen #(
    parameter IMG_W = 16,
    parameter IMG_H = 16
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [71:0] win,
    output reg         win_valid,
    output reg         new_line_out,
    output reg         done
);
    localparam CW = (IMG_W + 2 > 1) ? $clog2(IMG_W + 2) : 1;  // counts 0..W+1
    localparam RW = (IMG_H + 1 > 1) ? $clog2(IMG_H + 1) : 1;  // counts 0..H
    localparam [CW-1:0] W_COL  = IMG_W;
    localparam [RW-1:0] H_ROW  = IMG_H;
    localparam [CW-1:0] W_LAST = IMG_W - 1;
    localparam LAW = (IMG_W > 1) ? $clog2(IMG_W) : 1;         // line-buf addr width

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    reg  [CW-1:0] in_col;        // 0..W-1 pixel col, W phantom slot, W+1 wait-nl
    reg  [RW-1:0] in_row;        // input row index (-1 until first new_line)
    reg           flushing;      // virtual bottom row in progress
    reg  [CW-1:0] fl_cnt;        // flush beat counter 0..W (W = phantom)

    // stage-A -> stage-B pipeline registers
    reg           sh_pend;       // a shift is pending this beat
    reg  [CW-1:0] col_d;         // column index of the pending shift
    reg  [RW-1:0] row_d;         // row index of the pending shift
    reg           ph_d;          // pending shift is a phantom (replicate) beat
    reg           sf_d;          // pending shift is a flush beat (bot = lb0_q)
    reg  [7:0]    pix_d;

    // 3-tap column shift registers per window row.
    // Lane map: [7:0] newest (col c) ... [23:16] oldest (col c-2).
    reg  [23:0]   rt0, rt1, rt2;

    // ------------------------------------------------------------------
    // stage-A source select
    // ------------------------------------------------------------------
    // pixels are consumed inside a row, or as an implicit row start in the
    // wait-for-new_line slot -- but never after the last input row (flush).
    wire take_pix   = pix_valid && !flushing && !done &&
                      ((in_col < IMG_W) ||
                       ((in_col == IMG_W + 1) && (in_row < IMG_H - 1)));
    wire cap_phant  = !flushing && !done && (in_col == IMG_W);
    wire wait_nl    = !flushing && !done && (in_col == IMG_W + 1);
    wire fl_issue   = flushing && (fl_cnt <= IMG_W);
    wire cap_any    = take_pix || cap_phant || fl_issue;

    // line-buffer read: issued on the capture beat, data used next beat
    wire           lb_re   = take_pix || (fl_issue && (fl_cnt < IMG_W));
    wire [CW-1:0]  lb_raddr = flushing ? fl_cnt :
                             (in_col == IMG_W + 1) ? {CW{1'b0}} : in_col;

    wire [8:0] lb0_q, lb1_q;

    // ------------------------------------------------------------------
    // stage-B combinational taps / emit
    // ------------------------------------------------------------------
    wire do_shift = sh_pend;

    wire [7:0] tap_top = ph_d ? rt0[7:0] : lb1_q[7:0];
    wire [7:0] tap_mid = ph_d ? rt1[7:0] : lb0_q[7:0];
    wire [7:0] tap_bot = ph_d ? rt2[7:0] : (sf_d ? lb0_q[7:0] : pix_d);

    wire [23:0] wn0 = {rt0[15:0], tap_top};
    wire [23:0] wn1 = {rt1[15:0], tap_mid};
    wire [23:0] wn2 = {rt2[15:0], tap_bot};

    // emit only for real output pixels: non-phantom needs col_d >= 1
    // (window centre x = col_d-1), every phantom emits x = W-1.  Row -1
    // (first input row, row_d == 0) and post-frame garbage are suppressed.
    wire          emit_ok = do_shift && !done &&
                            (row_d >= 1) && (row_d <= IMG_H) &&
                            (ph_d || (col_d >= 1));
    wire [CW-1:0] emit_x  = ph_d ? W_LAST : (col_d - 1'b1);

    // line-buffer write (combinational at the shift beat, sampled at edge)
    wire        lb_we   = do_shift && !ph_d && !sf_d;
    wire [8:0]  lb0_wd  = {1'b0, pix_d};
    wire [8:0]  lb1_wd  = (row_d == 0) ? {1'b0, pix_d} : lb0_q;

    line_buf_ram #(.DEPTH(IMG_W)) u_lb0 (
        .clk(clk), .clk_en(clk_en),
        .we(lb_we), .waddr(col_d[LAW-1:0]), .wdata(lb0_wd),
        .re(lb_re), .raddr(lb_raddr[LAW-1:0]), .q(lb0_q)
    );
    line_buf_ram #(.DEPTH(IMG_W)) u_lb1 (
        .clk(clk), .clk_en(clk_en),
        .we(lb_we), .waddr(col_d[LAW-1:0]), .wdata(lb1_wd),
        .re(lb_re), .raddr(lb_raddr[LAW-1:0]), .q(lb1_q)
    );

    // ------------------------------------------------------------------
    // sequential: stage-A capture + counters
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_col   <= {CW{1'b0}};
            in_row   <= {RW{1'b1}};            // -1: first new_line makes it 0
            flushing <= 1'b0;
            fl_cnt   <= {CW{1'b0}};
            done     <= 1'b0;
            sh_pend  <= 1'b0;
            col_d    <= {CW{1'b0}};
            row_d    <= {RW{1'b0}};
            ph_d     <= 1'b0;
            sf_d     <= 1'b0;
            pix_d    <= 8'd0;
        end else if (clk_en) begin
            if (take_pix) begin
                pix_d   <= pix;
                ph_d    <= 1'b0;
                sf_d    <= 1'b0;
                if (in_col >= IMG_W) begin
                    // implicit row start without new_line (contract fallback)
                    col_d  <= {CW{1'b0}};
                    row_d  <= in_row + 1'b1;
                    in_col <= {{CW-1{1'b0}}, 1'b1};
                    if (!new_line) in_row <= in_row + 1'b1;
                end else begin
                    col_d  <= in_col;
                    row_d  <= in_row;
                    in_col <= in_col + 1'b1;
                end
            end else if (cap_phant) begin
                // phantom column: replicate newest tap, emits x = W-1
                col_d  <= W_COL;
                row_d  <= in_row;
                ph_d   <= 1'b1;
                sf_d   <= 1'b0;
                in_col <= IMG_W + 1;
            end else if (fl_issue) begin
                col_d  <= (fl_cnt == IMG_W) ? W_COL : fl_cnt;
                row_d  <= H_ROW;
                ph_d   <= (fl_cnt == IMG_W);
                sf_d   <= 1'b1;
                fl_cnt <= fl_cnt + 1'b1;
            end
            sh_pend <= cap_any;

            // new_line wins over cap_phant for in_col: when nl lands on the
            // phantom slot the phantom is still captured (above) but the
            // next row starts cleanly at column 0 -- no double in_row bump
            if (new_line && !flushing && !done) begin
                in_col <= {CW{1'b0}};
                in_row <= in_row + 1'b1;
            end

            // enter the bottom-edge flush after the last row's phantom slot
            if (wait_nl && (in_row == IMG_H - 1)) begin
                flushing <= 1'b1;
                fl_cnt   <= {CW{1'b0}};
            end
            if (flushing && (fl_cnt == IMG_W + 1)) flushing <= 1'b0;

            // frame complete once the flush phantom window has shifted
            if (do_shift && ph_d && (row_d == IMG_H)) done <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // sequential: stage-B window shift + emit registers
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rt0          <= 24'd0;
            rt1          <= 24'd0;
            rt2          <= 24'd0;
            win          <= 72'd0;
            win_valid    <= 1'b0;
            new_line_out <= 1'b0;
        end else if (clk_en) begin
            if (do_shift) begin
                rt0 <= wn0;
                rt1 <= wn1;
                rt2 <= wn2;
                // left-edge replication: when emitting x==0 the oldest tap
                // is stale, so it takes the centre tap instead
                win[7:0]    <= (emit_x == 0) ? wn0[15:8] : wn0[23:16];
                win[15:8]   <= wn0[15:8];
                win[23:16]  <= wn0[7:0];
                win[31:24]  <= (emit_x == 0) ? wn1[15:8] : wn1[23:16];
                win[39:32]  <= wn1[15:8];
                win[47:40]  <= wn1[7:0];
                win[55:48]  <= (emit_x == 0) ? wn2[15:8] : wn2[23:16];
                win[63:56]  <= wn2[15:8];
                win[71:64]  <= wn2[7:0];
            end
            win_valid    <= emit_ok;
            new_line_out <= emit_ok && (emit_x == 0);
        end
    end
endmodule
