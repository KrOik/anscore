// ============================================================================
// feat_harris -- Harris corner score over a causal 3x3 product window
// (wave2 idx10).
//
// Per emitted 3x3 window (win3x3_gen contract):
//   gx = (w2 + 2w5 + w8) - (w0 + 2w3 + w6)      Sobel, range +-1020
//   gy = (w6 + 2w7 + w8) - (w0 + 2w1 + w2)
//   qx = gx >>> QSH,  qy = gy >>> QSH           (arithmetic shift; QSH=7 ->
//                                               4-bit signed, range [-8,7])
//   pxx = qx*qx,  pyy = qy*qy,  pxy = qx*qy     (small shift-add mults)
//   NOTE: datapath widths below assume QSH=7 (|q| <= 8).  Other QSH values
//   need the product/sum widths re-checked.
//
// Score accumulation window is CAUSAL 3x3 with edge replication:
//   S(y,x) = sum_{i=0..2} sum_{j=0..2} p[clamp(y-i)][clamp(x-j)]
// implemented as vertical column sums (2-row history in w2_dpram) + a 3-tap
// horizontal shift register:
//   cs(y,x)   = p(y,x) + p(y-1,x) + p(y-2,x)   (rows -1,-2 clamp to row 0)
//   S(y,x)    = cs(y,x) + cs(y,x-1) + cs(y,x-2)(cols -1,-2 clamp to col 0)
// History RAMs: histA*{pxx[6:0],pyy[6:0]} (W=14), histB*pxy[7:0] (W=8),
// one pair per history row -> 4 x w2_dpram (4 BSRAM).
//   histA1[x]<=p(y,x) each beat, histA2[x]<=eff(p(y-1,x)) => row-0 clamp
//   propagates correctly with no X reaching the datapath.
//
// score = (Sxx*Syy - Sxy*Sxy) - ((Sxx+Syy)*(Sxx+Syy) >> 5)   [k ~= 1/32]
// All multiplies are combinational shift-add functions (NO '*' operator ->
// no DSP).  Pipeline: products @T, sums @T+1, score @T+2, out_valid @T+3.
// Output order = input order (1024 pixels, row-major).
// ============================================================================
module feat_harris #(
    parameter IMG_W  = 32,
    parameter IMG_H  = 32,
    parameter QSH    = 7,                     // gradient quantization shift
    parameter signed [31:0] THRESH = 32'sd500,
    parameter LW     = (IMG_W > 1) ? $clog2(IMG_W) : 1,
    parameter RW     = (IMG_H > 1) ? $clog2(IMG_H) : 1
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  signed [31:0] score_out,
    output reg  [7:0]  flag_out,
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] w0 = win[7:0],    w1 = win[15:8],   w2 = win[23:16];
    wire [7:0] w3 = win[31:24],  w5 = win[47:40];
    wire [7:0] w6 = win[55:48],  w7 = win[63:56],  w8 = win[71:64];

    // ---- combinational Sobel gradients (shift-add) --------------------------
    wire [10:0] gx_p = {3'b0, w2} + ({3'b0, w5} << 1) + {3'b0, w8};
    wire [10:0] gx_n = {3'b0, w0} + ({3'b0, w3} << 1) + {3'b0, w6};
    wire [10:0] gy_p = {3'b0, w6} + ({3'b0, w7} << 1) + {3'b0, w8};
    wire [10:0] gy_n = {3'b0, w0} + ({3'b0, w1} << 1) + {3'b0, w2};
    wire signed [11:0] gx = $signed({1'b0, gx_p}) - $signed({1'b0, gx_n});
    wire signed [11:0] gy = $signed({1'b0, gy_p}) - $signed({1'b0, gy_n});

    // quantized gradients, 4-bit signed for QSH=7 (range [-8,7])
    wire signed [3:0] qx = gx >>> QSH;
    wire signed [3:0] qy = gy >>> QSH;
    wire [3:0] aqx = qx[3] ? (~qx + 4'd1) : qx;      // |qx| <= 8
    wire [3:0] aqy = qy[3] ? (~qy + 4'd1) : qy;

    // ---- shift-add multipliers (LUT only, no DSP) ---------------------------
    function [7:0] mul4u;                   // 4b x 4b unsigned (<= 64)
        input [3:0] a, b;
        integer i;
        begin
            mul4u = 8'd0;
            for (i = 0; i < 4; i = i + 1)
                if (b[i]) mul4u = mul4u + ({4'd0, a} << i);
        end
    endfunction
    function [19:0] mul10u;                 // 10b x 10b unsigned
        input [9:0] a, b;
        integer i;
        begin
            mul10u = 20'd0;
            for (i = 0; i < 10; i = i + 1)
                if (b[i]) mul10u = mul10u + ({10'd0, a} << i);
        end
    endfunction
    function [21:0] mul11u;                 // 11b x 11b unsigned
        input [10:0] a, b;
        integer i;
        begin
            mul11u = 22'd0;
            for (i = 0; i < 11; i = i + 1)
                if (b[i]) mul11u = mul11u + ({11'd0, a} << i);
        end
    endfunction

    // per-pixel products (comb, stage A)
    wire [7:0]        pxx_f = mul4u(aqx, aqx);
    wire [7:0]        pyy_f = mul4u(aqy, aqy);
    wire [6:0]        pxx_c = pxx_f[6:0];
    wire [6:0]        pyy_c = pyy_f[6:0];
    wire [7:0]        pmag  = mul4u(aqx, aqy);
    wire              psign = qx[3] ^ qy[3];
    wire signed [7:0] pxy_c = psign ? -$signed(pmag) : $signed(pmag);

    // ---- position counters --------------------------------------------------
    reg [LW-1:0] x;
    reg [RW-1:0] y;

    // ---- stage-A registers --------------------------------------------------
    reg [6:0]        pxx_d, pyy_d;
    reg signed [7:0] pxy_d;
    reg [LW-1:0]     x_d;
    reg [RW-1:0]     y_d;
    reg              pv_d;

    // ---- product history RAMs ----------------------------------------------
    wire [13:0] qa1, qa2;                    // {pxx,pyy} of rows y-1, y-2
    wire [7:0]  qb1, qb2;                    // pxy of rows y-1, y-2
    wire [13:0] pack_d  = {pxx_d, pyy_d};
    wire [13:0] eff1_p  = (y_d == {RW{1'b0}}) ? pack_d  : qa1;
    wire [13:0] eff2_p  = (y_d == {RW{1'b0}}) ? pack_d  : qa2;
    wire [7:0]  eff1_xy = (y_d == {RW{1'b0}}) ? pxy_d   : qb1;
    wire [7:0]  eff2_xy = (y_d == {RW{1'b0}}) ? pxy_d   : qb2;

    w2_dpram #(.W(14), .DEPTH(IMG_W)) u_ha1 (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d), .waddr(x_d), .wdata(pack_d),
        .re(win_valid), .raddr(x), .q(qa1));
    w2_dpram #(.W(14), .DEPTH(IMG_W)) u_ha2 (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d), .waddr(x_d), .wdata(eff1_p),
        .re(win_valid), .raddr(x), .q(qa2));
    w2_dpram #(.W(8), .DEPTH(IMG_W)) u_hb1 (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d), .waddr(x_d), .wdata(pxy_d),
        .re(win_valid), .raddr(x), .q(qb1));
    w2_dpram #(.W(8), .DEPTH(IMG_W)) u_hb2 (
        .clk(clk), .clk_en(clk_en),
        .we(pv_d), .waddr(x_d), .wdata(eff1_xy),
        .re(win_valid), .raddr(x), .q(qb2));

    // ---- stage-B: column sums + horizontal clamp sums -----------------------
    // cs <= 192 (8b unsigned) ; cs_xy <= +-192 (9b signed)
    wire [7:0]        cs_xx = {1'b0, pxx_d} + {1'b0, eff1_p[13:7]}
                                          + {1'b0, eff2_p[13:7]};
    wire [7:0]        cs_yy = {1'b0, pyy_d} + {1'b0, eff1_p[6:0]}
                                          + {1'b0, eff2_p[6:0]};
    wire signed [8:0] cs_xy = $signed(pxy_d) + $signed({eff1_xy[7], eff1_xy})
                                            + $signed({eff2_xy[7], eff2_xy});

    reg [7:0]        cxx_d1, cxx_d2, cyy_d1, cyy_d2;
    reg signed [8:0] cxy_d1, cxy_d2;

    wire [7:0] t1x = (x_d == {LW{1'b0}}) ? cs_xx : cxx_d1;
    wire [7:0] t2x = (x_d == {LW{1'b0}}) ? cs_xx :
                     (x_d == {{LW-1{1'b0}},1'b1}) ? cxx_d1 : cxx_d2;
    wire [7:0] t1y = (x_d == {LW{1'b0}}) ? cs_yy : cyy_d1;
    wire [7:0] t2y = (x_d == {LW{1'b0}}) ? cs_yy :
                     (x_d == {{LW-1{1'b0}},1'b1}) ? cyy_d1 : cyy_d2;
    wire signed [8:0] t1xy = (x_d == {LW{1'b0}}) ? cs_xy : cxy_d1;
    wire signed [8:0] t2xy = (x_d == {LW{1'b0}}) ? cs_xy :
                     (x_d == {{LW-1{1'b0}},1'b1}) ? cxy_d1 : cxy_d2;

    // S <= 576 (10b unsigned) ; Sxy <= +-576 (11b signed)
    wire [9:0]        sxx_c = {2'b00, cs_xx} + {2'b00, t1x} + {2'b00, t2x};
    wire [9:0]        syy_c = {2'b00, cs_yy} + {2'b00, t1y} + {2'b00, t2y};
    wire signed [10:0] sxy_c = $signed({{2{cs_xy[8]}}, cs_xy})
                             + $signed({{2{t1xy[8]}}, t1xy})
                             + $signed({{2{t2xy[8]}}, t2xy});

    // ---- stage-C registers --------------------------------------------------
    reg [9:0]         sxx_r, syy_r;
    reg signed [10:0] sxy_r;
    reg               pv_d2;
    reg [LW-1:0]      x_d2;

    // ---- score (comb, stage C) ----------------------------------------------
    wire [9:0]  axy   = sxy_r[10] ? (~sxy_r[9:0] + 10'd1) : sxy_r[9:0];
    wire [19:0] p_det = mul10u(sxx_r, syy_r);
    wire [19:0] p_neg = mul10u(axy, axy);
    wire [10:0] tr    = {1'b0, sxx_r} + {1'b0, syy_r};
    wire [21:0] tr2   = mul11u(tr, tr);
    wire signed [31:0] det     = $signed({2'b00, p_det})
                               - $signed({2'b00, p_neg});
    wire signed [31:0] score_c = det - $signed({10'd0, tr2[21:5]});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            x         <= {LW{1'b0}};
            y         <= {RW{1'b0}};
            pxx_d     <= 7'd0;
            pyy_d     <= 7'd0;
            pxy_d     <= 8'd0;
            x_d       <= {LW{1'b0}};
            y_d       <= {RW{1'b0}};
            pv_d      <= 1'b0;
            cxx_d1    <= 8'd0;
            cxx_d2    <= 8'd0;
            cyy_d1    <= 8'd0;
            cyy_d2    <= 8'd0;
            cxy_d1    <= 9'd0;
            cxy_d2    <= 9'd0;
            sxx_r     <= 10'd0;
            syy_r     <= 10'd0;
            sxy_r     <= 11'd0;
            pv_d2     <= 1'b0;
            x_d2      <= {LW{1'b0}};
            score_out <= 32'd0;
            flag_out  <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            // stage A
            pv_d <= win_valid;
            if (win_valid) begin
                pxx_d <= pxx_c;
                pyy_d <= pyy_c;
                pxy_d <= pxy_c;
                x_d   <= x;
                y_d   <= y;
                // y advances on the LAST window of the row (new_line_out
                // fires at x==0 of the current row -- using it would bump y
                // one row early and break the row-0 clamp muxes)
                x     <= (x == IMG_W - 1) ? {LW{1'b0}}
                                          : x + {{LW-1{1'b0}},1'b1};
                if (x == IMG_W - 1) y <= y + {{RW-1{1'b0}}, 1'b1};
            end

            // stage B
            pv_d2 <= pv_d;
            x_d2  <= x_d;
            if (pv_d) begin
                sxx_r  <= sxx_c;
                syy_r  <= syy_c;
                sxy_r  <= sxy_c;
                cxx_d1 <= cs_xx;
                cxx_d2 <= cxx_d1;
                cyy_d1 <= cs_yy;
                cyy_d2 <= cyy_d1;
                cxy_d1 <= cs_xy;
                cxy_d2 <= cxy_d1;
            end

            // stage C
            out_valid <= pv_d2;
            nl_out    <= pv_d2 && (x_d2 == {LW{1'b0}});
            if (pv_d2) begin
                score_out <= score_c;
                flag_out  <= (score_c > THRESH) ? 8'h01 : 8'h00;
            end
        end
    end
endmodule
