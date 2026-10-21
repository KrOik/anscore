`timescale 1ns / 1ps
// tb_ips_speck128_block : production-line testbench for the bit-serial
// SPECK128/128 block cipher engine.
//
// No #() override: the bench exercises the declared default geometry, which is
// the configuration the manifest records and the mutation station checks.
//
// FOLDING RULE (stated here first, and stated identically at the top of
// models/ips_speck128_block.py -- the two must agree byte for byte):
//   One logical beat = exactly one ENABLED rising edge of the core.  Inputs are
//   driven on the half period before that edge and released on the half period
//   after it, so no beat ever straddles two enabled edges and every combinational
//   output is folded with the inputs already released (all request lines low).
//   ips_cycle is incremented by the common helper on every enabled edge.
//   Seven words are folded after every beat, in this order:
//     1  ct_x[31:0]
//     2  ct_x[63:32]
//     3  ct_y[31:0]
//     4  ct_y[63:32]
//     5  {18'd0, err_code, done, busy, err, ld_ready, align, bit_pos}
//     6  {20'd0, round_cnt, sched_cnt}
//     7  {24'd0, key_cnt, blk_cnt}
//   After the last beat, a tail stamp of nine more words: the operation count,
//   then the eight parameter defaults read out of the DUT instance
//   (WORD_BITS, ROUNDS, LOAD_WORDS, BUS_BITS, ROT_X, ROT_Y, POS_BITS, IDX_BITS),
//   so the shipped geometry is observable in the digest and every parameter has a
//   path to it.
//
// WHAT IS CHECKED HERE AND WHAT IS NOT.  This bench checks protocol conformance
// against the contract written in src/ips_speck128_block.v: X-freedom on every
// beat, the exact beat budget of a full operation, done/busy/counter closure, the
// first-error-wins codes on every malformed sequence, that refused beats leave the
// state untouched, and that inserted disabled edges are ignored.  It deliberately
// does NOT contain a single expected ciphertext: the cipher values are computed
// independently by models/ips_speck128_block.py from the published NSA SIMON and
// SPECK Implementation Guide 1.1 (docs/IP_CORE_SOP.md trap T1), so nothing in this
// file could be retuned to match a simulation digest.
module tb_ips_speck128_block;

`include "ips_tb_common.vh"

// beat budget of one full operation, derived from the DUT's own geometry
localparam integer LBW    = 32;          // beats per loaded word (= BUS_BITS)
localparam integer LOADW  = 4;           // words per stream
localparam integer LAPSZ  = 64;          // beats per lap (= WORD_BITS)
localparam integer RONDS  = 32;          // scored laps (= ROUNDS)
localparam integer ARMBE  = 1;           // run_pend -> busy beat
localparam integer RUNBP  = 1 + LOADW*LBW*2 + 1 + ARMBE + LAPSZ*(RONDS + 1);
localparam integer NSTOPS = 14;          // operations in the list below

reg                 rst_n;
reg                 clk_en;
reg                 start_drv;
reg                 run_drv;
reg                 kw_drv;
reg                 bw_drv;
reg  [31:0]         word_drv;
reg  [31:0]         state;
reg  [31:0]         kws [0:3];
reg  [31:0]         bws [0:3];
reg                 stall_req;
reg                 do_stall;
integer             stalled;
reg                 bad;
reg                 obs_x;
reg                 term_ok;

wire [63:0]         ct_x;
wire [63:0]         ct_y;
wire                err;
wire                ld_ready;
wire                align;
wire [5:0]          bit_pos;
wire [5:0]          round_cnt;
wire [5:0]          sched_cnt;
wire [3:0]          key_cnt;
wire [3:0]          blk_cnt;
wire [2:0]          err_code;
wire                done;
wire                busy;

ips_speck128_block dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start_drv),
    .run_req    (run_drv),
    .kw_valid   (kw_drv),
    .bw_valid   (bw_drv),
    .ld_word    (word_drv),
    .ct_x       (ct_x),
    .ct_y       (ct_y),
    .err        (err),
    .ld_ready   (ld_ready),
    .align      (align),
    .bit_pos    (bit_pos),
    .round_cnt  (round_cnt),
    .sched_cnt  (sched_cnt),
    .key_cnt    (key_cnt),
    .blk_cnt    (blk_cnt),
    .err_code   (err_code),
    .done       (done),
    .busy       (busy)
);

// the cycle counter is driven by the clock, not by the beat task, so a disabled
// edge can never be mistaken for a beat
always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function [31:0] next_state;
    input [31:0] s0;
    begin
        next_state = s0 * 32'd1664525 + 32'd1013904223;
    end
endfunction

// ---- one logical beat -------------------------------------------------------
// N1: drive.  Then either the very next rising edge is the sampling edge, or --
// when this beat is selected for a stall -- one DISABLED rising edge is inserted
// first and the following enabled edge becomes the sampling edge.  Inputs stay
// driven until the half period after that enabled edge, where they are released
// and the outputs are observed and folded.  Exactly one enabled edge per call.
task beat;
    input              st;
    input              rn;
    input              kwv;
    input              bwv;
    input [31:0]       wd;
    begin
        @(negedge ips_clk);
        start_drv = st;
        run_drv   = rn;
        kw_drv    = kwv;
        bw_drv    = bwv;
        word_drv  = wd;
        do_stall  = (stall_req === 1'b1) && ((ips_cycle % 32'd5) === 32'd3);
        if (do_stall) begin
            clk_en   = 1'b0;
            @(negedge ips_clk);
            clk_en   = 1'b1;
            stalled  = stalled + 1;
        end
        @(negedge ips_clk);

        start_drv = 1'b0;
        run_drv   = 1'b0;
        kw_drv    = 1'b0;
        bw_drv    = 1'b0;
        word_drv  = 32'd0;

        obs_x = (^{ct_x, ct_y, err_code, done, busy, err, ld_ready, align,
                   bit_pos, round_cnt, sched_cnt, key_cnt, blk_cnt}) === 1'bx;
        if (obs_x) bad = 1'b1;

        ips_fnv_word(ct_x[31:0]);
        ips_fnv_word(ct_x[63:32]);
        ips_fnv_word(ct_y[31:0]);
        ips_fnv_word(ct_y[63:32]);
        ips_fnv_word({18'd0, err_code, done, busy, err, ld_ready, align, bit_pos});
        ips_fnv_word({20'd0, round_cnt, sched_cnt});
        ips_fnv_word({24'd0, key_cnt, blk_cnt});
    end
endtask

// reset without folding: the core's reset values are still observed, on the very
// next (folded) beat
task reset_core;
    begin
        @(negedge ips_clk);
        clk_en    = 1'b0;
        rst_n     = 1'b0;
        repeat (4) @(negedge ips_clk);
        rst_n     = 1'b1;
        @(negedge ips_clk);
        clk_en    = 1'b1;
    end
endtask

// ---- documented sequences ---------------------------------------------------
// a complete, well-formed operation: start, 4 key words, 4 block words, run,
// then sit through the align lap and ROUNDS scored laps
task full_op;
    integer j;
    integer b;
    begin
        beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);        // settles the previous op
        beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);        // start
        for (j = 0; j < LOADW; j = j + 1) begin
            beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
            for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
        end
        for (j = 0; j < LOADW; j = j + 1) begin
            beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
            for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
        end
        beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);        // run_req
        for (b = 0; b < ARMBE + LAPSZ*(RONDS + 1); b = b + 1)
            beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
endtask

// the same budget without the leading settle beat, for the very first operation
task first_op;
    integer j;
    integer b;
    begin
        beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
        for (j = 0; j < LOADW; j = j + 1) begin
            beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
            for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
        end
        for (j = 0; j < LOADW; j = j + 1) begin
            beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
            for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
        end
        beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
        for (b = 0; b < ARMBE + LAPSZ*(RONDS + 1); b = b + 1)
            beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
endtask

// published vectors, guide section 16, least-significant word first
task load_published;
    begin
        kws[0] = 32'h03020100;  kws[1] = 32'h07060504;   // A = K[0]
        kws[2] = 32'h0b0a0908;  kws[3] = 32'h0f0e0d0c;   // B = K[1]
        bws[0] = 32'h64616d20;  bws[1] = 32'h74692065;   // Pt[0]
        bws[2] = 32'h75716520;  bws[3] = 32'h6c617669;   // Pt[1]
    end
endtask

// the published ciphertext fed back as the next plaintext (chained block)
task load_chained;
    begin
        kws[0] = 32'h03020100;  kws[1] = 32'h07060504;
        kws[2] = 32'h0b0a0908;  kws[3] = 32'h0f0e0d0c;
        bws[0] = 32'h5c570d18;  bws[1] = 32'h7860fedf;   // Ct[0]
        bws[2] = 32'h79783265;  bws[3] = 32'ha65d9851;   // Ct[1]
    end
endtask

// deterministic random stream, one LCG step per word, key words first
task load_random;
    input integer r;
    integer i;
    begin
        for (i = 0; i < LOADW; i = i + 1) begin
            state  = next_state(state);
            kws[i] = state ^ (32'ha0000000 | (r << 4) | i);
        end
        for (i = 0; i < LOADW; i = i + 1) begin
            state  = next_state(state);
            bws[i] = state ^ (32'hb0000000 | (r << 4) | i);
        end
    end
endtask

// closure check of a finished, error-free operation
task check_full_done;
    begin
        if (done !== 1'b1)                                    bad = 1'b1;
        if (busy !== 1'b0)                                    bad = 1'b1;
        if (err  !== 1'b0)                                    bad = 1'b1;
        if (err_code !== 3'd0)                                bad = 1'b1;
        if (align  !== 1'b0)                                  bad = 1'b1;
        if (ld_ready !== 1'b0)                                bad = 1'b1;
        if (bit_pos !== 6'd0)                                 bad = 1'b1;
        if (round_cnt !== 6'd32)                              bad = 1'b1;
        if (sched_cnt !== 6'd31)                              bad = 1'b1;
        if (key_cnt !== 4'd4 || blk_cnt !== 4'd4)             bad = 1'b1;
    end
endtask

integer op;
integer j;
integer b;

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    start_drv = 1'b0;
    run_drv   = 1'b0;
    kw_drv    = 1'b0;
    bw_drv    = 1'b0;
    word_drv  = 32'd0;
    state     = 32'h5E0C1280;
    stall_req = 1'b0;
    bad       = 1'b0;
    obs_x     = 1'b0;
    term_ok   = 1'b1;
    kws[0] = 32'd0; kws[1] = 32'd0; kws[2] = 32'd0; kws[3] = 32'd0;
    bws[0] = 32'd0; bws[1] = 32'd0; bws[2] = 32'd0; bws[3] = 32'd0;

    @(negedge ips_clk);
    rst_n  = 1'b1;
    clk_en = 1'b1;
    @(negedge ips_clk);

    // op 1: the published SPECK128/128 vector, one clean full operation
    load_published();
    first_op();
    check_full_done();

    // op 2: same key, the published ciphertext re-encrypted (chained block)
    load_chained();
    full_op();
    check_full_done();

    // op 3: random vector 1
    load_random(32'd1, 1'b1);
    full_op();
    check_full_done();

    // op 4: random vector 2, with one disabled edge inserted before every beat
    // whose index inside the operation is 3 mod 5 -- proves that every register
    // really is clk_en gated, because a register that free-ran would drift away
    // from the beat budget the model replays
    load_random(32'd2, 1'b1);
    stall_req = 1'b1;
    first_stall_op();
    stall_req = 1'b0;
    check_full_done();

    // op 5: random vector 3
    load_random(32'd3, 1'b1);
    full_op();
    check_full_done();

    // op 6: ERR_MIXED -- key and block requested in the same beat
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b0, 1'b1, 1'b0, kws[0]);
    for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b0, 1'b1, 1'b1, kws[1]);            // both valid -> refused
    for (j = 2; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);             // run refused, done anyway
    if (err_code !== 3'd3 || done !== 1'b1 || busy !== 1'b0) bad = 1'b1;

    // op 7: ERR_KWORD -- a fifth key word
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b0, 1'b1, 1'b0, 32'hdeadbeef);      // overflow
    if (err_code !== 3'd1) bad = 1'b1;
    if (key_cnt !== 4'd4)  bad = 1'b1;
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    if (err_code !== 3'd1 || done !== 1'b1) bad = 1'b1;

    // op 8: ERR_BWORD -- a fifth block word, on top of a pending key overflow
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);             // start clears the error
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b0, 1'b0, 1'b1, 32'h5a5a5a5a);      // overflow
    if (err_code !== 3'd2) bad = 1'b1;
    beat(1'b0, 1'b0, 1'b1, 1'b0, 32'h12345678);      // first error wins
    if (err_code !== 3'd2) bad = 1'b1;
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    if (err_code !== 3'd2 || done !== 1'b1) bad = 1'b1;

    // op 9: ERR_SHORT -- run with only two key words loaded
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    for (j = 0; j < 2; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    if (err_code !== 3'd4 || done !== 1'b1 || busy !== 1'b0) bad = 1'b1;
    if (key_cnt !== 4'd2 || blk_cnt !== 4'd0) bad = 1'b1;

    // op 10: ERR_SHORT again, this time requested while a word is still being
    // serialised: the run must be refused and the in-flight word must finish
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b0, 1'b1, 1'b0, kws[0]);
    for (b = 1; b < 12; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);             // mid word -> refused
    if (err_code !== 3'd4 || done !== 1'b1) bad = 1'b1;

    // op 11: ERR_LATE -- a block word requested while the engine runs, the
    // operation still has to finish with the correct ciphertext
    load_published();
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    for (b = 0; b < 40; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b0, 1'b0, 1'b1, 32'h0f0f0f0f);      // refused, ERR_LATE
    if (err_code !== 3'd5) bad = 1'b1;
    for (b = 0; b < ARMBE + LAPSZ*(RONDS + 1) - 40; b = b + 1)
        beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    if (done !== 1'b1 || busy !== 1'b0 || err_code !== 3'd5) bad = 1'b1;
    if (round_cnt !== 6'd32 || bit_pos !== 6'd0) bad = 1'b1;

    // op 12: ERR_LATE -- activity sampled on the same beat as start
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b1, 1'b0, kws[0]);
    if (err_code !== 3'd5) bad = 1'b1;
    if (key_cnt !== 4'd0)  bad = 1'b1;
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    if (err_code !== 3'd5 || done !== 1'b1) bad = 1'b1;

    // op 13: refused load beats must not disturb anything -- a key word asserted
    // in the middle of another word's serialisation window is simply ignored, and
    // the operation still closes with the published result
    load_published();
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b1, 1'b0, kws[j]);
        for (b = 1; b < LBW; b = b + 1) begin
            if (b == 5 || b == 6)
                beat(1'b0, 1'b0, 1'b1, 1'b1, 32'hffff0000);   // refused
            else
                beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
        end
    end
    for (j = 0; j < LOADW; j = j + 1) begin
        beat(1'b0, 1'b0, 1'b0, 1'b1, bws[j]);
        for (b = 1; b < LBW; b = b + 1)
            beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    end
    if (err_code !== 3'd0)  bad = 1'b1;               // refused, no error code
    if (key_cnt !== 4'd4)   bad = 1'b1;
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    for (b = 0; b < ARMBE + LAPSZ*(RONDS + 1); b = b + 1)
        beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    check_full_done();

    // op 14: reset in the middle of an operation, then a clean published run.
    // The folded beat right after reset carries the core's reset values.
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b1, 1'b0, 1'b0, 1'b0, 32'd0);
    beat(1'b0, 1'b0, 1'b1, 1'b0, kws[0]);
    for (b = 1; b < 20; b = b + 1) beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    reset_core();
    beat(1'b0, 1'b0, 1'b0, 1'b0, 32'd0);
    if (bit_pos !== 6'd0 || key_cnt !== 4'd0 || done !== 1'b0) bad = 1'b1;
    if (round_cnt !== 6'd0 || sched_cnt !== 6'd0) bad = 1'b1;
    load_published();
    full_op();
    check_full_done();

    // run_req once the core is done is ERR_LATE, and the result must hold
    beat(1'b0, 1'b1, 1'b0, 1'b0, 32'd0);
    if (err_code !== 3'd5) bad = 1'b1;

    if (ips_cycle < 32'd9000) bad = 1'b1;             // the beat budget is real
    term_ok = ~bad;
    ips_verdict(term_ok, "ips_speck128_block");
end

endmodule
