// ============================================================================
// bnn_conv3x3 -- binarised 3x3 convolution kernel (wave2 unit idx35, TAG BC3).
//
// Input : 1-bit pixel stream in the imgwin contract: per row one new_line
//         beat (no pix_valid), then IMG_W pix_valid beats; IMG_H rows per
//         frame.  Single frame per reset (done latches).
// Core  : two IMG_W-bit shift-register line buffers (no RAM -- 1-bit data
//         keeps it cheap) + 3-tap column shift regs per window row.
//         Per output position: win9 = XNOR vs packed weight word, popcount,
//         compare against per-channel threshold -> NCH output bits.
// Output: IMG_W*IMG_H windows in strict row-major order (oy = 0..IMG_H-1,
//         ox = 0..IMG_W-1), out_valid one clk_en beat each; out_nl pulses on
//         ox==0; done rises with the last emitted window.
//
// BORDER POLICY: edge replication (clamp), identical to win3x3_gen:
//   tap(r,c) = I[ clamp(oy+r-1,0,IMG_H-1) ][ clamp(ox+c-1,0,IMG_W-1) ]
//   win9[i] = tap(r,c), i = r*3+c  (win9[0]=top-left ... win9[8]=bot-right)
// Right edge uses a phantom column beat after the last pixel of a row;
// bottom edge uses a phantom flush row of IMG_W+1 beats after the last
// input row.  Top edge substitutes mid-lane taps at emit (oy==0).
//
// Weights/thresholds are plain config inputs (constant or register driven):
//   wcfg [ch*9 +: 9] = channel ch weight word (bit i matches win9[i])
//   thcfg[ch*4 +: 4] = channel ch threshold 0..9
//   out[ch] = (popcount(~(win9 ^ w9_ch)) >= thr_ch)
//
// All registers clk_en gated (T2).  No multipliers, no RAM.
// ============================================================================
module bnn_conv3x3 #(
    parameter IMG_W = 16,
    parameter IMG_H = 16,
    parameter NCH   = 2
)(
    input  wire             clk,
    input  wire             clk_en,
    input  wire             rst_n,
    input  wire             pix,
    input  wire             pix_valid,
    input  wire             new_line,
    input  wire [NCH*9-1:0] wcfg,
    input  wire [NCH*4-1:0] thcfg,
    output reg  [NCH-1:0]   out,
    output reg              out_valid,
    output reg              out_nl,
    output reg              done
);
    localparam CW = (IMG_W + 2 > 1) ? $clog2(IMG_W + 2) : 1;
    localparam RW = (IMG_H + 1 > 1) ? $clog2(IMG_H + 1) : 1;

    // ------------------------------------------------------------------
    // state
    // ------------------------------------------------------------------
    reg  [CW-1:0]    in_col;     // 0..W-1 pixels, W phantom col, W+1 wait-nl
    reg  [RW-1:0]    in_row;     // input row; all-ones until first new_line
    reg              flushing;   // phantom bottom row in progress
    reg  [CW-1:0]    fl_cnt;     // flush beat 0..W (W = flush phantom col)
    reg  [IMG_W-1:0] lb0, lb1;   // line buffers: lb0=row y-1, lb1=row y-2
    reg  [2:0]       rt0, rt1, rt2;  // column taps, [0]=newest

    // ------------------------------------------------------------------
    // beat decode
    // ------------------------------------------------------------------
    wire take_pix = pix_valid && !flushing && !done && (in_row < IMG_H) &&
                    ((in_col < IMG_W) ||
                     ((in_col == IMG_W + 1) && (in_row < IMG_H - 1)));
    wire cap_ph   = !flushing && !done && (in_col == IMG_W);
    wire wait_nl  = !flushing && !done && (in_col == IMG_W + 1);
    wire fl_act   = flushing && !done && (fl_cnt <= IMG_W);
    wire fl_real  = fl_act && (fl_cnt < IMG_W);
    wire fl_ph    = fl_act && (fl_cnt == IMG_W);
    wire implicit = take_pix && (in_col == IMG_W + 1); // row start w/o new_line

    // shift position of this beat (column of the tap being shifted in)
    wire [CW-1:0] sh_col = take_pix ? (implicit ? {CW{1'b0}} : in_col) :
                           cap_ph   ? IMG_W[CW-1:0] : fl_cnt;
    wire [RW-1:0] sh_row = take_pix ? (implicit ? in_row + 1'b1 : in_row) :
                           flushing ? IMG_H[RW-1:0] : in_row;

    // emit coordinates: window centre = (sh_col-1, sh_row-1);
    // phantom column emits ox = IMG_W-1; flush row emits oy = IMG_H-1.
    wire          emit_ok = (take_pix && (sh_col >= 1) &&
                                     (sh_row >= 1) && (sh_row <= IMG_H)) ||
                            (cap_ph && (in_row >= 1) && (in_row <= IMG_H)) ||
                            (fl_real && (fl_cnt >= 1)) || fl_ph;
    wire [CW-1:0] emit_x = (cap_ph || fl_ph) ? (IMG_W - 1) : (sh_col - 1'b1);
    wire [RW-1:0] emit_y = flushing ? (IMG_H - 1) : (sh_row - 1'b1);

    // ------------------------------------------------------------------
    // taps shifted in this beat (pre-shift register reads)
    // ------------------------------------------------------------------
    wire phantom = cap_ph || fl_ph;
    wire tap0 = phantom ? rt0[0] : lb1[IMG_W-1];                    // row y-2
    wire tap1 = phantom ? rt1[0] : lb0[IMG_W-1];                    // row y-1
    wire tap2 = phantom ? rt2[0] : (flushing ? lb0[IMG_W-1] : pix); // row y

    // post-shift lanes: lane[0]=col ox+1, lane[1]=col ox, lane[2]=col ox-1
    wire [2:0] n0 = {rt0[1:0], tap0};
    wire [2:0] n1 = {rt1[1:0], tap1};
    wire [2:0] n2 = {rt2[1:0], tap2};

    // vertical clamp: oy==0 -> top lane takes mid lane
    wire [2:0] laneT = (emit_y == 0) ? n1 : n0;
    // horizontal clamp: ox==0 -> oldest tap takes centre tap
    wire leftT = (emit_x == 0) ? laneT[1] : laneT[2];
    wire leftM = (emit_x == 0) ? n1[1]    : n1[2];
    wire leftB = (emit_x == 0) ? n2[1]    : n2[2];

    // win9[i] = tap(r,c), i = r*3+c; lane[2-c] = tap c
    wire [8:0] win9 = { n2[0],    n2[1],    leftB,   // r=2: c2 c1 c0
                        n1[0],    n1[1],    leftM,   // r=1
                        laneT[0], laneT[1], leftT }; // r=0

    // ------------------------------------------------------------------
    // per-channel XNOR popcount + threshold (combinational)
    // ------------------------------------------------------------------
    function [3:0] pc9;
        input [8:0] v;
        integer i;
        begin
            pc9 = 4'd0;
            for (i = 0; i < 9; i = i + 1) pc9 = pc9 + {3'd0, v[i]};
        end
    endfunction

    genvar gi;
    wire [NCH-1:0] outc;
    generate
    for (gi = 0; gi < NCH; gi = gi + 1) begin : g_ch
        wire [8:0] w9   = wcfg[gi*9 +: 9];
        wire [3:0] thr  = thcfg[gi*4 +: 4];
        wire [8:0] m    = ~(win9 ^ w9);       // XNOR match mask
        assign outc[gi] = (pc9(m) >= thr);
    end
    endgenerate

    // ------------------------------------------------------------------
    // sequential
    // ------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            in_col   <= {CW{1'b0}};
            in_row   <= {RW{1'b1}};    // "row -1": first new_line -> row 0
            flushing <= 1'b0;
            fl_cnt   <= {CW{1'b0}};
            lb0      <= {IMG_W{1'b0}};
            lb1      <= {IMG_W{1'b0}};
            rt0      <= 3'd0;
            rt1      <= 3'd0;
            rt2      <= 3'd0;
            done     <= 1'b0;
        end else if (clk_en) begin
            if (take_pix) begin
                rt0 <= n0; rt1 <= n1; rt2 <= n2;
                lb0 <= {lb0[IMG_W-2:0], pix};
                lb1 <= {lb1[IMG_W-2:0], lb0[IMG_W-1]};
                if (implicit) begin
                    in_col <= {{(CW-1){1'b0}}, 1'b1};
                    in_row <= in_row + 1'b1;
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end else if (cap_ph) begin
                rt0 <= n0; rt1 <= n1; rt2 <= n2;      // replicate newest tap
                in_col <= IMG_W + 1;
            end else if (fl_act) begin
                rt0 <= n0; rt1 <= n1; rt2 <= n2;
                if (fl_real) begin
                    lb0 <= {lb0[IMG_W-2:0], 1'b0};
                    lb1 <= {lb1[IMG_W-2:0], lb0[IMG_W-1]};
                end
                fl_cnt <= fl_cnt + 1'b1;
                if (fl_ph) begin
                    flushing <= 1'b0;
                    done     <= 1'b1;
                end
            end
            // new_line beats coexist with the phantom-column beat
            if (new_line && !flushing && !done) begin
                in_col <= {CW{1'b0}};
                in_row <= in_row + 1'b1;
            end
            // enter bottom-edge flush once the last row's phantom passed
            // (>= covers a stray new_line that bumped in_row to IMG_H)
            if (wait_nl && (in_row >= IMG_H - 1)) begin
                flushing <= 1'b1;
                fl_cnt   <= {CW{1'b0}};
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out       <= {NCH{1'b0}};
            out_valid <= 1'b0;
            out_nl    <= 1'b0;
        end else if (clk_en) begin
            out_valid <= emit_ok;
            out_nl    <= emit_ok && (emit_x == 0);
            if (emit_ok) out <= outc;
        end
    end
endmodule
