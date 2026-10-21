// ============================================================================
// hist_clahe -- small-tile CLAHE prototype (wave2 unit idx17, TAG CLA).
//
// 32x32 frame in a w2_dpram (T9).  The frame is divided into a 4x4 grid of
// 8x8 tiles.  SIMPLIFICATIONS vs full CLAHE (documented, deterministic, and
// replicated by tools/golden_geom.py):
//   * per-tile histogram has only 16 bins (pixel>>4), kept in a flat
//     16x8-bit register vector (no RAM hazard);
//   * clip = min(h,CLIP); clipped-out mass is NOT redistributed -- the CDF is
//     normalised by S = sum(clipped) instead (classic "clip + renormalise"
//     variant);
//   * LUT_t[i] = min(255, floor(cdf_i*255 / S)) via an unrolled restoring
//     divider (no DSP, no '/' operator);
//   * apply pass blends the 4 nearest tile-centre LUTs with 3-bit fractions:
//       x<4 -> tile0 only ; 4<=x<28 -> tiles (x-4)>>3 & +1, fx=(x-4)&7 ;
//       x>=28 -> tile3 only.  Same per y.
//       m = LUT_tile[p>>4]; top=(m00<<3)+(m01-m00)*fx;
//       bot=(m10<<3)+(m11-m10)*fx; res=(top<<3)+(bot-top)*fy;
//       out = clamp((res+32)>>6,0,255)
//   * the same shared mulsu-style signed x unsigned shift-add multiplier does
//     all three lerps (zero DSP).
//
// Per-tile LUTs are stored in a second w2_dpram (256x8, addr={tile,bin}).
// ~10 clk_en beats per output pixel.
// ============================================================================
module hist_clahe #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,             // both 32: 4x4 tiles of 8x8
    parameter CLIP  = 8               // 16-bin clip limit
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         new_line_out,
    output reg         done
);
    localparam S_WR = 3'd0, S_HC = 3'd1, S_HR = 3'd2, S_CS = 3'd3,
               S_LUT = 3'd4, S_AP = 3'd5, S_DONE = 3'd6;

    // ---- state -------------------------------------------------------------
    reg  [2:0]  state;
    reg  [3:0]  ph;
    reg  [3:0]  tile;            // {ty[3:2], tx[1:0]} via tile[3:2]=ty
    reg  [5:0]  n;               // 0..63 pixel index inside tile
    reg  [3:0]  li;              // LUT build index 0..15
    reg  [7:0]  cdf;             // clipped CDF accumulator
    reg  [7:0]  ssum;            // S = sum clipped
    // apply-pass coords and taps
    reg  [4:0]  ox, oy;
    reg  [7:0]  m00, m01, m10, m11;
    reg  [10:0] top, bot;
    reg  [3:0]  pbin;            // p>>4 for the LUT reads
    // issue pipeline for tile-hist pass: issue regs set at end of beat u ->
    // port active during u+1 -> DOB loads end u+1 -> q valid at u+2 = d1 stage
    reg         iss_v, d1_v;
    reg  [5:0]  iss_n, d1_n;
    // tile histogram registers (flat 16x8)
    reg  [127:0] hvec;

    // ---- frame RAM ---------------------------------------------------------
    reg          fre;
    reg  [9:0]   fraddr;
    wire [7:0]   fq;
    reg  [4:0]   wx, wy;
    wire         fwe    = (state == S_WR) && pix_valid;
    wire [9:0]   fwaddr = {wy, wx};
    w2_dpram #(.W(8), .DEPTH(1024), .AW(10)) u_frame (
        .clk(clk), .clk_en(clk_en),
        .we(fwe), .waddr(fwaddr), .wdata(pix),
        .re(fre), .raddr(fraddr), .q(fq));

    // ---- tile-LUT RAM (256 x 8, addr = {tile[3:0], bin[3:0]}) --------------
    reg          lre, lwe;
    reg  [7:0]   lraddr, lwaddr;
    reg  [7:0]   lwdata;
    wire [7:0]   lq;
    w2_dpram #(.W(8), .DEPTH(256), .AW(8)) u_lut (
        .clk(clk), .clk_en(clk_en),
        .we(lwe), .waddr(lwaddr), .wdata(lwdata),
        .re(lre), .raddr(lraddr), .q(lq));

    // ---- shared signed(18) x unsigned(8) shift-add multiplier --------------
    reg  signed [17:0] mx;
    reg  [7:0]         my;
    function signed [25:0] mulsu;
        input signed [17:0] a;
        input [7:0]         b;
        integer i;
        reg signed [25:0] s;
        begin
            s = 26'sd0;
            for (i = 0; i < 8; i = i + 1)
                if (b[i]) s = s + ({{8{a[17]}}, a} << i);
            mulsu = s;
        end
    endfunction
    wire signed [25:0] mp = mulsu(mx, my);

    // ---- 16-bit / 8-bit restoring divider (combinational, no DSP) ----------
    function [15:0] divu;
        input [15:0] n;
        input [7:0]  d;
        integer k;
        reg [8:0] rem;
        reg [15:0] qq;
        begin
            rem = 9'd0;
            qq  = 16'd0;
            for (k = 15; k >= 0; k = k - 1) begin
                rem = {rem[7:0], n[k]};
                if (rem >= {1'b0, d}) begin
                    rem   = rem - {1'b0, d};
                    qq[k] = 1'b1;
                end
            end
            divu = qq;
        end
    endfunction

    wire [1:0] ty = tile[3:2];
    wire [1:0] tx = tile[1:0];

    // clipped-hist sum, combinational over flat vector
    function [8:0] clip_sum;
        input [127:0] hv;
        integer k;
        reg [8:0] s;
        begin
            s = 9'd0;
            for (k = 0; k < 16; k = k + 1)
                s = s + ((hv[k*8 +: 8] > CLIP) ? CLIP : hv[k*8 +: 8]);
            clip_sum = s;
        end
    endfunction
    wire [7:0]  h_i    = hvec[li*8 +: 8];
    wire [7:0]  h_clip = (h_i > CLIP) ? CLIP : h_i;
    wire [8:0]  ncdf   = {1'b0, cdf} + {1'b0, h_clip};         // <=64
    wire [15:0] n255   = ({7'd0, ncdf} << 8) - {7'd0, ncdf};   // ncdf*255
    wire [15:0] dquo   = divu(n255, ssum);
    wire [7:0]  lval   = (ssum == 8'd0) ? 8'd0 :
                        (dquo > 16'd255) ? 8'hFF : dquo[7:0];

    // tile-centre decode for apply pass
    wire        m_x  = (ox >= 5'd4) && (ox < 5'd28);
    wire        m_y  = (oy >= 5'd4) && (oy < 5'd28);
    wire [1:0]  ix0  = (ox < 5'd4)  ? 2'd0 : (ox >= 5'd28) ? 2'd3 :
                       (ox - 5'd4) >> 3;
    wire [1:0]  ix1  = m_x ? (ix0 + 2'd1) : ix0;
    wire [1:0]  iy0  = (oy < 5'd4)  ? 2'd0 : (oy >= 5'd28) ? 2'd3 :
                       (oy - 5'd4) >> 3;
    wire [1:0]  iy1  = m_y ? (iy0 + 2'd1) : iy0;
    wire [7:0]  fx   = m_x ? (({3'd0, ox} - 8'd4) & 8'd7) : 8'd0;
    wire [7:0]  fy   = m_y ? (({3'd0, oy} - 8'd4) & 8'd7) : 8'd0;

    // multiplier operand mux
    always @(*) begin
        mx = 18'sd0;
        my = 8'd0;
        if (state == S_AP) begin
            case (ph)
                4'd6: begin mx = $signed({1'b0, m01}) - $signed({1'b0, m00});
                            my = fx; end
                4'd8: begin mx = $signed({1'b0, m11}) - $signed({1'b0, m10});
                            my = fx; end
                4'd9: begin mx = $signed({7'd0, bot}) - $signed({7'd0, top});
                            my = fy; end
                default: begin mx = 18'sd0; my = 8'd0; end
            endcase
        end
    end
    wire signed [26:0] top_s = $signed({1'b0, m00, 3'd0}) + mp;
    wire signed [26:0] bot_s = $signed({1'b0, m10, 3'd0}) + mp;
    wire signed [26:0] res_s = $signed({1'b0, top, 3'd0}) + mp;
    wire signed [27:0] res_r = res_s + 28'sd32;
    wire [7:0] outb = res_r[27]       ? 8'd0  :
                      (|res_r[26:14]) ? 8'hFF : res_r[13:6];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_WR;
            ph    <= 4'd0;
            tile  <= 4'd0;
            n     <= 6'd0;
            li    <= 4'd0;
            cdf   <= 8'd0;
            ssum  <= 8'd0;
            hvec  <= 128'd0;
            wx    <= 5'd0;  wy  <= 5'd0;
            ox    <= 5'd0;  oy  <= 5'd0;
            m00   <= 8'd0;  m01 <= 8'd0;  m10 <= 8'd0;  m11 <= 8'd0;
            top   <= 11'd0; bot <= 11'd0;
            pbin  <= 4'd0;
            iss_v <= 1'b0;  d1_v <= 1'b0;
            iss_n <= 6'd0;  d1_n <= 6'd0;
            fre   <= 1'b0;  fraddr <= 10'd0;
            lre   <= 1'b0;  lwe    <= 1'b0;
            lraddr<= 8'd0;  lwaddr <= 8'd0;  lwdata <= 8'd0;
            pix_out      <= 8'd0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            done         <= 1'b0;
        end else if (clk_en) begin
            fre          <= 1'b0;
            lre          <= 1'b0;
            lwe          <= 1'b0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            case (state)
                // ---- ingest frame ------------------------------------------
                S_WR: begin
                    if (pix_valid) begin
                        if (wx == IMG_W-1) begin
                            wx <= 5'd0;
                            if (wy == IMG_H-1) begin
                                state <= S_HC;
                                tile  <= 4'd0;
                            end else begin
                                wy <= wy + 5'd1;
                            end
                        end else begin
                            wx <= wx + 5'd1;
                        end
                    end
                end
                // ---- clear tile histogram ----------------------------------
                S_HC: begin
                    hvec  <= 128'd0;
                    n     <= 6'd0;
                    iss_v <= 1'b0;
                    d1_v  <= 1'b0;
                    state <= S_HR;
                end
                // ---- read 64 tile pixels -> hist ----------------------------
                S_HR: begin
                    // issue side: addr = ty*256 + (n>>3)*32 + tx*8 + (n&7)
                    if (!(iss_v && iss_n == 6'd63)) begin
                        fre    <= 1'b1;
                        fraddr <= {ty, 8'd0} + {tx, 3'd0} +
                                  {n[5:3], 5'd0} + {7'd0, n[2:0]};
                        iss_n  <= n;
                        iss_v  <= 1'b1;
                        n      <= n + 6'd1;
                    end else begin
                        iss_v <= 1'b0;
                    end
                    d1_v <= iss_v;  d1_n <= iss_n;
                    if (d1_v) begin
                        hvec[fq[7:4]*8 +: 8] <= hvec[fq[7:4]*8 +: 8] + 8'd1;
                        if (d1_n == 6'd63) state <= S_CS;
                    end
                end
                // ---- clip sum ----------------------------------------------
                S_CS: begin
                    ssum  <= clip_sum(hvec);
                    cdf   <= 8'd0;
                    li    <= 4'd0;
                    state <= S_LUT;
                end
                // ---- CDF -> LUT (one entry per beat) ------------------------
                S_LUT: begin
                    lwe    <= 1'b1;
                    lwaddr <= {tile, li};
                    lwdata <= lval;
                    cdf    <= ncdf[7:0];
                    if (li == 4'd15) begin
                        li <= 4'd0;
                        if (tile == 4'd15) begin
                            state <= S_AP;
                            ox    <= 5'd0;
                            oy    <= 5'd0;
                            ph    <= 4'd0;
                        end else begin
                            tile  <= tile + 4'd1;
                            state <= S_HC;
                        end
                    end else begin
                        li <= li + 4'd1;
                    end
                end
                // ---- apply: read p, 4 LUT taps, 3 lerps, emit ---------------
                S_AP: begin
                    case (ph)
                        4'd0: begin                          // frame read
                            fre    <= 1'b1;
                            fraddr <= {oy, ox};
                            if (ox == 5'd0) new_line_out <= 1'b1;
                            ph <= 4'd1;
                        end
                        4'd1: ph <= 4'd2;                    // p lands next
                        4'd2: begin                          // p= q -> LUT t00
                            pbin   <= fq[7:4];
                            lre    <= 1'b1;
                            lraddr <= {iy0, ix0, fq[7:4]};
                            ph     <= 4'd3;
                        end
                        4'd3: begin                          // LUT t01
                            lre    <= 1'b1;
                            lraddr <= {iy0, ix1, pbin};
                            ph     <= 4'd4;
                        end
                        4'd4: begin                          // LUT t10, cap m00
                            lre    <= 1'b1;
                            lraddr <= {iy1, ix0, pbin};
                            m00    <= lq;
                            ph     <= 4'd5;
                        end
                        4'd5: begin                          // LUT t11, cap m01
                            lre    <= 1'b1;
                            lraddr <= {iy1, ix1, pbin};
                            m01    <= lq;
                            ph     <= 4'd6;
                        end
                        4'd6: begin                          // cap m10, top lerp
                            m10 <= lq;
                            top <= top_s[10:0];
                            ph  <= 4'd7;
                        end
                        4'd7: begin                          // cap m11
                            m11 <= lq;
                            ph  <= 4'd8;
                        end
                        4'd8: begin                          // bot lerp
                            bot <= bot_s[10:0];
                            ph  <= 4'd9;
                        end
                        4'd9: begin                          // blend + emit
                            pix_out   <= outb;
                            out_valid <= 1'b1;
                            if (ox == IMG_W-1) begin
                                ox <= 5'd0;
                                if (oy == IMG_H-1) begin
                                    state <= S_DONE;
                                    done  <= 1'b1;
                                end else begin
                                    oy <= oy + 5'd1;
                                    ph <= 4'd0;
                                end
                            end else begin
                                ox <= ox + 5'd1;
                                ph <= 4'd0;
                            end
                        end
                        default: ph <= 4'd0;
                    endcase
                end
                S_DONE: done <= 1'b1;
                default: state <= S_WR;
            endcase
        end
    end
endmodule
