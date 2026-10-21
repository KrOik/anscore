// ============================================================================
// ISP-12 AE/AWB/AF statistics: zoned brightness (channel sums), overexposure
// counts, and focus gradient energy, with an independent result-readout port.
//
// Streaming raster statistics SINK: there is no pixel output stream.  Every
// accepted pixel feeds O(1) accumulator work (strict input II=1), and each
// zone record is pushed to a ping-pong result RAM at the moment the zone's
// last pixel commits.  The host reads complete-frame record sets through
// res_bank/res_addr with one-cycle synchronous-read latency.
//
// Zone grid: runtime zones_x x zones_y, each in [1,8], with the contract
// zones_x <= img_w and zones_y <= img_h (every zone non-empty, so a
// single-carry Bresenham raster map is exact: zx = floor(x*zones_x/img_w)).
//
// Focus operator: causal first-difference gradient magnitude on the luma
// path  v = pixel (CH=1) or v = (r + 2g + b) >> 2 (CH=3).
//   gx = (x==0) ? 0 : |v(x,y) - v(x-1,y)|
//   gy = (y==0) ? 0 : |v(x,y) - v(x,y-1)|
//   e  = gx + gy   <= 2*MPX, attributed to zone(x,y).
// One WIDTH-entry luma line buffer supplies v(x,y-1); borders contribute 0.
//
// Overexposure: a pixel counts when ANY channel >= cfg_thresh (gray: pixel).
// All accumulators are width-derived and cannot overflow for any legal
// configuration (bounds in SPEC.md); there is no runtime saturation.
//
// Pipeline: stage A = input handshake captures the pixel and issues the
// luma-line read; stage B = commit on the next edge (accumulator writeback
// and, for zone-final pixels, the result-RAM push).  Two-bank ping-pong:
// frame F writes bank b while the host may still read bank ~b; res_done[b]
// clears when a new frame starts writing bank b, so each record set stays
// readable for one full following frame.
// ============================================================================
module ispstats_stream #(
    parameter BITS       = 8,
    parameter CH         = 3,    // 1 = gray pixel, 3 = packed {R,G,B}
    parameter MAX_W      = 32,
    parameter MAX_H      = 24,
    // Derived widths; documented bounds, override only to mirror the formulas.
    // Clamps keep elaboration alive for illegal static params so the initial
    // check reports them instead of a compile-time failure.
    parameter MPX  = (BITS<1) ? 1 : ((1<<BITS)-1),
    parameter FP   = (MAX_W<1 || MAX_H<1 || MAX_W*MAX_H>65536) ? 1 : MAX_W*MAX_H,
    parameter CNTW = $clog2(FP+1),          // zone pixel count / oe count
    parameter SUMW = $clog2(FP*MPX+1),      // per-channel zone sum
    parameter ENW  = $clog2(FP*2*MPX+1),    // zone gradient-energy sum
    parameter RW   = 2*CNTW + 3*SUMW + ENW, // result record width
    parameter XW   = (MAX_W<2) ? 1 : $clog2(MAX_W),
    parameter YW   = (MAX_H<2) ? 1 : $clog2(MAX_H),
    parameter CWX  = (MAX_W<1) ? 1 : $clog2(MAX_W+1),
    parameter CWY  = (MAX_H<1) ? 1 : $clog2(MAX_H+1)
)(
    input  wire clk, rst_n,
    // Pixel stream sink: tuser = SOF (first pixel of frame), tlast = EOL.
    input  wire [CH*BITS-1:0] s_tdata,
    input  wire s_tvalid, s_tuser, s_tlast,
    output wire s_tready,
    // Independent statistics readout port (host side).  Present res_bank and
    // res_addr at edge T; res_data is valid in cycle T+1 and holds while the
    // address is held and the bank keeps a complete frame.
    input  wire [5:0] res_addr,
    input  wire res_bank,
    output reg  [RW-1:0] res_data,
    output reg  res_new,             // 1-cycle pulse: a frame's records landed
    output reg  res_new_bank,        // which bank received them
    output reg  [1:0]  res_done,     // per-bank: holds a complete frame's set
    output reg  [15:0] res_frame,    // {bank1 fseq, bank0 fseq}, wraps mod 256
    output reg  [13:0] res_count,    // {bank1 nrec, bank0 nrec} = zones_x*zones_y
    // Atomic configuration; accepted only between frames.
    input  wire cfg_valid, output wire cfg_ready,
    input  wire [CWX-1:0] cfg_img_w,
    input  wire [CWY-1:0] cfg_img_h,
    input  wire [3:0] cfg_zx, cfg_zy,
    input  wire [BITS-1:0] cfg_thresh,
    output reg  cfg_done, cfg_error,
    output reg  marker_error,
    output wire busy
);
    localparam [3:0] DEFZX = (MAX_W<4) ? MAX_W : 4;
    localparam [3:0] DEFZY = (MAX_H<4) ? MAX_H : 4;

    reg  [CWX-1:0] img_w;
    reg  [CWY-1:0] img_h;
    reg  [3:0] zones_x, zones_y;
    reg  [BITS-1:0] thresh;
    reg  [XW-1:0] x;
    reg  [YW-1:0] y;
    reg  [2:0] zx, zy;
    reg  [CWX+3:0] acc_x;   // Bresenham remainder; value always < img_w
    reg  [CWY+3:0] acc_y;
    reg  fopen;             // frame inputs started but not completed
    reg  pend;              // stage-B pending pixel
    reg  [6:0] push_cnt;    // records pushed this frame (<=64)
    reg  wbank;             // bank the current/next frame writes
    reg  [7:0] fseq;        // completed-frame sequence counter
    // Stage-A captures for the pending pixel.
    reg  [BITS-1:0] cap_v, cap_pv;
    reg  [BITS-1:0] cap_r, cap_g, cap_b;
    reg  [2:0] cap_zx;
    reg  cap_x0, cap_y0, cap_final, cap_last;
    reg  [BITS-1:0] lumq;   // luma one row above the pending pixel
    reg  [BITS-1:0] prev_v; // luma of previous accepted pixel
    // Per-zone-column band accumulators (current band only; a slot is flushed
    // to the result RAM and cleared on its zone's final pixel).
    reg  [CNTW-1:0] a_cnt [0:7];
    reg  [SUMW-1:0] a_s0  [0:7];
    reg  [SUMW-1:0] a_s1  [0:7];
    reg  [SUMW-1:0] a_s2  [0:7];
    reg  [CNTW-1:0] a_oe  [0:7];
    reg  [ENW-1:0]  a_en  [0:7];
    // Luma line buffer (previous row) and dual-bank result RAM.
    (* ram_style="block" *) reg [BITS-1:0] lummem [0:MAX_W-1];
    (* ram_style="block" *) reg [RW-1:0]   resmem [0:127];

    assign busy      = fopen | pend;
    assign cfg_ready = rst_n && !busy;
    assign s_tready  = rst_n && !(cfg_valid && cfg_ready);
    wire take = s_tvalid && s_tready;

    // -------------------- stage-A combinational inputs ----------------------
    // Implicit zero extension keeps channel extracts in range for CH=1.
    wire [3*BITS-1:0] sext = s_tdata;
    wire [BITS-1:0] r_in = (CH==3) ? sext[3*BITS-1 -: BITS] : s_tdata[BITS-1:0];
    wire [BITS-1:0] g_in = (CH==3) ? sext[2*BITS-1 -: BITS] : {BITS{1'b0}};
    wire [BITS-1:0] b_in = (CH==3) ? sext[BITS-1:0]          : {BITS{1'b0}};
    wire [BITS+1:0] lsum = {2'b00, r_in} + {1'b0, g_in, 1'b0} + {2'b00, b_in};
    wire [BITS-1:0] v_in = (CH==3) ? lsum[BITS+1:2] : s_tdata[BITS-1:0];
    wire [CWX-1:0] w_last = img_w - 1'b1;
    wire [CWY-1:0] h_last = img_h - 1'b1;
    // Zone raster map; a single carry per step is exact because zones<=img.
    wire [CWX+4:0] zx_e    = {{(CWX+1){1'b0}}, zones_x};
    wire [CWX+4:0] ax_next = {1'b0, acc_x} + zx_e;
    wire [CWX+4:0] ax_dif  = ax_next - img_w;     // implicit zero extension
    wire col_carry  = ax_next >= {1'b0, img_w};
    wire col_last   = (x == w_last) || col_carry;
    wire [CWY+4:0] zy_e    = {{(CWY+1){1'b0}}, zones_y};
    wire [CWY+4:0] ay_next = {1'b0, acc_y} + zy_e;
    wire [CWY+4:0] ay_dif  = ay_next - img_h;     // implicit zero extension
    wire band_carry = ay_next >= {1'b0, img_h};
    wire band_last  = (y == h_last) || band_carry;
    wire zone_final = col_last && band_last;
    wire pix_last   = (x == w_last) && (y == h_last);
    // Bank a new frame will write: wbank normally, ~wbank when this same edge
    // completes the previous frame (the toggle lands on this edge).
    wire commit_last = pend && cap_last;
    wire sof_bank    = commit_last ? ~wbank : wbank;

    // -------------------- stage-B combinational update ----------------------
    wire [BITS-1:0] gx = cap_x0 ? {BITS{1'b0}}
                       : ((cap_v >= cap_pv) ? cap_v - cap_pv : cap_pv - cap_v);
    wire [BITS-1:0] gy = cap_y0 ? {BITS{1'b0}}
                       : ((cap_v >= lumq) ? cap_v - lumq : lumq - cap_v);
    wire [BITS:0]   e_now = {1'b0, gx} + {1'b0, gy};
    wire oe_pix = (cap_r >= thresh) | (cap_g >= thresh) | (cap_b >= thresh);
    wire [CNTW-1:0] c_cnt = a_cnt[cap_zx];
    wire [SUMW-1:0] c_s0  = a_s0[cap_zx];
    wire [SUMW-1:0] c_s1  = a_s1[cap_zx];
    wire [SUMW-1:0] c_s2  = a_s2[cap_zx];
    wire [CNTW-1:0] c_oe  = a_oe[cap_zx];
    wire [ENW-1:0]  c_en  = a_en[cap_zx];
    wire [CNTW-1:0] n_cnt = c_cnt + 1'b1;
    wire [SUMW-1:0] n_s0  = c_s0 + cap_r;
    wire [SUMW-1:0] n_s1  = c_s1 + cap_g;
    wire [SUMW-1:0] n_s2  = c_s2 + cap_b;
    wire [CNTW-1:0] n_oe  = c_oe + oe_pix;   // implicit zero extension
    wire [ENW-1:0]  n_en  = c_en + e_now;    // implicit zero extension
    wire [RW-1:0]   rec_word = {n_en, n_oe, n_s2, n_s1, n_s0, n_cnt};
    wire [6:0]      push_next = push_cnt + (pend && cap_final);

    // -------------------- result RAM: 1W (pushes) + 1R (host) ---------------
    wire push = pend && cap_final;
    always @(posedge clk) begin
        if (push) resmem[{wbank, push_cnt[5:0]}] <= rec_word;
    end
    always @(posedge clk) begin
        if (!rst_n) res_data <= {RW{1'b0}};
        else        res_data <= resmem[{res_bank, res_addr}];
    end

    integer k;
    always @(posedge clk) begin
        if (!rst_n) begin
            img_w <= MAX_W; img_h <= MAX_H;
            zones_x <= DEFZX; zones_y <= DEFZY; thresh <= {BITS{1'b1}};
            x <= 0; y <= 0; zx <= 0; zy <= 0; acc_x <= 0; acc_y <= 0;
            fopen <= 0; pend <= 0; push_cnt <= 0; wbank <= 0; fseq <= 0;
            cap_v <= 0; cap_pv <= 0; cap_r <= 0; cap_g <= 0; cap_b <= 0;
            cap_zx <= 0; cap_x0 <= 0; cap_y0 <= 0; cap_final <= 0; cap_last <= 0;
            lumq <= 0; prev_v <= 0;
            for (k = 0; k < 8; k = k + 1) begin
                a_cnt[k] <= 0; a_s0[k] <= 0; a_s1[k] <= 0; a_s2[k] <= 0;
                a_oe[k] <= 0; a_en[k] <= 0;
            end
            res_new <= 0; res_new_bank <= 0; res_done <= 0;
            res_frame <= 0; res_count <= 0;
            cfg_done <= 0; cfg_error <= 0; marker_error <= 0;
        end else begin
            cfg_done <= 0; cfg_error <= 0; res_new <= 0;
            if (cfg_valid && cfg_ready) begin
                if (cfg_img_w < 1 || cfg_img_w > MAX_W ||
                    cfg_img_h < 1 || cfg_img_h > MAX_H ||
                    cfg_zx < 1 || cfg_zx > 4'd8 ||
                    cfg_zy < 1 || cfg_zy > 4'd8 ||
                    cfg_zx > cfg_img_w || cfg_zy > cfg_img_h) begin
                    cfg_error <= 1;            // reject all fields
                end else begin
                    img_w <= cfg_img_w; img_h <= cfg_img_h;
                    zones_x <= cfg_zx; zones_y <= cfg_zy;
                    thresh <= cfg_thresh; cfg_done <= 1;
                end
            end
            pend <= take;
            if (take) begin
                if (x == {XW{1'b0}} && y == {YW{1'b0}}) begin
                    fopen <= 1;
                    res_done[sof_bank] <= 1'b0;   // this bank gets overwritten
                    push_cnt <= 0;
                end
                if (pix_last) fopen <= 0;
                if (s_tuser != ((x == {XW{1'b0}}) && (y == {YW{1'b0}})) ||
                    s_tlast != (x == w_last))
                    marker_error <= 1;
                cap_v <= v_in; cap_pv <= prev_v; prev_v <= v_in;
                cap_r <= r_in; cap_g <= g_in; cap_b <= b_in;
                lumq <= lummem[x]; lummem[x] <= v_in;  // read-before-write
                cap_zx <= zx; cap_x0 <= (x == {XW{1'b0}});
                cap_y0 <= (y == {YW{1'b0}});
                cap_final <= zone_final; cap_last <= pix_last;
                if (x == w_last) begin
                    x <= 0; zx <= 0; acc_x <= 0;
                    if (y == h_last) begin
                        y <= 0; zy <= 0; acc_y <= 0;
                    end else begin
                        y <= y + 1'b1;
                        if (band_carry) begin
                            acc_y <= ay_dif[CWY+3:0]; zy <= zy + 1'b1;
                        end else acc_y <= ay_next[CWY+3:0];
                    end
                end else begin
                    x <= x + 1'b1;
                    if (col_carry) begin
                        acc_x <= ax_dif[CWX+3:0]; zx <= zx + 1'b1;
                    end else acc_x <= ax_next[CWX+3:0];
                end
            end
            if (pend) begin
                if (cap_final) begin
                    push_cnt <= push_next;
                    a_cnt[cap_zx] <= 0; a_s0[cap_zx] <= 0; a_s1[cap_zx] <= 0;
                    a_s2[cap_zx] <= 0; a_oe[cap_zx] <= 0; a_en[cap_zx] <= 0;
                end else begin
                    a_cnt[cap_zx] <= n_cnt; a_s0[cap_zx] <= n_s0;
                    a_s1[cap_zx] <= n_s1; a_s2[cap_zx] <= n_s2;
                    a_oe[cap_zx] <= n_oe;  a_en[cap_zx] <= n_en;
                end
                if (cap_last) begin
                    push_cnt <= 0;
                    res_done[wbank] <= 1'b1;
                    res_new <= 1'b1; res_new_bank <= wbank;
                    if (wbank == 1'b0) begin
                        res_frame[7:0]  <= fseq;
                        res_count[6:0]  <= push_next;
                    end else begin
                        res_frame[15:8] <= fseq;
                        res_count[13:7] <= push_next;
                    end
                    wbank <= ~wbank; fseq <= fseq + 1'b1;
                end
            end
        end
    end

    initial begin
        if ((BITS != 8 && BITS != 10) || (CH != 1 && CH != 3) ||
            MAX_W < 1 || MAX_W > 1024 || MAX_H < 1 || MAX_H > 1024 ||
            MAX_W * MAX_H > 65536)
            $fatal(1, "unsupported ispstats_stream parameters");
    end
endmodule
