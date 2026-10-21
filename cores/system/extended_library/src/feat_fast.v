// ============================================================================
// feat_fast -- FAST corner detector, radius-3 Bresenham circle, 16 taps,
// contiguous-arc test with parameter N (default 9).  (wave2 idx11)
//
// Two phases:
//   CAPTURE : incoming imgwin-contract pixel stream (new_line + pix_valid)
//             is stored into an internal frame RAM (w2_dpram, W=8,
//             DEPTH=IMG_W*IMG_H).  IMG_W must be a power of two (w2_win_rd).
//   RUN     : after `start` pulses, w2_win_rd walks every pixel with a 7x7
//             window (tap index r*7+c, per-tap edge clamp).  One clk_en beat
//             after each win_valid the detector emits flag_out + arc_out.
//
// Circle tap indices inside the 7x7 window (dx,dy) in ring order:
//   (0,-3)(1,-3)(2,-2)(3,-1)(3,0)(3,1)(2,2)(1,3)(0,3)(-1,3)
//   (-2,2)(-3,1)(-3,0)(-3,-1)(-2,-2)(-1,-3)
// bright_i = circ_i >  c + THRESH   (9-bit compare, no wraparound)
// dark_i   = circ_i + THRESH < c
// corner   = longest circular run(bright) >= N || run(dark) >= N
// arc_out  = max(runB, runD)  (0..16)
// flag_out = 8'h01 / 8'h00
// ============================================================================
module feat_fast #(
    parameter IMG_W  = 32,                  // power of two
    parameter IMG_H  = 32,
    parameter N      = 9,                   // contiguous-arc threshold
    parameter [7:0] THRESH = 8'd24,
    parameter LW     = (IMG_W > 1) ? $clog2(IMG_W) : 1,
    parameter AW     = $clog2(IMG_W*IMG_H)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    // capture phase (imgwin stream contract)
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    // run phase
    input  wire        start,
    output reg  [7:0]  flag_out,
    output reg  [7:0]  arc_out,
    output reg         out_valid,
    output reg         done
);
    // ------------------------------------------------------------------
    // capture: write incoming pixels into the frame RAM (port A)
    // ------------------------------------------------------------------
    reg [LW-1:0] cx;
    reg [15:0]   cy;

    wire cap_we = pix_valid && !done;
    // IMG_W is a power of two -> address = cy*IMG_W + cx is a concat
    wire [AW-1:0] cap_addr = {cy[AW-LW-1:0], cx};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cx <= {LW{1'b0}};
            cy <= 16'hFFFF;                // -1: first new_line makes it 0
        end else if (clk_en) begin
            if (pix_valid)
                cx <= (cx == IMG_W - 1) ? {LW{1'b0}}
                                      : cx + {{LW-1{1'b0}}, 1'b1};
            if (new_line) begin
                cx <= {LW{1'b0}};
                cy <= cy + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // frame RAM + window reader
    // ------------------------------------------------------------------
    wire           rd_re;
    wire [AW-1:0]  rd_raddr;
    wire [7:0]     rd_q;
    wire [391:0]   win;            // 49 taps x 8
    wire           win_valid;
    wire           wrd_done;

    w2_dpram #(.W(8), .DEPTH(IMG_W*IMG_H)) u_frame (
        .clk(clk), .clk_en(clk_en),
        .we(cap_we), .waddr(cap_addr), .wdata(pix),
        .re(rd_re), .raddr(rd_raddr), .q(rd_q)
    );

    w2_win_rd #(.K(7), .IMG_W(IMG_W), .IMG_H(IMG_H)) u_rd (
        .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
        .re(rd_re), .raddr(rd_raddr), .q(rd_q),
        .win(win), .win_valid(win_valid),
        .win_x(), .win_y(), .done(wrd_done)
    );

    // ------------------------------------------------------------------
    // FAST ring test -- SERIAL over 33 beats (one tap per beat).
    // w2_win_rd needs 49+2 beats per window, so a 33-beat scan keeps the
    // 1:1 pixel rate while needing only ONE comparator + run counters.
    // The scan walks the doubled 16-tap ring (taps i mod 16, i = 0..31):
    // a circular run of L <= 16 appears as a linear run in the doubled ring,
    // and the all-ones ring saturates the counter at 16 -- equivalent to the
    // golden per-start run scan.
    // ------------------------------------------------------------------
    // ring tap indices (row-major r*7+c inside the 7x7 window)
    //   0:(0,-3)->3   1:(1,-3)->4   2:(2,-2)->12  3:(3,-1)->20
    //   4:(3,0)->27   5:(3,1)->34   6:(2,2)->40   7:(1,3)->46
    //   8:(0,3)->45   9:(-1,3)->44 10:(-2,2)->36 11:(-3,1)->28
    //  12:(-3,0)->21 13:(-3,-1)->14 14:(-2,-2)->8 15:(-1,-3)->2
    wire [7:0]   ctr = win[24*8 +: 8];      // window centre tap
    // packed ring: ring_r[i*8 +: 8] = circle pixel i
    wire [127:0] ring_w = {
        win[2*8 +: 8],  win[8*8 +: 8],  win[14*8 +: 8], win[21*8 +: 8],
        win[28*8 +: 8], win[36*8 +: 8], win[44*8 +: 8], win[45*8 +: 8],
        win[46*8 +: 8], win[40*8 +: 8], win[34*8 +: 8], win[27*8 +: 8],
        win[20*8 +: 8], win[12*8 +: 8], win[4*8 +: 8],  win[3*8 +: 8]};

    reg  [127:0] ring_r;
    reg  [7:0]   ctr_r;
    reg  [5:0]   scan;          // 0..32 : tap index (mod 16), 32 = emit
    reg          scanning;
    reg  [4:0]   cur_b, cur_d;  // current run length (saturates at 16)
    reg  [4:0]   max_b, max_d;  // longest run seen
    reg          fin;           // reader finished -> emit completes frame

    wire [7:0]  ctap = ring_r[{scan[3:0], 3'b000} +: 8];   // tap scan mod 16
    wire        bright = ({1'b0, ctap} > ({1'b0, ctr_r} + {1'b0, THRESH}));
    wire        dark   = (({1'b0, ctap} + {1'b0, THRESH}) < {1'b0, ctr_r});
    wire [4:0]  nb = bright ? ((cur_b == 5'd16) ? 5'd16 : cur_b + 5'd1)
                            : 5'd0;
    wire [4:0]  nd = dark   ? ((cur_d == 5'd16) ? 5'd16 : cur_d + 5'd1)
                            : 5'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ring_r    <= 128'd0;
            ctr_r     <= 8'd0;
            scan      <= 6'd0;
            scanning  <= 1'b0;
            cur_b     <= 5'd0;
            cur_d     <= 5'd0;
            max_b     <= 5'd0;
            max_d     <= 5'd0;
            fin       <= 1'b0;
            flag_out  <= 8'd0;
            arc_out   <= 8'd0;
            out_valid <= 1'b0;
            done      <= 1'b0;
        end else if (clk_en) begin
            out_valid <= 1'b0;
            if (wrd_done) fin <= 1'b1;
            if (win_valid) begin
                // latch the window; start the 33-beat ring scan
                ring_r   <= ring_w;
                ctr_r    <= ctr;
                scan     <= 6'd0;
                scanning <= 1'b1;
                cur_b    <= 5'd0;
                cur_d    <= 5'd0;
                max_b    <= 5'd0;
                max_d    <= 5'd0;
            end else if (scanning) begin
                if (scan < 6'd32) begin
                    cur_b <= nb;
                    cur_d <= nd;
                    if (nb > max_b) max_b <= nb;
                    if (nd > max_d) max_d <= nd;
                    scan  <= scan + 6'd1;
                end else begin
                    // emit beat: longest circular runs are in max_b/max_d
                    scanning  <= 1'b0;
                    out_valid <= 1'b1;
                    flag_out  <= ((max_b >= N) || (max_d >= N))
                                 ? 8'h01 : 8'h00;
                    arc_out   <= {3'd0,
                                  (max_b >= max_d) ? max_b : max_d};
                    if (fin) done <= 1'b1;
                end
            end
        end
    end
endmodule
