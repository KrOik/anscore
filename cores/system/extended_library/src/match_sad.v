// ============================================================================
// match_sad -- 8x8 template matching by SAD over a 32x32 frame (wave2 idx18,
// TAG SAD).
//
// Frame is streamed into a w2_dpram (T9); the 8x8 template is pre-loaded
// through the t_we/t_addr/t_data port into a second w2_dpram (64x8).  After
// `go` (one clk_en beat) the matcher slides the template over all
// (IMG_W-7) x (IMG_H-7) = 25x25 positions in row-major order:
//
//   per candidate: issue 64 paired reads (frame + template, one tap per
//   beat, registered-DO latency 2), accumulate sad += |fq - tq|,
//   then emit {sad[7:0], sad[15:8]} on pix_out/out_valid.
//   min tracking uses STRICT <, so the first (top-left) minimum wins.
//
// After the last candidate it emits {best_x, best_y, min_sad[7:0],
// min_sad[15:8]} and raises done.  Output stream = 25*25*2 + 4 bytes.
// ============================================================================
module match_sad #(
    parameter IMG_W = 32,
    parameter IMG_H = 32,
    parameter TS    = 8                        // template edge (fixed 8)
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    // frame stream in
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    // template load port (active while idle)
    input  wire        t_we,
    input  wire [5:0]  t_addr,
    input  wire [7:0]  t_data,
    // match kick-off
    input  wire        go,
    // byte stream out: per-candidate sad lo,hi then best_x,best_y,min lo,hi
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         done,
    // result registers (also folded into the byte stream)
    output reg  [7:0]  best_x,
    output reg  [7:0]  best_y,
    output reg  [15:0] min_sad
);
    localparam NPOS = IMG_W - TS + 1;          // 25
    localparam S_WR = 3'd0, S_IDLE = 3'd1, S_ISS = 3'd2,
               S_EMIT = 3'd3, S_FIN = 3'd4, S_DONE = 3'd5;

    reg  [2:0]  state;
    reg  [4:0]  cx, cy;              // candidate origin 0..24
    reg  [5:0]  i;                   // tap index 0..63
    // read pipeline: issue regs set end of beat u -> port during u+1 ->
    // DOB loads end u+1 -> q valid at u+2 = d1 stage (capture there)
    reg         iss_v, d1_v;
    reg  [5:0]  iss_i, d1_i;
    reg  [15:0] acc;
    reg  [15:0] sad_r;
    reg  [1:0]  eph;                 // emit sub-phase
    reg  [2:0]  fph;                 // final emit sub-phase
    reg  [4:0]  wx, wy;

    // ---- frame RAM ---------------------------------------------------------
    reg          fre;
    reg  [9:0]   fraddr;
    wire [7:0]   fq;
    wire         fwe    = (state == S_WR) && pix_valid;
    wire [9:0]   fwaddr = {wy, wx};
    w2_dpram #(.W(8), .DEPTH(1024), .AW(10)) u_frame (
        .clk(clk), .clk_en(clk_en),
        .we(fwe), .waddr(fwaddr), .wdata(pix),
        .re(fre), .raddr(fraddr), .q(fq));

    // ---- template RAM ------------------------------------------------------
    reg          tre;
    reg  [5:0]   traddr;
    wire [7:0]   tq;
    w2_dpram #(.W(8), .DEPTH(64), .AW(6)) u_tpl (
        .clk(clk), .clk_en(clk_en),
        .we(t_we), .waddr(t_addr), .wdata(t_data),
        .re(tre), .raddr(traddr), .q(tq));

    wire [7:0] adiff = (fq > tq) ? (fq - tq) : (tq - fq);
    wire [15:0] acc_n = acc + {8'd0, adiff};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_WR;
            cx <= 5'd0;  cy <= 5'd0;
            i  <= 6'd0;
            iss_v <= 1'b0; d1_v <= 1'b0;
            iss_i <= 6'd0; d1_i <= 6'd0;
            acc   <= 16'd0;
            sad_r <= 16'd0;
            eph   <= 2'd0;
            fph   <= 3'd0;
            wx    <= 5'd0; wy <= 5'd0;
            fre   <= 1'b0; fraddr <= 10'd0;
            tre   <= 1'b0; traddr <= 6'd0;
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            done      <= 1'b0;
            best_x    <= 8'd0;
            best_y    <= 8'd0;
            min_sad   <= 16'hFFFF;
        end else if (clk_en) begin
            fre       <= 1'b0;
            tre       <= 1'b0;
            out_valid <= 1'b0;
            case (state)
                // ---- ingest frame ------------------------------------------
                S_WR: begin
                    if (pix_valid) begin
                        if (wx == IMG_W-1) begin
                            wx <= 5'd0;
                            if (wy == IMG_H-1) begin
                                state <= S_IDLE;
                            end else begin
                                wy <= wy + 5'd1;
                            end
                        end else begin
                            wx <= wx + 5'd1;
                        end
                    end
                end
                // ---- wait for template+go -----------------------------------
                S_IDLE: begin
                    if (go) begin
                        state <= S_ISS;
                        cx    <= 5'd0;
                        cy    <= 5'd0;
                        i     <= 6'd0;
                        acc   <= 16'd0;
                        iss_v <= 1'b0;
                        d1_v  <= 1'b0;
                        min_sad <= 16'hFFFF;
                    end
                end
                // ---- 64-tap issue + accumulate ------------------------------
                S_ISS: begin
                    if (!(iss_v && iss_i == 6'd63)) begin
                        // issue tap i: frame (cy+i>>3, cx+i&7), template i
                        fre    <= 1'b1;
                        fraddr <= {cy, 5'd0} + {{2{1'b0}}, i[5:3], 5'd0}
                                  + {5'd0, cx} + {7'd0, i[2:0]};
                        tre    <= 1'b1;
                        traddr <= i;
                        iss_i  <= i;
                        iss_v  <= 1'b1;
                        i      <= i + 6'd1;
                    end else begin
                        iss_v <= 1'b0;
                    end
                    d1_v <= iss_v;  d1_i <= iss_i;
                    if (d1_v) begin
                        acc <= acc_n;
                        if (d1_i == 6'd63) begin
                            sad_r <= acc_n;
                            // strict <: first (top-left) minimum wins
                            if (acc_n < min_sad) begin
                                min_sad <= acc_n;
                                best_x  <= {3'd0, cx};
                                best_y  <= {3'd0, cy};
                            end
                            state <= S_EMIT;
                            eph   <= 2'd0;
                        end
                    end
                end
                // ---- emit sad lo,hi -----------------------------------------
                S_EMIT: begin
                    if (eph == 2'd0) begin
                        pix_out   <= sad_r[7:0];
                        out_valid <= 1'b1;
                        eph       <= 2'd1;
                    end else begin
                        pix_out   <= sad_r[15:8];
                        out_valid <= 1'b1;
                        if (cx == NPOS-1) begin
                            cx <= 5'd0;
                            if (cy == NPOS-1) begin
                                state <= S_FIN;
                                fph   <= 3'd0;
                            end else begin
                                cy    <= cy + 5'd1;
                                state <= S_ISS;
                                i     <= 6'd0;
                                acc   <= 16'd0;
                                iss_v <= 1'b0;
                                d1_v  <= 1'b0;
                            end
                        end else begin
                            cx    <= cx + 5'd1;
                            state <= S_ISS;
                            i     <= 6'd0;
                            acc   <= 16'd0;
                            iss_v <= 1'b0;
                            d1_v  <= 1'b0;
                        end
                    end
                end
                // ---- emit best_x,best_y,min lo,hi ---------------------------
                S_FIN: begin
                    out_valid <= 1'b1;
                    case (fph)
                        3'd0: pix_out <= best_x;
                        3'd1: pix_out <= best_y;
                        3'd2: pix_out <= min_sad[7:0];
                        3'd3: pix_out <= min_sad[15:8];
                        default: pix_out <= 8'd0;
                    endcase
                    if (fph == 3'd3) begin
                        state <= S_DONE;
                        done  <= 1'b1;
                    end else begin
                        fph <= fph + 3'd1;
                    end
                end
                S_DONE: done <= 1'b1;
                default: state <= S_WR;
            endcase
        end
    end
endmodule
