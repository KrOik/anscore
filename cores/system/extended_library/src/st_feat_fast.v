// ============================================================================
// st_feat_fast -- selftest cell for feat_fast (wave2 idx11, TAG=FST).
// Chain: w2_img_stim(32x32) -> feat_fast(capture -> w2_win_rd K=7 -> FAST).
// The DUT `start` is pulsed once after the stimulus finishes the frame
// capture.  Output stream folded per pixel: flag byte, then arc byte.
// EXP digest comes from tools/golden_feat.py (trap T1 -- never backfill).
// ============================================================================
module st_feat_fast (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam [31:0] EXP  = 32'hE1DEB6B0;
    localparam [15:0] NEXP = 16'd1024;

`include "w2_fnv.vh"

    reg run;
    wire ce = (clk_en & run) | ~rst_n;

    wire [7:0]  s_pix;
    wire        s_pv, s_nl, s_done;
    w2_img_stim #(.IMG_W(32), .IMG_H(32), .N_FRAMES(1)) u_stim (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix24(), .pix_valid(s_pv), .new_line(s_nl),
        .fidx(), .stim_done(s_done));

    // pulse DUT start once after capture completes
    reg  f_start, f_started;
    wire [7:0] o_flag, o_arc;
    wire       o_v, d_done;
    feat_fast #(.IMG_W(32), .IMG_H(32), .N(9), .THRESH(8'd24)) u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .start(f_start),
        .flag_out(o_flag), .arc_out(o_arc),
        .out_valid(o_v), .done(d_done));

    reg [15:0] nout;
    reg [3:0]  tail;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run       <= 1'b0;
            done      <= 1'b0;
            pass      <= 1'b0;
            digest    <= 32'h811C9DC5;
            cycles    <= 16'd0;
            nout      <= 16'd0;
            tail      <= 4'd0;
            f_start   <= 1'b0;
            f_started <= 1'b0;
        end else if (clk_en) begin
            if (start && !run) begin
                run    <= 1'b1;
                cycles <= 16'd0;
            end else if (run && !done) begin
                cycles <= cycles + 16'd1;
            end
            f_start <= 1'b0;
            if (run && !done) begin
                if (s_done && !f_started) begin
                    f_start   <= 1'b1;
                    f_started <= 1'b1;
                end
                if (o_v) begin
                    digest <= fnv(fnv(digest, o_flag), o_arc);
                    nout   <= nout + 16'd1;
                end
                if (d_done) begin
                    tail <= tail + 4'd1;
                    if (tail == 4'd10) begin
                        done <= 1'b1;
                        pass <= (digest === EXP) && (nout === NEXP);
                    end
                end
            end
        end
    end
endmodule
