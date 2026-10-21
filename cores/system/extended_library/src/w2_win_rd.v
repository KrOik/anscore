// ============================================================================
// w2_win_rd -- generic KxK sliding-window READER over an external frame RAM.
//
// Companion to w2_dpram: the caller stores the input frame in a w2_dpram
// (or any port-compatible RAM), then pulses `start`; this module walks every
// output pixel (oy,ox) in row-major order and emits one win_valid beat per
// pixel with the KxK neighbourhood in `win`.
//
// Unlike the streaming win3x3_gen this is a RANDOM-ACCESS reader: each tap
// address is computed with independent edge clamping, so border policy is
// exactly
//     tap(r,c) = I[ clamp(oy+r-H,0,IMG_H-1) ][ clamp(ox+c-H,0,IMG_W-1) ]
// with H=(K-1)/2 and win[i*8 +: 8] = tap(r,c), i = r*K+c  (row-major taps,
// identical layout convention to imgwin_20k win3x3_gen).
//
// Throughput: one tap read per clk_en beat (read port fully pipelined),
// i.e. K*K beats per output pixel + 2-beat drain.  Intended for small
// selftest frames (<= 32x32) and for units where correctness matters more
// than rate; the ce = clk/16 selftest strobe gives the address path ~590 ns.
//
// Constraints: K odd, 3 <= K <= 9; IMG_W must be a power of two (row base is
// a shift); IMG_W*IMG_H <= 1024 for a single w2_dpram frame bank.
// ============================================================================
module w2_win_rd #(
    parameter K     = 3,
    parameter IMG_W = 32,                    // power of two
    parameter IMG_H = 32,
    parameter LW    = $clog2(IMG_W),
    parameter AW    = $clog2(IMG_W*IMG_H)
)(
    input  wire              clk,
    input  wire              clk_en,
    input  wire              rst_n,
    input  wire              start,
    // frame RAM read port (w2_dpram port-B style, registered read data)
    output reg               re,
    output reg  [AW-1:0]     raddr,
    input  wire [7:0]        q,
    // window stream out
    output reg  [K*K*8-1:0]  win,
    output reg               win_valid,
    output reg  [LW-1:0]     win_x,
    output reg  [15:0]       win_y,
    output reg               done
);
    localparam TAPS = K*K;
    localparam HD   = (K-1)/2;
    localparam IW   = (TAPS > 1) ? $clog2(TAPS) : 1;
    localparam YW   = (IMG_H > 1) ? $clog2(IMG_H) : 1;

    reg  [IW-1:0] iss;          // tap index currently being issued
    reg  [IW-1:0] d1_tap, d2_tap;
    reg           d1_v,   d2_v;
    reg           busy;
    reg  [LW-1:0] ox;           // pixel being read
    reg  [YW-1:0] oy;
    reg  [LW-1:0] ex;           // pixel being emitted
    reg  [YW-1:0] ey;
    reg           last_iss;     // final tap of final pixel issued

    function [AW-1:0] tap_addr;
        input [IW-1:0] t;
        input [YW-1:0] yy;
        input [LW-1:0] xx;
        integer r, c, ry, cx;
        begin
            r  = t / K - HD;
            c  = t % K - HD;
            ry = yy + r;
            cx = xx + c;
            if (ry < 0)         ry = 0;
            if (ry > IMG_H-1)   ry = IMG_H-1;
            if (cx < 0)         cx = 0;
            if (cx > IMG_W-1)   cx = IMG_W-1;
            tap_addr = (ry << LW) + cx;
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iss       <= {IW{1'b0}};
            d1_tap    <= {IW{1'b0}};
            d2_tap    <= {IW{1'b0}};
            d1_v      <= 1'b0;
            d2_v      <= 1'b0;
            busy      <= 1'b0;
            ox        <= {LW{1'b0}};
            oy        <= {YW{1'b0}};
            ex        <= {LW{1'b0}};
            ey        <= {YW{1'b0}};
            re        <= 1'b0;
            raddr     <= {AW{1'b0}};
            win       <= {(K*K*8){1'b0}};
            win_valid <= 1'b0;
            win_x     <= {LW{1'b0}};
            win_y     <= 16'd0;
            done      <= 1'b0;
            last_iss  <= 1'b0;
        end else if (clk_en) begin
            win_valid <= 1'b0;
            // ---- issue stage ------------------------------------------------
            re <= 1'b0;
            if (start && !busy && !done) begin
                busy <= 1'b1;
                iss  <= {IW{1'b0}};
                ox   <= {LW{1'b0}};
                oy   <= {YW{1'b0}};
                ex   <= {LW{1'b0}};
                ey   <= {YW{1'b0}};
                last_iss <= 1'b0;
            end else if (busy && !last_iss) begin
                re     <= 1'b1;
                raddr  <= tap_addr(iss, oy, ox);
                d1_tap <= iss;
                d1_v   <= 1'b1;
                iss    <= iss + 1'b1;
                if (iss == TAPS-1) begin
                    iss <= {IW{1'b0}};
                    if ((ox == IMG_W-1) && (oy == IMG_H-1)) begin
                        last_iss <= 1'b1;
                    end else if (ox == IMG_W-1) begin
                        ox <= {LW{1'b0}};
                        oy <= oy + 1'b1;
                    end else begin
                        ox <= ox + 1'b1;
                    end
                end
            end else begin
                d1_v <= 1'b0;
            end
            // ---- capture pipeline (RAM read latency = 2 beats after issue) --
            d2_tap <= d1_tap;
            d2_v   <= d1_v;
            if (d2_v) win[d2_tap*8 +: 8] <= q;
            // ---- emit -------------------------------------------------------
            if (d2_v && (d2_tap == TAPS-1)) begin
                win_valid <= 1'b1;
                win_x     <= ex;
                win_y     <= {{(16-YW){1'b0}}, ey};
                if ((ex == IMG_W-1) && (ey == IMG_H-1)) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end else if (ex == IMG_W-1) begin
                    ex <= {LW{1'b0}};
                    ey <= ey + 1'b1;
                end else begin
                    ex <= ex + 1'b1;
                end
            end
            if (done) busy <= 1'b0;
        end
    end
endmodule
