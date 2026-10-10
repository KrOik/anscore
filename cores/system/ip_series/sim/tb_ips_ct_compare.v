`timescale 1ns / 1ps
// tb_ips_ct_compare : production-line testbench for the whole-stream comparator.
//
// EPISODES compare streams of deterministic LCG words.  Each episode latches an
// expected length with cmp_start, drives identical / inverted / pattern-masked
// candidate words, marks the final beat with in_last and then keeps driving extra
// beats afterwards: that is how this bench proves the core has no early exit,
// because the accumulator and both counters must keep moving after end-of-stream.
// Only DUT outputs are folded, plus a final configuration stamp read out of the
// DUT instance so the shipped parameter defaults are observable in the digest.
// The expected stream is NOT written here; models/ips_ct_compare.py computes it
// independently (docs/IP_CORE_SOP.md trap T1).
module tb_ips_ct_compare;

`include "ips_tb_common.vh"

localparam integer EPISODES = 20;
localparam [31:0]  SEED     = 32'h5E45D000;

reg                 rst_n;
reg                 clk_en;
reg                 cmp_start;
reg                 in_valid;
reg                 in_last;
reg  [11:0]         exp_len_drv;
reg  [31:0]         cand_drv;
reg  [31:0]         ref_drv;
reg  [31:0]         state;
reg  [11:0]         exp_w;

wire [31:0]         diff_acc;
wire [11:0]         match_cnt;
wire [11:0]         mismatch_cnt;
wire [11:0]         beat_cnt;
wire [11:0]         exp_cnt;
wire                len_err;
wire                cmp_done;

// No #() override: the bench exercises the declared default geometry, which is
// the configuration the manifest records and the mutation station checks.
ips_ct_compare dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .cmp_start    (cmp_start),
    .exp_len      (exp_len_drv),
    .in_valid     (in_valid),
    .in_last      (in_last),
    .cand_word    (cand_drv),
    .ref_word     (ref_drv),
    .diff_acc     (diff_acc),
    .match_cnt    (match_cnt),
    .mismatch_cnt (mismatch_cnt),
    .beat_cnt     (beat_cnt),
    .exp_cnt      (exp_cnt),
    .len_err      (len_err),
    .cmp_done     (cmp_done)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer e;
integer b;
integer exp_i;
integer alen_i;
integer extra_i;
integer dsel;
integer dlt;
integer qual;
reg     bad;
reg     in_episode;
reg     obs_x;

reg     [31:0] prev_diff;
reg     [11:0] prev_match;
reg     [11:0] prev_unmatch;
reg     [11:0] prev_beat;
reg            prev_len_err;

function [31:0] next_state;
    input [31:0] s0;
    begin
        next_state = s0 * 32'd1664525 + 32'd1013904223;
    end
endfunction

// One logical beat: drive for the first half period, release for the second, then
// sample the registered outputs one enabled clock after they were loaded.
task beat;
    input              start;
    input              valid;
    input              last;
    input [31:0]       cand;
    input [31:0]       ref_v;
    begin
        @(negedge ips_clk);
        cmp_start   = start;
        in_valid    = valid;
        in_last     = last;
        cand_drv    = cand;
        ref_drv     = ref_v;

        @(negedge ips_clk);
        cmp_start = 1'b0;
        in_valid  = 1'b0;
        in_last   = 1'b0;

        obs_x = (^{diff_acc, match_cnt, mismatch_cnt, beat_cnt, exp_cnt,
                   cmp_done, len_err}) === 1'bx;
        if (obs_x) bad = 1'b1;

        // Early-exit resistance: every data beat that is not a restart advances
        // beat_cnt by exactly one and keeps both counters monotonic; the two
        // counters always account for the whole stream.
        if (valid === 1'b1 && start === 1'b0 && in_episode === 1'b1) begin
            if (({20'd0, beat_cnt} !== ({20'd0, prev_beat} + 32'd1)))        bad = 1'b1;
            if (({20'd0, match_cnt} !== {20'd0, prev_match}) &&
                ({20'd0, match_cnt} !== ({20'd0, prev_match} + 32'd1)))      bad = 1'b1;
            if (({20'd0, mismatch_cnt} !== {20'd0, prev_unmatch}) &&
                ({20'd0, mismatch_cnt} !== ({20'd0, prev_unmatch} + 32'd1))) bad = 1'b1;
            if ((({20'd0, match_cnt} + {20'd0, mismatch_cnt}) !==
                 {20'd0, beat_cnt}))                                         bad = 1'b1;
        end
        if (start === 1'b1 && diff_acc !== 32'd0) bad = 1'b1;
        // len_err is sticky inside an episode until the next restart.
        if (prev_len_err === 1'b1 && start === 1'b0 && len_err !== 1'b1) bad = 1'b1;

        prev_diff    = diff_acc;
        prev_match   = match_cnt;
        prev_unmatch = mismatch_cnt;
        prev_beat    = beat_cnt;
        prev_len_err = len_err;

        ips_fnv_word(diff_acc);
        ips_fnv_word({20'd0, match_cnt});
        ips_fnv_word({20'd0, mismatch_cnt});
        ips_fnv_word({20'd0, beat_cnt});
        ips_fnv_word({20'd0, exp_cnt});
        ips_fnv_word({30'd0, cmp_done, len_err});
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    cmp_start   = 1'b0;
    in_valid    = 1'b0;
    in_last     = 1'b0;
    exp_len_drv = 12'd0;
    cand_drv    = 32'd0;
    ref_drv     = 32'd0;
    state       = SEED;
    exp_w       = 12'd0;
    bad         = 1'b0;
    in_episode  = 1'b0;
    obs_x       = 1'b0;
    prev_diff   = 32'd0;
    prev_match  = 12'd0;
    prev_unmatch = 12'd0;
    prev_beat   = 12'd0;
    prev_len_err = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (e = 0; e < EPISODES; e = e + 1) begin
        state   = next_state(state);
        exp_i   = 8 + state[3:0];
        dsel    = state[7:5];
        case (dsel)
            3'd0:    dlt = 0;
            3'd1:    dlt = 1;
            3'd2:    dlt = -1;
            3'd3:    dlt = 2;
            3'd4:    dlt = -2;
            3'd5:    dlt = 3;
            3'd6:    dlt = -3;
            default: dlt = 0;
        endcase
        alen_i  = exp_i + dlt;
        extra_i = state[13:12];
        exp_w   = exp_i[11:0];
        exp_len_drv = exp_w;

        // restart beat: latches the expected length and clears the accumulators
        in_episode = 1'b0;
        beat(1'b1, 1'b0, 1'b0, 32'd0, 32'd0);
        in_episode = 1'b1;

        for (b = 0; b < alen_i; b = b + 1) begin
            state = next_state(state);
            qual  = state[11:10];
            case (qual)
                2'd0:    cand_drv = state;
                2'd1:    cand_drv = ~state;
                2'd2:    cand_drv = state ^ 32'h5A5A_5A5A;
                default: cand_drv = state ^ 32'h00FF_00FF;
            endcase
            beat(1'b0, 1'b1, (b == alen_i - 1), cand_drv, state);
        end

        // beats past end-of-stream: the comparator must still consume them all
        for (b = 0; b < extra_i; b = b + 1) begin
            state = next_state(state);
            beat(1'b0, 1'b1, 1'b0, state, ~state);
        end
    end

    // idle beat: outputs must hold, then the settled snapshot and the stamp
    beat(1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
    ips_fnv_word(diff_acc);
    ips_fnv_word({20'd0, match_cnt});
    ips_fnv_word({20'd0, mismatch_cnt});
    ips_fnv_word({20'd0, beat_cnt});
    ips_fnv_word({20'd0, exp_cnt});
    ips_fnv_word({30'd0, cmp_done, len_err});
    ips_fnv_word(EPISODES);
    ips_fnv_word(dut.WIDTH);
    ips_fnv_word(dut.LEN_BITS);
    ips_fnv_word(dut.ROT_BITS);
    ips_fnv_word(dut.LEN_BAD_CONST);

    ips_verdict(!bad, "ips_ct_compare");
end

endmodule
