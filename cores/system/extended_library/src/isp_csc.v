// ============================================================================
// isp_csc -- RGB <-> YCbCr (BT.601 full-range) fixed-point converter.
//
//   mode = 0 : RGB -> YCbCr   in {R,G,B}   -> out {Y,Cb,Cr}
//   mode = 1 : YCbCr -> RGB   in {Y,Cb,Cr} -> out {R,G,B}
//   (mode is sampled per pix_valid beat; keep stable within a frame)
//
// Coefficients are Q8 integers, realised as shift-add networks -- NO `*`
// operator anywhere (T4: each constant multiply would burn a DSP):
//   fwd  Y  = (77R + 150G + 29B) >> 8                     (never clips)
//        Cb = (128B - 43R - 85G + 32768) >> 8             (always in [0,255])
//        Cr = (128R - 107G - 21B + 32768) >> 8            (always in [0,255])
//   inv  R = clip( Y + ((359*cri + 128) >>> 8) )
//        G = clip( Y - ((88*cbi + 183*cri + 128) >>> 8) )
//        B = clip( Y + ((454*cbi + 128) >>> 8) )
//   cbi = Cb-128, cri = Cr-128; >>> is floor on signed values (+128 rounds).
// Golden replica: tools/golden_isp.py csc_fwd/csc_inv.
// Registered output, one clk_en beat latency.  All registers clk_en gated.
// ============================================================================
module isp_csc (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [23:0] pix24,        // {R,G,B} or {Y,Cb,Cr}
    input  wire        pix_valid,
    input  wire        new_line,
    input  wire        mode,         // 0 fwd, 1 inv
    output reg  [23:0] pix24_out,    // {Y,Cb,Cr} or {R,G,B}
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] c0 = pix24[23:16];
    wire [7:0] c1 = pix24[15:8];
    wire [7:0] c2 = pix24[7:0];

    // ---------------- forward (unsigned; Cb/Cr provably non-negative) ------
    // 77 = 64+8+4+1 ; 150 = 128+16+4+2 ; 29 = 16+8+4+1
    wire [16:0] fy = (c0 << 6) + (c0 << 3) + (c0 << 2) + c0
                   + (c1 << 7) + (c1 << 4) + (c1 << 2) + (c1 << 1)
                   + (c2 << 4) + (c2 << 3) + (c2 << 2) + c2;
    // Cb: 32768 + (B<<7) - 43R - 85G ; 43 = 32+8+2+1 ; 85 = 64+16+4+1
    wire [17:0] cb_pos = 18'd32768 + {3'b000, c2, 7'b0000000};
    wire [17:0] cb_neg = (c0 << 5) + (c0 << 3) + (c0 << 1) + c0
                       + (c1 << 6) + (c1 << 4) + (c1 << 2) + c1;
    wire [17:0] cb_t   = cb_pos - cb_neg;          // >= 128, never underflows
    // Cr: 32768 + (R<<7) - 107G - 21B ; 107 = 64+32+8+2+1 ; 21 = 16+4+1
    wire [17:0] cr_pos = 18'd32768 + {3'b000, c0, 7'b0000000};
    wire [17:0] cr_neg = (c1 << 6) + (c1 << 5) + (c1 << 3) + (c1 << 1) + c1
                       + (c2 << 4) + (c2 << 2) + c2;
    wire [17:0] cr_t   = cr_pos - cr_neg;

    wire [7:0] fy8  = fy[16:8];
    wire [7:0] fcb8 = cb_t[15:8];                  // cb_t>>8 <= 255 always
    wire [7:0] fcr8 = cr_t[15:8];

    // ---------------- inverse (signed) -------------------------------------
    wire signed [18:0] ys  = {11'd0, c0};
    wire signed [18:0] cbi = {11'd0, c1} - 19'sd128;
    wire signed [18:0] cri = {11'd0, c2} - 19'sd128;
    // 359 = 256+64+32+4+2+1
    wire signed [18:0] t_r = (cri <<< 8) + (cri <<< 6) + (cri <<< 5)
                           + (cri <<< 2) + (cri <<< 1) + cri;
    // 88 = 64+16+8 ; 183 = 128+32+16+4+2+1 ; 454 = 256+128+64+4+2
    wire signed [19:0] t_g = (cbi <<< 6) + (cbi <<< 4) + (cbi <<< 3)
                           + (cri <<< 7) + (cri <<< 5) + (cri <<< 4)
                           + (cri <<< 2) + (cri <<< 1) + cri;
    wire signed [19:0] t_b = (cbi <<< 8) + (cbi <<< 7) + (cbi <<< 6)
                           + (cbi <<< 2) + (cbi <<< 1);

    // NOTE: every operand must stay signed -- mixing in an unsigned concat
    // forces unsigned context, which turns >>> into a LOGICAL shift (T-miss
    // found in sim: ur came out +1976 instead of -72).
    wire signed [20:0] ur = ys + ((t_r + 19'sd128) >>> 8);
    wire signed [20:0] ug = ys - ((t_g + 20'sd128) >>> 8);
    wire signed [20:0] ub = ys + ((t_b + 20'sd128) >>> 8);

    function [7:0] clip8;
        input signed [20:0] v;
        begin
            clip8 = (v < 0) ? 8'd0 : ((v > 21'sd255) ? 8'd255 : v[7:0]);
        end
    endfunction

    wire [7:0] ir8 = clip8(ur);
    wire [7:0] ig8 = clip8(ug);
    wire [7:0] ib8 = clip8(ub);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix24_out <= 24'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix24_out <= mode ? {ir8, ig8, ib8} : {fy8, fcb8, fcr8};
            out_valid <= pix_valid;
            nl_out    <= new_line;
        end
    end
endmodule
