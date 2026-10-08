// ============================================================================
// st_canny_hyst -- wave2 selftest cell for idx9 HYS (canny_hyst).
//   Pass A (canonical chain):
//     w2_img_stim (32x32 frame 0) -> canny_grad -> canny_nms
//       -> canny_dth(TH_LO=200, TH_HI=255) -> canny_hyst
//   Pass B (coverage frame): after pass A completes, a synthetic class
//     stream is replayed into the SAME canny_hyst instance (frame re-arm):
//       cls(x,y) = 2 if (x%8==0 && y%8==0)                       strong grid
//                = 1 if (x%8<=1 && y%8<=1) || (x%8==4 && y%8==4) adj+iso weak
//                = 0 otherwise
//     giving 16 strong / 48 promoted weak / 16 ISOLATED weak (the stim
//     frame has no isolated weak pixels -- all weak are strong-adjacent).
//   digest = FNV-1a over the hyst edge-byte stream of both passes
//            (2048 bytes).  EXP from tools/golden_canny.py only (T1).
// ============================================================================
module st_canny_hyst (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam IMG_W = 32;
    localparam IMG_H = 32;
    localparam NPIX  = IMG_W * IMG_H;
    localparam [31:0] EXP = 32'h6785454B;   // golden_canny.py HYS DIGEST

    `include "w2_fnv.vh"

    reg  run;
    wire ce = clk_en & run;

    // ------------------------------------------------------------------
    // pass A chain: stim -> grad -> nms -> dth
    // ------------------------------------------------------------------
    wire [7:0] s_pix;
    wire       s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done)
    );

    wire [7:0] g_mag;
    wire [1:0] g_dir;
    wire       g_v, g_nl, g_done;
    canny_grad #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_grad (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .mag_out(g_mag), .dir_out(g_dir),
        .out_valid(g_v), .nl_out(g_nl), .done(g_done)
    );

    wire [7:0] n_pix;
    wire       n_v, n_nl, n_done;
    canny_nms #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_nms (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(g_mag), .dir(g_dir), .pix_valid(g_v), .new_line(g_nl),
        .pix_out(n_pix), .out_valid(n_v), .nl_out(n_nl), .done(n_done)
    );

    wire [1:0] t_cls;
    wire       t_v, t_nl;
    canny_dth #(.TH_LO(8'd200), .TH_HI(8'd255)) u_dth (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(n_pix), .pix_valid(n_v), .new_line(n_nl),
        .cls_out(t_cls), .out_valid(t_v), .nl_out(t_nl)
    );

    // ------------------------------------------------------------------
    // pass B: synthetic class-frame generator (replays into same DUT)
    // ------------------------------------------------------------------
    reg        p2;            // pass-B active
    reg  [10:0] p2_cnt;       // 0..NPIX while generating
    wire [2:0] m8x = p2_cnt[2:0];
    wire [2:0] m8y = p2_cnt[7:5];
    wire [1:0] p2_cls =
        ((m8x == 3'd0) && (m8y == 3'd0))                          ? 2'd2 :
        (((m8x <= 3'd1) && (m8y <= 3'd1)) ||
         ((m8x == 3'd4) && (m8y == 3'd4)))                        ? 2'd1 :
                                                                  2'd0;
    wire       p2_pv = p2 && (p2_cnt < 11'd1024);

    // DUT input mux: pass A drives from the chain, pass B from the gen
    wire [1:0] h_cls = p2 ? p2_cls : t_cls;
    wire       h_pv  = p2 ? p2_pv  : t_v;

    wire [7:0] d_pix;
    wire       d_v, d_nl, d_done;
    canny_hyst #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .cls(h_cls), .pix_valid(h_pv), .new_line(1'b0),
        .pix_out(d_pix), .out_valid(d_v), .nl_out(d_nl), .done(d_done)
    );

    // fold output stream (both passes)
    reg [15:0] npix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            digest <= 32'h811C9DC5;
            npix   <= 16'd0;
        end else if (ce) begin
            if (d_v) begin
                digest <= fnv(digest, d_pix);
                npix   <= npix + 16'd1;
            end
        end
    end

    // sequencer: start -> run; first DUT done rise arms pass B; second
    // done rise latches `fin`, then an 8-beat tail settles the verdict.
    reg       d_done_d;
    reg       fin;
    wire      done_rise = d_done && !d_done_d;
    reg [3:0] tail;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run      <= 1'b0;
            done     <= 1'b0;
            pass     <= 1'b0;
            cycles   <= 16'd0;
            tail     <= 4'd0;
            p2       <= 1'b0;
            p2_cnt   <= 11'd0;
            d_done_d <= 1'b0;
            fin      <= 1'b0;
        end else if (clk_en) begin
            d_done_d <= d_done;
            if (start && !run) run <= 1'b1;
            if (run && !done)  cycles <= cycles + 16'd1;
            if (done_rise && !p2) p2  <= 1'b1;
            if (done_rise && p2)  fin <= 1'b1;
            if (p2 && (p2_cnt < 11'd1024)) p2_cnt <= p2_cnt + 11'd1;
            if (fin && !done) begin
                tail <= tail + 4'd1;
                if (tail == 4'd8) begin
                    done <= 1'b1;
                    pass <= (digest === EXP) && (npix == 2 * NPIX);
                end
            end
        end
    end
endmodule
