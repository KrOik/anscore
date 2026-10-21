// ============================================================================
// st_feat_lbp -- selftest cell for feat_lbp (wave2 idx12, TAG=LBP).
// Chain: w2_img_stim(32x32) -> win3x3_gen -> feat_lbp -> FNV-1a digest.
// Output stream folded per pixel: code byte, then uniform flag byte.
// EXP digest comes from tools/golden_feat.py (trap T1 -- never backfill).
// ============================================================================
module st_feat_lbp (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire        start,
    output reg         done,
    output reg         pass,
    output reg  [31:0] digest,
    output reg  [15:0] cycles
);
    localparam [31:0] EXP  = 32'h45C677F3;
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

    wire [71:0] w_win;
    wire        w_v, w_nl, w_done;
    win3x3_gen #(.IMG_W(32), .IMG_H(32)) u_gen (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .pix(s_pix), .pix_valid(s_pv), .new_line(s_nl),
        .win(w_win), .win_valid(w_v), .new_line_out(w_nl), .done(w_done));

    wire [7:0] o_code, o_uni;
    wire       o_v, o_nl;
    feat_lbp u_dut (
        .clk(clk), .clk_en(ce), .rst_n(rst_n),
        .win(w_win), .win_valid(w_v), .new_line_out(w_nl),
        .code_out(o_code), .uni_out(o_uni),
        .out_valid(o_v), .nl_out(o_nl));

    reg [15:0] nout;
    reg [3:0]  tail;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run    <= 1'b0;
            done   <= 1'b0;
            pass   <= 1'b0;
            digest <= 32'h811C9DC5;
            cycles <= 16'd0;
            nout   <= 16'd0;
            tail   <= 4'd0;
        end else if (clk_en) begin
            if (start && !run) begin
                run    <= 1'b1;
                cycles <= 16'd0;
            end else if (run && !done) begin
                cycles <= cycles + 16'd1;
            end
            if (run && !done) begin
                if (o_v) begin
                    digest <= fnv(fnv(digest, o_code), o_uni);
                    nout   <= nout + 16'd1;
                end
                if (w_done) begin
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
