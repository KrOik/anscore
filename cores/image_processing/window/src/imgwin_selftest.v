// ============================================================================
// imgwin_selftest -- unit selftest aggregator for the imgwin_20k streaming
// image kernels on GW2A-18C.  Structure follows cnn_selftest.v:
//   * ce = 1 clk in 16 (deep FNV fold chains get ~590 ns to settle)
//   * each unit: img_stim -> win3x3_gen -> kernel -> FNV-1a digest
//   * EXP_* constants are produced by tools/golden_model.py (independent
//     golden, trap T1) -- NOT harvested from simulation output
//   * verdict uses === so X can never masquerade as PASS (trap T6)
//
// Units:
//   U0 WIN : win3x3_gen window stream (folds all 9 taps per window)
//   U1 GAUS: win3x3_gen + gaussian3x3 blur
//   U2 SOB : win3x3_gen + sobel_edge (folds mag then bin)
//   U3 MED : win3x3_gen + median3x3
//   U4 MRP : img_stim -> threshold_bin -> win3x3_gen -> morph3x3
//            (binary image; mode = output row parity: even=erode, odd=dilate;
//             folds erode, dilate, selected per window)
//   U5 THR : img_stim -> threshold_bin (fixed threshold, raw stream)
// ============================================================================
module imgwin_selftest #(
    parameter [5:0] UNIT_EN = 6'h3F
)(
    input  wire        clk,
    input  wire        rst_n,
    output reg         all_done,
    output reg         all_pass,
    output reg         any_fail,
    input  wire [4:0]  digest_sel,
    output reg  [31:0] digest_q,
    output wire [5:0]  done_mask,
    output wire [5:0]  pass_mask
);
    localparam IMG_W = 16;
    localparam IMG_H = 16;

    function [31:0] fnv;
        input [31:0] h;
        input [7:0]  b;
        reg   [31:0] x;
        begin
            x = h ^ {24'd0, b};
            // 0x01000193 = bits {0,1,4,7,8,24} -- shift-add, no DSP (T4)
            fnv = x + (x << 1) + (x << 4) + (x << 7) + (x << 8) + (x << 24);
        end
    endfunction

    reg [3:0] ce_div = 4'd0;
    wire ce = (ce_div == 4'd15);
    always @(posedge clk) ce_div <= ce_div + 4'd1;

    // ------------------------------------------------------------------
    // U0 WIN: win3x3_gen alone
    // ------------------------------------------------------------------
    localparam [31:0] EXP_WIN = 32'hbd71944d;   // filled from golden_model.py
    wire [7:0]  s0_pix;
    wire        s0_pv, s0_nl;
    wire [71:0] w0_win;
    wire        w0_v, w0_nlo, w0_done;
    reg         u0_done = 1'b0;
    reg  [3:0]  u0_tail = 4'd0;
    reg  [31:0] u0_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[0]) begin : g_u0
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s0_pix), .pix_valid(s0_pv), .new_line(s0_nl), .stim_done());
        win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s0_pix), .pix_valid(s0_pv), .new_line(s0_nl),
            .win(w0_win), .win_valid(w0_v), .new_line_out(w0_nlo),
            .done(w0_done));
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u0_done <= 1'b0; u0_dg <= 32'h811c9dc5; u0_tail <= 4'd0;
            end else if (ce && !u0_done) begin
                if (w0_v) begin
                    u0_dg <= fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(fnv(u0_dg,
                        w0_win[7:0]),   w0_win[15:8]),  w0_win[23:16]),
                        w0_win[31:24]), w0_win[39:32]), w0_win[47:40]),
                        w0_win[55:48]), w0_win[63:56]), w0_win[71:64]);
                end
                if (w0_done) begin
                    u0_tail <= u0_tail + 4'd1;
                    if (u0_tail == 4'd8) u0_done <= 1'b1;
                end
            end
        end
    end else begin : g_u0_off
        always @(posedge clk) u0_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // U1 GAUS: win3x3_gen + gaussian3x3
    // ------------------------------------------------------------------
    localparam [31:0] EXP_GAUS = 32'h1c69d353;
    wire [7:0]  s1_pix;
    wire        s1_pv, s1_nl;
    wire [71:0] w1_win;
    wire        w1_v, w1_nlo, w1_done;
    wire [7:0]  g1_pix;
    wire        g1_v, g1_nlo;
    reg         u1_done = 1'b0;
    reg  [3:0]  u1_tail = 4'd0;
    reg  [31:0] u1_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[1]) begin : g_u1
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s1_pix), .pix_valid(s1_pv), .new_line(s1_nl), .stim_done());
        win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s1_pix), .pix_valid(s1_pv), .new_line(s1_nl),
            .win(w1_win), .win_valid(w1_v), .new_line_out(w1_nlo),
            .done(w1_done));
        gaussian3x3 u_f (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .win(w1_win), .win_valid(w1_v), .new_line_out(w1_nlo),
            .pix_out(g1_pix), .out_valid(g1_v), .nl_out(g1_nlo));
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u1_done <= 1'b0; u1_dg <= 32'h811c9dc5; u1_tail <= 4'd0;
            end else if (ce && !u1_done) begin
                if (g1_v) u1_dg <= fnv(u1_dg, g1_pix);
                if (w1_done) begin
                    u1_tail <= u1_tail + 4'd1;
                    if (u1_tail == 4'd8) u1_done <= 1'b1;
                end
            end
        end
    end else begin : g_u1_off
        always @(posedge clk) u1_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // U2 SOB: win3x3_gen + sobel_edge (fold mag then bin per window)
    // ------------------------------------------------------------------
    localparam [31:0] EXP_SOB = 32'he1762120;
    wire [7:0]  s2_pix;
    wire        s2_pv, s2_nl;
    wire [71:0] w2_win;
    wire        w2_v, w2_nlo, w2_done;
    wire [7:0]  e2_mag, e2_bin;
    wire        e2_v, e2_nlo;
    reg         u2_done = 1'b0;
    reg  [3:0]  u2_tail = 4'd0;
    reg  [31:0] u2_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[2]) begin : g_u2
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s2_pix), .pix_valid(s2_pv), .new_line(s2_nl), .stim_done());
        win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s2_pix), .pix_valid(s2_pv), .new_line(s2_nl),
            .win(w2_win), .win_valid(w2_v), .new_line_out(w2_nlo),
            .done(w2_done));
        sobel_edge #(.THRESH(8'd96)) u_f (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .win(w2_win), .win_valid(w2_v), .new_line_out(w2_nlo),
            .mag_out(e2_mag), .bin_out(e2_bin),
            .out_valid(e2_v), .nl_out(e2_nlo));
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u2_done <= 1'b0; u2_dg <= 32'h811c9dc5; u2_tail <= 4'd0;
            end else if (ce && !u2_done) begin
                if (e2_v) u2_dg <= fnv(fnv(u2_dg, e2_mag), e2_bin);
                if (w2_done) begin
                    u2_tail <= u2_tail + 4'd1;
                    if (u2_tail == 4'd8) u2_done <= 1'b1;
                end
            end
        end
    end else begin : g_u2_off
        always @(posedge clk) u2_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // U3 MED: win3x3_gen + median3x3
    // ------------------------------------------------------------------
    localparam [31:0] EXP_MED = 32'ha3a98a3c;
    wire [7:0]  s3_pix;
    wire        s3_pv, s3_nl;
    wire [71:0] w3_win;
    wire        w3_v, w3_nlo, w3_done;
    wire [7:0]  m3_pix;
    wire        m3_v, m3_nlo;
    reg         u3_done = 1'b0;
    reg  [3:0]  u3_tail = 4'd0;
    reg  [31:0] u3_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[3]) begin : g_u3
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s3_pix), .pix_valid(s3_pv), .new_line(s3_nl), .stim_done());
        win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s3_pix), .pix_valid(s3_pv), .new_line(s3_nl),
            .win(w3_win), .win_valid(w3_v), .new_line_out(w3_nlo),
            .done(w3_done));
        median3x3 u_f (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .win(w3_win), .win_valid(w3_v), .new_line_out(w3_nlo),
            .pix_out(m3_pix), .out_valid(m3_v), .nl_out(m3_nlo));
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u3_done <= 1'b0; u3_dg <= 32'h811c9dc5; u3_tail <= 4'd0;
            end else if (ce && !u3_done) begin
                if (m3_v) u3_dg <= fnv(u3_dg, m3_pix);
                if (w3_done) begin
                    u3_tail <= u3_tail + 4'd1;
                    if (u3_tail == 4'd8) u3_done <= 1'b1;
                end
            end
        end
    end else begin : g_u3_off
        always @(posedge clk) u3_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // U4 MRP: stim -> threshold_bin -> win3x3_gen -> morph3x3
    //   mode = output row parity (erode on even rows, dilate on odd rows)
    //   fold order per window: erode, dilate, selected pix_out
    // ------------------------------------------------------------------
    localparam [31:0] EXP_MRP = 32'h3e86450a;
    wire [7:0]  s4_pix;
    wire        s4_pv, s4_nl;
    wire [7:0]  t4_pix;
    wire        t4_v, t4_nl;
    wire [71:0] w4_win;
    wire        w4_v, w4_nlo, w4_done;
    wire [7:0]  m4_pix, m4_er, m4_di;
    wire        m4_v, m4_nlo;
    reg  [4:0]  mrp_x = 5'd0;
    reg  [4:0]  mrp_y = 5'd0;
    wire        mrp_mode = mrp_y[0];
    reg         u4_done = 1'b0;
    reg  [3:0]  u4_tail = 4'd0;
    reg  [31:0] u4_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[4]) begin : g_u4
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s4_pix), .pix_valid(s4_pv), .new_line(s4_nl), .stim_done());
        threshold_bin #(.THRESH(8'd128)) u_thr (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s4_pix), .pix_valid(s4_pv), .new_line(s4_nl),
            .pix_out(t4_pix), .out_valid(t4_v), .new_line_out(t4_nl));
        win3x3_gen #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_dut (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(t4_pix), .pix_valid(t4_v), .new_line(t4_nl),
            .win(w4_win), .win_valid(w4_v), .new_line_out(w4_nlo),
            .done(w4_done));
        morph3x3 u_f (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .win(w4_win), .win_valid(w4_v), .new_line_out(w4_nlo),
            .mode(mrp_mode),
            .pix_out(m4_pix), .erode_out(m4_er), .dilate_out(m4_di),
            .out_valid(m4_v), .nl_out(m4_nlo));
        // output row parity for the morph mode select
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                mrp_x <= 5'd0; mrp_y <= 5'd0;
            end else if (ce && !u4_done && w4_v) begin
                if (mrp_x == IMG_W - 1) begin
                    mrp_x <= 5'd0;
                    mrp_y <= mrp_y + 5'd1;
                end else begin
                    mrp_x <= mrp_x + 5'd1;
                end
            end
        end
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u4_done <= 1'b0; u4_dg <= 32'h811c9dc5; u4_tail <= 4'd0;
            end else if (ce && !u4_done) begin
                // fold order per window: erode,dilate (at win_valid beat)
                // then selected pix_out (at out_valid beat, may coincide
                // with the next window's erode/dilate -> pix first)
                if (m4_v && w4_v)
                    u4_dg <= fnv(fnv(fnv(u4_dg, m4_pix), m4_er), m4_di);
                else if (m4_v)
                    u4_dg <= fnv(u4_dg, m4_pix);
                else if (w4_v)
                    u4_dg <= fnv(fnv(u4_dg, m4_er), m4_di);
                if (w4_done) begin
                    u4_tail <= u4_tail + 4'd1;
                    if (u4_tail == 4'd8) u4_done <= 1'b1;
                end
            end
        end
    end else begin : g_u4_off
        always @(posedge clk) u4_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // U5 THR: stim -> threshold_bin (raw stream)
    // ------------------------------------------------------------------
    localparam [31:0] EXP_THR = 32'h9ffadfc0;
    wire [7:0]  s5_pix;
    wire        s5_pv, s5_nl, s5_done;
    wire [7:0]  t5_pix;
    wire        t5_v, t5_nl;
    reg  [3:0]  u5_tail = 4'd0;
    reg         u5_done = 1'b0;
    reg  [31:0] u5_dg = 32'h811c9dc5;

    generate
    if (UNIT_EN[5]) begin : g_u5
        img_stim #(.IMG_W(IMG_W), .IMG_H(IMG_H)) u_stim (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s5_pix), .pix_valid(s5_pv), .new_line(s5_nl),
            .stim_done(s5_done));
        threshold_bin #(.THRESH(8'd128)) u_f (
            .clk(clk), .clk_en(ce || !rst_n), .rst_n(rst_n),
            .pix(s5_pix), .pix_valid(s5_pv), .new_line(s5_nl),
            .pix_out(t5_pix), .out_valid(t5_v), .new_line_out(t5_nl));
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin
                u5_done <= 1'b0; u5_dg <= 32'h811c9dc5; u5_tail <= 4'd0;
            end else if (ce && !u5_done) begin
                if (t5_v) u5_dg <= fnv(u5_dg, t5_pix);
                if (s5_done) begin
                    u5_tail <= u5_tail + 4'd1;
                    if (u5_tail == 4'd8) u5_done <= 1'b1;
                end
            end
        end
    end else begin : g_u5_off
        always @(posedge clk) u5_done <= 1'b1;
    end
    endgenerate

    // ------------------------------------------------------------------
    // aggregation
    // ------------------------------------------------------------------
    wire [5:0] done_w = {u5_done, u4_done, u3_done, u2_done, u1_done, u0_done};
    assign done_mask = done_w;

    function [31:0] exp_digest;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: exp_digest = EXP_WIN;
                4'd1: exp_digest = EXP_GAUS;
                4'd2: exp_digest = EXP_SOB;
                4'd3: exp_digest = EXP_MED;
                4'd4: exp_digest = EXP_MRP;
                4'd5: exp_digest = EXP_THR;
                default: exp_digest = 32'd0;
            endcase
        end
    endfunction

    reg [31:0] digests [0:5];
    reg [5:0]  pass_r;
    assign pass_mask = pass_r;

    integer ui;
    always @(posedge clk) begin
        digests[0] <= u0_dg; digests[1] <= u1_dg; digests[2] <= u2_dg;
        digests[3] <= u3_dg; digests[4] <= u4_dg; digests[5] <= u5_dg;
        for (ui = 0; ui < 6; ui = ui + 1) begin
            pass_r[ui] <= done_w[ui] &&
                          (!UNIT_EN[ui] || digests[ui] == exp_digest(ui[3:0]));
        end
    end

    always @(*) begin
        digest_q = (digest_sel < 5'd6) ? digests[digest_sel[2:0]] : 32'd0;
    end

    reg verdict_settled;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            all_done <= 1'b0; all_pass <= 1'b0; any_fail <= 1'b0;
            verdict_settled <= 1'b0;
        end else if (ce && !all_done) begin
            all_done <= &done_w;
        end else if (all_done && !verdict_settled) begin
            // latch only AFTER all_done: pass_r===done_w is trivially true
            // while every done bit is still 0 (template trap)
            verdict_settled <= 1'b1;
            all_pass <= (pass_r === done_w);
            any_fail <= (pass_r !== done_w);
        end
    end
endmodule
