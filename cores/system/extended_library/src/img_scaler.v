// ============================================================================
// img_scaler -- bilinear image rescaler (wave2 unit idx15, TAG SCL).
//
// Streams an IMG_W x IMG_H frame into a w2_dpram bank (T9: no inferred RAM),
// then generates an OUT_W x OUT_H image with bilinear interpolation:
//
//   STX = (IMG_W*256)/OUT_W  (truncated, elaboration constant, accumulated
//   per output column so NO multiplier is needed for source positions)
//   sx_q8 = ox*STX ; xi = sx_q8[15:8] ; fx = sx_q8[7:0] ; xi2 = min(xi+1,W-1)
//   top = (a<<8) + (b-a)*fx ; bot = (c<<8) + (d-c)*fx          [Q8 pixels]
//   res = (top<<8) + (bot-top)*fy                              [Q16 pixel]
//   out = clamp((res + 0x8000) >> 16, 0, 255)
//
// The only true products are (delta)*(8-bit frac): one shared signed x
// unsigned shift-add multiplier (mulsu) is time-muxed over 3 beats -- zero
// DSP slices (T4).  8 clk_en beats per output pixel.
//
// Stream contract: input = imgwin-style new_line + pix_valid rows (new_line
// unused internally; pixels counted).  Output = new_line_out beat per row,
// then OUT_W pix_out/out_valid beats.  done latches after last pixel.
//
// IMG_W/IMG_H must be powers of two (frame address = {y,x} concat) and
// IMG_W*IMG_H <= 1024 (single BSRAM bank).  OUT_W/OUT_H <= 64 arbitrary.
// ============================================================================
module img_scaler #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter OUT_W = 16,
    parameter OUT_H = 16,
    parameter LW    = $clog2(IMG_W),
    parameter LH    = $clog2(IMG_H),
    parameter OW    = (OUT_W > 1) ? $clog2(OUT_W) : 1,
    parameter OH    = (OUT_H > 1) ? $clog2(OUT_H) : 1,
    parameter AW    = $clog2(IMG_W*IMG_H),
    parameter [15:0] STX = (IMG_W*256)/OUT_W,
    parameter [15:0] STY = (IMG_H*256)/OUT_H
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
    localparam S_WR = 2'd0, S_GEN = 2'd1, S_DONE = 2'd2;

    // ---- state -------------------------------------------------------------
    reg  [1:0]  state;
    reg  [3:0]  ph;
    reg  [OW-1:0] ox;
    reg  [OH-1:0] oy;
    reg  [15:0] sx_acc, sy_acc;
    reg  [7:0]  aq, bq, cq, dq;
    reg  [16:0] top, bot;

    // ---- frame RAM ---------------------------------------------------------
    reg           fre;
    reg  [AW-1:0] fraddr;
    wire [7:0]    fq;
    wire          fwe    = (state == S_WR) && pix_valid;
    reg  [LW-1:0] wx_r;
    reg  [LH-1:0] wy_r;
    wire [AW-1:0] fwaddr = {wy_r, wx_r};

    w2_dpram #(.W(8), .DEPTH(IMG_W*IMG_H), .AW(AW)) u_frame (
        .clk(clk), .clk_en(clk_en),
        .we(fwe), .waddr(fwaddr), .wdata(pix),
        .re(fre), .raddr(fraddr), .q(fq));

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

    wire [7:0] xi  = sx_acc[15:8];
    wire [7:0] yi  = sy_acc[15:8];
    wire [7:0] fx  = sx_acc[7:0];
    wire [7:0] fy  = sy_acc[7:0];
    wire [7:0] xi2 = (xi == IMG_W-1) ? xi : xi + 8'd1;
    wire [7:0] yi2 = (yi == IMG_H-1) ? yi : yi + 8'd1;

    // multiplier operand mux + this-beat products
    always @(*) begin
        mx = 18'sd0;
        my = 8'd0;
        if (state == S_GEN) begin
            case (ph)
                4'd5: begin
                    mx = $signed({1'b0, bq}) - $signed({1'b0, aq});
                    my = fx;
                end
                4'd6: begin
                    mx = $signed({1'b0, dq}) - $signed({1'b0, cq});
                    my = fx;
                end
                4'd7: begin
                    mx = $signed({1'b0, bot}) - $signed({1'b0, top});
                    my = fy;
                end
                default: begin mx = 18'sd0; my = 8'd0; end
            endcase
        end
    end

    wire signed [26:0] top_s = $signed({2'b00, aq, 8'd0}) + mp;   // (a<<8)+(b-a)fx
    wire signed [26:0] bot_s = $signed({2'b00, cq, 8'd0}) + mp;   // (c<<8)+(d-c)fx
    wire signed [26:0] res_s = $signed({1'b0, top, 8'd0}) + mp;   // Q16 result
    wire signed [27:0] res_r = res_s + 28'sd32768;                // rounding
    wire [7:0] outb = res_r[27]        ? 8'd0    :
                      (|res_r[26:24])  ? 8'hFF   : res_r[23:16];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_WR;
            ph           <= 4'd0;
            ox           <= {OW{1'b0}};
            oy           <= {OH{1'b0}};
            sx_acc       <= 16'd0;
            sy_acc       <= 16'd0;
            wx_r         <= {LW{1'b0}};
            wy_r         <= {LH{1'b0}};
            aq           <= 8'd0;
            bq           <= 8'd0;
            cq           <= 8'd0;
            dq           <= 8'd0;
            top          <= 17'd0;
            bot          <= 17'd0;
            fre          <= 1'b0;
            fraddr       <= {AW{1'b0}};
            pix_out      <= 8'd0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            done         <= 1'b0;
        end else if (clk_en) begin
            fre          <= 1'b0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
            case (state)
                // ---- ingest ------------------------------------------------
                S_WR: begin
                    if (pix_valid) begin
                        if (wx_r == IMG_W-1) begin
                            wx_r <= {LW{1'b0}};
                            if (wy_r == IMG_H-1) begin
                                state  <= S_GEN;
                                ph     <= 4'd0;
                                ox     <= {OW{1'b0}};
                                oy     <= {OH{1'b0}};
                                sx_acc <= 16'd0;
                                sy_acc <= 16'd0;
                            end else begin
                                wy_r <= wy_r + 1'b1;
                            end
                        end else begin
                            wx_r <= wx_r + 1'b1;
                        end
                    end
                end
                // ---- generate ----------------------------------------------
                S_GEN: begin
                    case (ph)
                        4'd0: begin                          // issue tap a
                            fre    <= 1'b1;
                            fraddr <= {yi[LH-1:0], xi[LW-1:0]};
                            if (ox == {OW{1'b0}}) new_line_out <= 1'b1;
                            ph <= 4'd1;
                        end
                        4'd1: begin                          // issue tap b
                            fre    <= 1'b1;
                            fraddr <= {yi[LH-1:0], xi2[LW-1:0]};
                            ph <= 4'd2;
                        end
                        4'd2: begin                          // issue c, cap a
                            fre    <= 1'b1;
                            fraddr <= {yi2[LH-1:0], xi[LW-1:0]};
                            aq <= fq;
                            ph <= 4'd3;
                        end
                        4'd3: begin                          // issue d, cap b
                            fre    <= 1'b1;
                            fraddr <= {yi2[LH-1:0], xi2[LW-1:0]};
                            bq <= fq;
                            ph <= 4'd4;
                        end
                        4'd4: begin                          // cap c
                            cq <= fq;
                            ph <= 4'd5;
                        end
                        4'd5: begin                          // cap d, top lerp
                            dq  <= fq;
                            top <= top_s[16:0];
                            ph  <= 4'd6;
                        end
                        4'd6: begin                          // bot lerp
                            bot <= bot_s[16:0];
                            ph  <= 4'd7;
                        end
                        4'd7: begin                          // vertical + emit
                            pix_out   <= outb;
                            out_valid <= 1'b1;
                            if (ox == OUT_W-1) begin
                                ox     <= {OW{1'b0}};
                                sx_acc <= 16'd0;
                                ph     <= 4'd0;
                                if (oy == OUT_H-1) begin
                                    state <= S_DONE;
                                    done  <= 1'b1;
                                end else begin
                                    oy     <= oy + 1'b1;
                                    sy_acc <= sy_acc + STY;
                                end
                            end else begin
                                ox     <= ox + 1'b1;
                                sx_acc <= sx_acc + STX;
                                ph     <= 4'd0;
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
