`timescale 1ns / 1ps
// tb_ips_topk_argmax4 : production-line testbench for the top-4 score selector.
//
// CB consumed beats (NVEC vectors of NSCTB scores each, so well over the 200-beat
// floor) follow the shared LCG contract documented in models/ips_topk_argmax4.py.
// The index that travels with each score is a permutation of the vector position, so
// scores arrive out of index order and the tie-break by index -- not arrival order --
// decides the list.  Per-vector score patterns: full random, coarse random (many
// exact ties), eight levels, every score equal to the maximum, every score equal to
// the minimum and a two-level split, so ties and drops abound; positions 3, 7, 11 and
// 13 additionally force zero, +2047, -2048 and +1 into every vector.  Properties are
// all derived from DUT outputs (or from the score the core itself reports as having
// been written) and use === / !== so an X can never look like a pass
// (docs/IP_CORE_SOP.md trap T6).  The run ends after a fixed number of edges, never
// on a DUT-conditional state.
module tb_ips_topk_argmax4;

`include "ips_tb_common.vh"

localparam integer NSCTB = 16;
localparam integer NVEC  = 16;
localparam integer CB    = NVEC * NSCTB;
localparam [31:0] SEED = 32'h7AC1_0003;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg  signed [11:0] sv;
reg  [3:0]         iv;
reg  [31:0]        state;

wire signed [11:0] t0;
wire signed [11:0] t1;
wire signed [11:0] t2;
wire signed [11:0] t3;
wire [3:0]         i0;
wire [3:0]         i1;
wire [3:0]         i2;
wire [3:0]         i3;
wire               v0;
wire               v1;
wire               v2;
wire               v3;
wire [2:0]         pos_last;
wire [4:0]         beat_last;
wire               done;
wire               rep_last;
wire               drop_last;
wire               in_last;
wire [7:0]         drop_count;
wire [7:0]         rep_count;
wire [31:0]        cfg_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_topk_argmax4 dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .s         (sv),
    .idx       (iv),
    .t0        (t0),
    .t1        (t1),
    .t2        (t2),
    .t3        (t3),
    .i0        (i0),
    .i1        (i1),
    .i2        (i2),
    .i3        (i3),
    .v0        (v0),
    .v1        (v1),
    .v2        (v2),
    .v3        (v3),
    .pos_last  (pos_last),
    .beat_last (beat_last),
    .done      (done),
    .rep_last  (rep_last),
    .drop_last (drop_last),
    .in_last   (in_last),
    .drop_count(drop_count),
    .rep_count (rep_count),
    .cfg_id    (cfg_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer b;
integer nb;
integer p;
integer vec;
integer exp_drop;
integer exp_rep;
reg        bad;
reg        xbad;
reg        consumed;
reg        held;
reg        exp_done;
reg [11:0] pt0;
reg [11:0] pt1;
reg [11:0] pt2;
reg [11:0] pt3;
reg [3:0]  pi0;
reg [3:0]  pi1;
reg [3:0]  pi2;
reg [3:0]  pi3;
reg        pv0;
reg        pv1;
reg        pv2;
reg        pv3;
reg [2:0]  ppos;
reg [4:0]  pbeat;
reg        pdone;
reg        prep;
reg        pdrop;
reg [7:0]  pdc;
reg [7:0]  prc;

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    in_valid   = 1'b0;
    sv         = 12'sd0;
    iv         = 4'd0;
    state      = SEED;
    bad        = 1'b0;
    nb         = 0;
    exp_drop   = 0;
    exp_rep    = 0;
    consumed   = 1'b0;
    held       = 1'b0;
    exp_done   = 1'b0;
    pt0        = 12'h800;
    pt1        = 12'h800;
    pt2        = 12'h800;
    pt3        = 12'h800;
    pi0        = 4'hf;
    pi1        = 4'hf;
    pi2        = 4'hf;
    pi3        = 4'hf;
    pv0        = 1'b0;
    pv1        = 1'b0;
    pv2        = 1'b0;
    pv3        = 1'b0;
    ppos       = 3'd4;
    pbeat      = 5'd0;
    pdone      = 1'b0;
    prep       = 1'b0;
    pdrop      = 1'b0;
    pdc        = 8'h00;
    prc        = 8'h00;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (b = 0; b < CB; b = b + 1) begin
        @(negedge ips_clk);

        state = state * 32'd1664525 + 32'd1013904223;
        p     = b % NSCTB;
        vec   = b / NSCTB;
        iv    = (p * 5 + vec) % NSCTB;

        case (vec % 6)
            0:       sv = state[11:0];
            1:       sv = {state[11:8], 4'd0, 4'd0};
            2:       sv = {state[11:9], 9'd0};
            3:       sv = 12'h7ff;
            4:       sv = 12'h800;
            default: sv = (p < 8) ? 12'sd100 : -12'sd100;
        endcase
        if (p == 3)  sv = 12'sd0;
        if (p == 7)  sv = 12'h7ff;
        if (p == 11) sv = 12'h800;
        if (p == 13) sv = 12'sd1;

        in_valid = 1'b1;
        consumed = 1'b1;
        held     = 1'b0;

        @(negedge ips_clk);
        in_valid = 1'b0;
        observe;

        if ((b % 27) == 26) begin
            // One extra beat with in_valid low: nothing the core publishes may move.
            @(negedge ips_clk);
            consumed = 1'b0;
            held     = 1'b1;
            observe;
        end

        if ((b % 40) == 39) begin
            clk_en = 1'b0;
            @(negedge ips_clk);
            @(negedge ips_clk);
            clk_en = 1'b1;
        end
    end

    repeat (4) @(negedge ips_clk);
`ifdef IPSDBG
    $display("T %h %h %h", {24'd0, drop_count}, {24'd0, rep_count}, nb);
`endif
    ips_fnv_word({24'd0, drop_count});
    ips_fnv_word({24'd0, rep_count});
    ips_fnv_word(nb);

    ips_verdict(!bad, "ips_topk_argmax4");
end

task observe;
    begin
        xbad = 1'b0;
        if ((^t0) === 1'bx || (^t1) === 1'bx) xbad = 1'b1;
        if ((^t2) === 1'bx || (^t3) === 1'bx) xbad = 1'b1;
        if ((^i0) === 1'bx || (^i1) === 1'bx) xbad = 1'b1;
        if ((^i2) === 1'bx || (^i3) === 1'bx) xbad = 1'b1;
        if ((^pos_last) === 1'bx || (^beat_last) === 1'bx) xbad = 1'b1;
        if ((^drop_count) === 1'bx || (^rep_count) === 1'bx) xbad = 1'b1;
        if ((^cfg_id) === 1'bx) xbad = 1'b1;
        if (v0 === 1'bx || v1 === 1'bx || v2 === 1'bx || v3 === 1'bx) xbad = 1'b1;
        if (done === 1'bx || rep_last === 1'bx || drop_last === 1'bx) xbad = 1'b1;
        if (in_last === 1'bx) xbad = 1'b1;
        if (xbad !== 1'b0) bad = 1'b1;

        if (in_last !== consumed) bad = 1'b1;

        if (held) begin
            if (t0 !== pt0 || t1 !== pt1 || t2 !== pt2 || t3 !== pt3) bad = 1'b1;
            if (i0 !== pi0 || i1 !== pi1 || i2 !== pi2 || i3 !== pi3) bad = 1'b1;
            if (v0 !== pv0 || v1 !== pv1 || v2 !== pv2 || v3 !== pv3) bad = 1'b1;
            if (pos_last !== ppos || beat_last !== pbeat) bad = 1'b1;
            if (done !== pdone || rep_last !== prep || drop_last !== pdrop) bad = 1'b1;
            if (drop_count !== pdc || rep_count !== prc) bad = 1'b1;
        end

        if (consumed) begin
            exp_done = ((b % NSCTB) == (NSCTB - 1));
            if (done !== exp_done) bad = 1'b1;

            if (pos_last === 3'd4) begin
                // A score that did not make the list leaves it untouched.
                if (t0 !== pt0 || t1 !== pt1 || t2 !== pt2 || t3 !== pt3) bad = 1'b1;
                if (i0 !== pi0 || i1 !== pi1 || i2 !== pi2 || i3 !== pi3) bad = 1'b1;
                if (v0 !== pv0 || v1 !== pv1 || v2 !== pv2 || v3 !== pv3) bad = 1'b1;
            end else begin
                // The lane the core reports as written holds that beat's score.
                case (pos_last)
                    3'd0: if (t0 !== sv || i0 !== iv) bad = 1'b1;
                    3'd1: if (t1 !== sv || i1 !== iv) bad = 1'b1;
                    3'd2: if (t2 !== sv || i2 !== iv) bad = 1'b1;
                    default: if (t3 !== sv || i3 !== iv) bad = 1'b1;
                endcase
            end

            // An index never appears twice among the valid lanes.
            if (v0 === 1'b1) begin
                if (v1 === 1'b1 && (i0 === i1)) bad = 1'b1;
                if (v2 === 1'b1 && (i0 === i2)) bad = 1'b1;
                if (v3 === 1'b1 && (i0 === i3)) bad = 1'b1;
            end
            if (v1 === 1'b1) begin
                if (v2 === 1'b1 && (i1 === i2)) bad = 1'b1;
                if (v3 === 1'b1 && (i1 === i3)) bad = 1'b1;
            end
            if (v2 === 1'b1 && v3 === 1'b1 && (i2 === i3)) bad = 1'b1;

            // The lanes are ordered by score, and by index where scores tie.
            if ((t0 < t1) === 1'b1) bad = 1'b1;
            if ((t1 < t2) === 1'b1) bad = 1'b1;
            if ((t2 < t3) === 1'b1) bad = 1'b1;
            if (v0 === 1'b1 && v1 === 1'b1 && t0 === t1 && (i0 >= i1)) bad = 1'b1;
            if (v1 === 1'b1 && v2 === 1'b1 && t1 === t2 && (i1 >= i2)) bad = 1'b1;
            if (v2 === 1'b1 && v3 === 1'b1 && t2 === t3 && (i2 >= i3)) bad = 1'b1;

            // Valid lanes form a prefix, and a new vector starts with one lane.
            if (v0 === 1'b0 && (v1 === 1'b1 || v2 === 1'b1 || v3 === 1'b1)) bad = 1'b1;
            if (v1 === 1'b0 && (v2 === 1'b1 || v3 === 1'b1)) bad = 1'b1;
            if (v2 === 1'b0 && v3 === 1'b1) bad = 1'b1;
            if (beat_last === 5'd0) begin
                if (v0 !== 1'b1) bad = 1'b1;
                if (v1 === 1'b1 || v2 === 1'b1 || v3 === 1'b1) bad = 1'b1;
            end

            // A tie-break insertion pushes an equal score one lane down, behind a
            // larger index, and is never also a drop.
            if (rep_last === 1'b1 && drop_last === 1'b1) bad = 1'b1;
            if (rep_last === 1'b1) begin
                case (pos_last)
                    3'd0: if (t1 !== t0 || (i1 <= i0)) bad = 1'b1;
                    3'd1: if (t2 !== t1 || (i2 <= i1)) bad = 1'b1;
                    3'd2: if (t3 !== t2 || (i3 <= i2)) bad = 1'b1;
                    default: ;
                endcase
            end

            if (drop_last === 1'b1) exp_drop = exp_drop + 1;
            if (rep_last === 1'b1)  exp_rep = exp_rep + 1;
            if (drop_count !== exp_drop[7:0]) bad = 1'b1;
            if (rep_count !== exp_rep[7:0]) bad = 1'b1;
        end

        ips_fnv_word({16'd0, i3, i2, i1, i0});
`ifdef IPSDBG
        $display("S %h %h %h %h %h %h", {16'd0, i3, i2, i1, i0}, {8'd0, t3, t2},
                 {8'd0, t1, t0},
                 {24'd0, v3, v2, v1, v0, done, rep_last, drop_last, in_last},
                 {24'd0, beat_last, pos_last}, cfg_id);
`endif
        ips_fnv_word({8'd0, t3, t2});
        ips_fnv_word({8'd0, t1, t0});
        ips_fnv_word({24'd0, v3, v2, v1, v0, done, rep_last, drop_last, in_last});
        ips_fnv_word({24'd0, beat_last, pos_last});
        ips_fnv_word(cfg_id);

        pt0   = t0;
        pt1   = t1;
        pt2   = t2;
        pt3   = t3;
        pi0   = i0;
        pi1   = i1;
        pi2   = i2;
        pi3   = i3;
        pv0   = v0;
        pv1   = v1;
        pv2   = v2;
        pv3   = v3;
        ppos  = pos_last;
        pbeat = beat_last;
        pdone = done;
        prep  = rep_last;
        pdrop = drop_last;
        pdc   = drop_count;
        prc   = rep_count;
        nb    = nb + 1;
    end
endtask

endmodule
