`timescale 1ns / 1ps
// tb_ips_scr_descrambler : production-line testbench for the 43-bit
// self-synchronising scrambler / descrambler pair.
//
// Configuration under test is the shipped default: taps at lag 1 and lag 43
// (characteristic polynomial x^43 + x^42 + 1) and a 43-bit line seeded with
// 43'h1A7F0C3D5E9.  The testbench never overrides a parameter, and every
// expected value comes from the link model written out here -- never from a
// number the DUT produced.
//
// Link model the checks are built from.  With c[n] the bit error on the channel
// and a[n] = y[n] ^ c[n] the bit the receiver actually hears,
//     r[n] = a[n] ^ a[n-1] ^ a[n-43]
// so the descrambler bit of this beat is wrong exactly when
// c[n] ^ c[n-1] ^ c[n-43] = 1, which is THREE output bit errors per injected
// channel bit error (one direct, two propagated = the tap weight).  The
// testbench keeps injhist[j] = c[n-j] and uses that sum as its expectation.
// A receiver that restarts with the transmitter's history apart from bit 0 is
// the same algebra with one virtual error one beat back, which is what makes
// its output wrong at relative beats 0 and 42 and clean from 43 on.
// The difference scr_state ^ desc_state is, likewise, exactly the error history
// of the last 43 received bits -- no state transfer, no side information.
//
// Sweep contract (models/ips_scr_descrambler.py reproduces exactly this
// schedule and folds 552 beats):
//   2 idle beats
//   NA = 64  beats with an all-zero payload, clean link  (zero -> pseudo-random)
//   NB = 48  beats with an all-ones payload, clean link
//   NC = 64  beats of LCG payload bits, clean link
//   NEV = 3  events of ND = 48 beats each with ONE channel bit error injected at
//            relative beat 3 (burst bound read at relative beat 47)
//   NE1 = 52 beats with errors injected at relative beats 3 AND 4 (adjacent pair)
//   NE2 = 70 beats with errors injected at relative beats 3 AND 23 (spread pair)
//   2 events of NF = 52 beats where the receiver restarts mid-stream at relative
//            beat 3 from the transmitter's history with bit 0 flipped
//            (resync position read at relative beat 50)
//   2 idle beats, a clk_en = 0 window that is checked but not folded,
//   2 more idle beats, seven accounting folds and the beat total.
//
// Folding rule, MSB byte first, eight 32-bit words per folded beat and in this
// order -- the golden model mirrors it word for word:
//   1  {21'd0, scr_state[42:32]}
//   2  scr_state[31:0]
//   3  {21'd0, desc_state[42:32]}
//   4  desc_state[31:0]
//   5  {11'd0, win, sync_pos, resync_pos}
//   6  {8'd0, chan_err, err_tot, scr_ones}
//   7  {16'd0, burst_max, prop_max, burst_tot, burst_prop}
//   8  {26'd0, err_sticky, desc_bit, scr_bit, done}
// Then once each: {24'd0, chan_err}, {24'd0, err_tot}, {24'd0, scr_ones},
// {28'd0, burst_max}, {28'd0, prop_max}, {25'd0, resync_pos},
// {29'd0, err_sticky} and the folded beat total.
//
// Every check uses === / !== so an X can never look like a pass (SOP trap T6).
module tb_ips_scr_descrambler;

`include "ips_tb_common.vh"

localparam integer LAG_A   = 1;
localparam integer LAG_B   = 43;
localparam integer N_IDL   = 2;
localparam integer NA      = 64;
localparam integer NB      = 48;
localparam integer NC      = 64;
localparam integer NEV     = 3;
localparam integer ND      = 48;
localparam integer NE1     = 52;
localparam integer NE2     = 70;
localparam integer NF      = 52;
localparam [31:0]  LCSEED  = 32'h5C071A7E;

reg                 rst_n;
reg                 clk_en;
reg                 start;
reg                 data_in;
reg                 chan_bad;
reg                 restart;
reg  [42:0]         seed_in;
reg                 inj_bit;

wire                scr_raw;
wire                desc_raw;
wire                done;
wire                scr_bit;
wire                desc_bit;
wire [42:0]         scr_state;
wire [42:0]         desc_state;
wire [7:0]          chan_err;
wire [7:0]          err_tot;
wire [7:0]          scr_ones;
wire [3:0]          burst_tot;
wire [3:0]          burst_prop;
wire [3:0]          burst_max;
wire [3:0]          prop_max;
wire [6:0]          win;
wire [6:0]          sync_pos;
wire [6:0]          resync_pos;
wire [2:0]          err_sticky;

// zero-latency link: the receiver hears exactly what the transmitter sends,
// XOR the channel bit error injected for this beat
wire                chan_drv = scr_raw ^ inj_bit;

ips_scr_descrambler dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .data_in    (data_in),
    .chan_in    (chan_drv),
    .chan_bad   (chan_bad),
    .restart    (restart),
    .seed_in    (seed_in),
    .scr_raw    (scr_raw),
    .desc_raw   (desc_raw),
    .done       (done),
    .scr_bit    (scr_bit),
    .desc_bit   (desc_bit),
    .scr_state  (scr_state),
    .desc_state (desc_state),
    .chan_err   (chan_err),
    .err_tot    (err_tot),
    .scr_ones   (scr_ones),
    .burst_tot  (burst_tot),
    .burst_prop (burst_prop),
    .burst_max  (burst_max),
    .prop_max   (prop_max),
    .win        (win),
    .sync_pos   (sync_pos),
    .resync_pos (resync_pos),
    .err_sticky (err_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// ------------------------------------------------------------------ link model
integer beats;
integer ab;              // started beats so far: the link timeline
integer rel_base;        // ab at the start of the phase under measurement
integer err_n;
integer err_list [0:31];
integer p;
integer e;
integer q;
integer a_ones;
integer b_ones;
integer rep;

reg  [43:0]         yhist;      // yhist[j] = scrambled bit j beats back
reg  [43:0]         injhist;    // injhist[j] = channel error j beats back
reg  [42:0]         sttab [0:127];
reg                 bad;
reg                 saved_d;
reg                 exp_err;
reg                 got_err;
reg                 pre_raw;

reg  [7:0]         f_chan_err;
reg  [7:0]         f_err_tot;
reg  [7:0]         f_scr_ones;
reg  [3:0]         f_bt;
reg  [3:0]         f_bp;
reg  [3:0]         f_bm;
reg  [3:0]         f_pm;
reg  [6:0]         f_win;
reg  [6:0]         f_sync;
reg  [6:0]         f_rsync;
reg  [2:0]         f_sticky;
reg                f_scr_bit;
reg                f_desc_bit;
reg                f_done;
reg  [42:0]        f_tx;
reg  [42:0]        f_rx;

reg  [31:0]        state;

task fold_beat;
    begin
        ips_fnv_word({21'd0, scr_state[42:32]});
        ips_fnv_word(scr_state[31:0]);
        ips_fnv_word({21'd0, desc_state[42:32]});
        ips_fnv_word(desc_state[31:0]);
        ips_fnv_word({11'd0, win, sync_pos, resync_pos});
        ips_fnv_word({8'd0, chan_err, err_tot, scr_ones});
        ips_fnv_word({16'd0, burst_max, prop_max, burst_tot, burst_prop});
        ips_fnv_word({26'd0, err_sticky, desc_bit, scr_bit, done});
        beats = beats + 1;
    end
endtask

task snapshot;
    begin
        f_chan_err = chan_err;
        f_err_tot  = err_tot;
        f_scr_ones = scr_ones;
        f_bt       = burst_tot;
        f_bp       = burst_prop;
        f_bm       = burst_max;
        f_pm       = prop_max;
        f_win      = win;
        f_sync     = sync_pos;
        f_rsync    = resync_pos;
        f_sticky   = err_sticky;
        f_scr_bit  = scr_bit;
        f_desc_bit = desc_bit;
        f_done     = done;
        f_tx       = scr_state;
        f_rx       = desc_state;
    end
endtask

task hold_checks;
    begin
        if (chan_err !== f_chan_err) bad = 1'b1;
        if (err_tot !== f_err_tot) bad = 1'b1;
        if (scr_ones !== f_scr_ones) bad = 1'b1;
        if (burst_tot !== f_bt) bad = 1'b1;
        if (burst_prop !== f_bp) bad = 1'b1;
        if (burst_max !== f_bm) bad = 1'b1;
        if (prop_max !== f_pm) bad = 1'b1;
        if (win !== f_win) bad = 1'b1;
        if (sync_pos !== f_sync) bad = 1'b1;
        if (resync_pos !== f_rsync) bad = 1'b1;
        if (err_sticky !== f_sticky) bad = 1'b1;
        if (scr_bit !== f_scr_bit) bad = 1'b1;
        if (desc_bit !== f_desc_bit) bad = 1'b1;
        if (scr_state !== f_tx) bad = 1'b1;
        if (desc_state !== f_rx) bad = 1'b1;
    end
endtask

task common_x;
    begin
        if ((^scr_state) === 1'bx || (^desc_state) === 1'bx) bad = 1'b1;
        if ((^chan_err) === 1'bx || (^err_tot) === 1'bx) bad = 1'b1;
        if ((^scr_ones) === 1'bx || (^burst_tot) === 1'bx) bad = 1'b1;
        if ((^burst_prop) === 1'bx || (^burst_max) === 1'bx) bad = 1'b1;
        if ((^prop_max) === 1'bx || (^win) === 1'bx) bad = 1'b1;
        if ((^sync_pos) === 1'bx || (^resync_pos) === 1'bx) bad = 1'b1;
        if ((^err_sticky) === 1'bx || scr_bit === 1'bx) bad = 1'b1;
        if ((^desc_bit) === 1'bx || (^done) === 1'bx) bad = 1'b1;
    end
endtask

// One bit beat of the link: drive it, take the registered result, check it
// against the link algebra, fold it.
task bit_beat;
    input        d;
    input        inj;
    input        rst;
    input [42:0] sd;
    begin
        @(negedge ips_clk);
        clk_en   = 1'b1;
        start    = 1'b1;
        data_in  = d;
        inj_bit  = inj;
        chan_bad = inj;
        restart  = rst;
        seed_in  = rst ? sd : 43'h0;
        injhist  = {injhist[42:0], 1'b0};   // age: slot k+1 = what slot k held
        injhist[0] = inj;
        if (rst) begin
            // a restarted line whose newest bit is wrong is one virtual error
            // that landed one beat ago
            injhist[1] = injhist[1] ^ 1'b1;
        end
        yhist   = {yhist[42:0], 1'b0};
        saved_d = d;
        ab      = ab + 1;
        exp_err = injhist[0] ^ injhist[LAG_A] ^ injhist[LAG_B];
        #1;
        pre_raw = desc_raw;

        @(negedge ips_clk);
        // Deassert the request the moment the result is sampled: the next beat is
        // driven at the following negedge, so without this the DUT would advance on
        // the clock edge in between and the two lines would shift by two.
        start    = 1'b0;
        inj_bit  = 1'b0;
        chan_bad = 1'b0;
        restart  = 1'b0;
        seed_in  = 43'h0;
        common_x();
        if (done !== 1'b1) bad = 1'b1;
        got_err = (desc_bit !== saved_d);
        if (got_err !== exp_err) bad = 1'b1;
        // the live combinational descrambler output is what got registered
        if (desc_bit !== pre_raw) bad = 1'b1;
        if (ab > LAG_B) begin
            // the channel stream really obeys y[n] = d[n] ^ y[n-1] ^ y[n-43]
            if (scr_bit !== (saved_d ^ yhist[1] ^ yhist[43])) bad = 1'b1;
        end
        yhist[0] = scr_bit;
        // The lines are read after this beat's edge, so line slot j holds the bit
        // j beats back: the transmitter its own outputs, the receiver what it heard.
        if (ab >= LAG_B) begin
            if (scr_state !== yhist[42:0]) bad = 1'b1;
            if (desc_state !== (yhist[42:0] ^ injhist[42:0])) bad = 1'b1;
        end
        // the two lines differ by exactly the error history of the last 43 bits
        if ((scr_state ^ desc_state) !== injhist[42:0]) bad = 1'b1;
        if (err_n < 32 && got_err) begin
            err_list[err_n] = ab - 1 - rel_base;
            err_n = err_n + 1;
        end
        fold_beat();
    end
endtask

task idle_beat;
    begin
        @(negedge ips_clk);
        snapshot();
        clk_en   = 1'b1;
        start    = 1'b0;
        inj_bit  = 1'b0;
        chan_bad = 1'b0;
        restart  = 1'b0;
        data_in  = 1'b0;
        seed_in  = 43'h0;
        @(negedge ips_clk);
        common_x();
        if (done !== 1'b0) bad = 1'b1;
        hold_checks();
        fold_beat();
    end
endtask

// Expected error-position set of the phase just swept, in increasing order.
integer ea;
integer eb;
integer ec;
integer ed;
integer ee;
integer ef;

function integer exp_at;
    input integer i;
    begin
        case (i)
            0:       exp_at = ea;
            1:       exp_at = eb;
            2:       exp_at = ec;
            3:       exp_at = ed;
            4:       exp_at = ee;
            default: exp_at = ef;
        endcase
    end
endfunction

// Structural check: the phase produced EXACTLY `want` descrambler bit errors and
// at exactly the expected positions.  The measured list is monotone by
// construction (it is appended in beat order), so size + membership + pairwise
// distinctness makes the two sets equal.
task check_errs;
    input integer want;
    integer i;
    integer j;
    integer hit;
    begin
        if (err_n !== want) bad = 1'b1;
        for (i = 0; i < err_n && i < 32; i = i + 1) begin
            hit = 0;
            for (j = 0; j < want; j = j + 1) begin
                if (exp_at(j) === err_list[i]) hit = 1;
            end
            if (!hit) bad = 1'b1;
            for (j = i + 1; j < err_n && j < 32; j = j + 1) begin
                if (err_list[i] === err_list[j]) bad = 1'b1;
            end
        end
        err_n = 0;
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    start     = 1'b0;
    data_in   = 1'b0;
    inj_bit   = 1'b0;
    chan_bad  = 1'b0;
    restart   = 1'b0;
    seed_in   = 43'h0;
    state     = LCSEED;
    bad       = 1'b0;
    beats     = 0;
    ab        = 0;
    rel_base  = 0;
    err_n     = 0;
    a_ones    = 0;
    b_ones    = 0;
    yhist     = 44'h0;
    injhist   = 44'h0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (p = 0; p < N_IDL; p = p + 1) begin
        idle_beat();
    end

    // ---- all-zero payload: the transmitter must still emit a pseudo-random run
    rel_base = ab;
    for (p = 0; p < NA; p = p + 1) begin
        bit_beat(1'b0, 1'b0, 1'b0, 43'h0);
        if (desc_bit !== 1'b0) bad = 1'b1;
        if (scr_bit === 1'b1) a_ones = a_ones + 1;
        rep = 0;
        for (q = 0; q < p; q = q + 1) begin
            if (sttab[q] === scr_state) rep = 1;
        end
        if (rep !== 0) bad = 1'b1;
        sttab[p] = scr_state;
        if (scr_state === 43'h0) bad = 1'b1;
    end
    if (a_ones === 0) bad = 1'b1;
    if (a_ones === NA) bad = 1'b1;
    check_errs(0);

    // ---- all-ones payload round trips too
    rel_base = ab;
    for (p = 0; p < NB; p = p + 1) begin
        bit_beat(1'b1, 1'b0, 1'b0, 43'h0);
        if (desc_bit !== 1'b1) bad = 1'b1;
        if (scr_bit === 1'b1) b_ones = b_ones + 1;
    end
    if (b_ones === 0) bad = 1'b1;
    if (b_ones === NB) bad = 1'b1;
    check_errs(0);

    // ---- random payload, clean link
    rel_base = ab;
    for (p = 0; p < NC; p = p + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        bit_beat(state[0], 1'b0, 1'b0, 43'h0);
    end
    check_errs(0);

    // ---- one injected channel bit: 3 output bits wrong, 2 of them propagated
    for (e = 0; e < NEV; e = e + 1) begin
        rel_base = ab;
        for (p = 0; p < ND; p = p + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            bit_beat(state[3], (p == 3) ? 1'b1 : 1'b0, 1'b0, 43'h0);
            if (p == ND - 1) begin
                if (burst_tot !== 4'd3) bad = 1'b1;
                if (burst_prop !== 4'd2) bad = 1'b1;
            end
        end
        ea = 3; eb = 4; ec = 46;
        check_errs(3);
        if (burst_max !== 4'd3) bad = 1'b1;
        if (prop_max !== 4'd2) bad = 1'b1;
    end

    // ---- two adjacent injected bits share a tap: 4 errors, not 6
    rel_base = ab;
    for (p = 0; p < NE1; p = p + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        bit_beat(state[5], (p == 3 || p == 4) ? 1'b1 : 1'b0, 1'b0, 43'h0);
    end
    ea = 3; eb = 5; ec = 46; ed = 47;
    check_errs(4);

    // ---- two injected bits 20 beats apart: exactly the bound, 6 errors
    rel_base = ab;
    for (p = 0; p < NE2; p = p + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        bit_beat(state[7], (p == 3 || p == 23) ? 1'b1 : 1'b0, 1'b0, 43'h0);
    end
    if (err_n !== 6) bad = 1'b1;
    if (err_list[0] !== 3) bad = 1'b1;
    if (err_list[1] !== 4) bad = 1'b1;
    if (err_list[2] !== 23) bad = 1'b1;
    if (err_list[3] !== 24) bad = 1'b1;
    if (err_list[4] !== 46) bad = 1'b1;
    if (err_list[5] !== 66) bad = 1'b1;
    err_n = 0;

    // ---- receiver joins mid-stream: flushes in exactly 43 channel bits
    for (e = 0; e < 2; e = e + 1) begin
        rel_base = ab;
        for (p = 0; p < NF; p = p + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            bit_beat(state[11], 1'b0, (p == 3) ? 1'b1 : 1'b0, scr_state ^ 43'h1);
            if (p == NF - 2) begin
                if (resync_pos !== 7'd42) bad = 1'b1;
            end
        end
        if (err_n !== 2) bad = 1'b1;
        if (err_list[0] !== 3) bad = 1'b1;
        if (err_list[1] !== 45) bad = 1'b1;
        err_n = 0;
    end

    for (p = 0; p < N_IDL; p = p + 1) begin
        idle_beat();
    end

    // ---- clock-enable window: nothing may move while clk_en is low
    @(negedge ips_clk);
    clk_en   = 1'b0;
    start    = 1'b1;
    data_in  = 1'b1;
    inj_bit  = 1'b1;
    chan_bad = 1'b1;
    restart  = 1'b1;
    seed_in  = ~scr_state;
    snapshot();
    repeat (3) @(negedge ips_clk);
    hold_checks();
    if (done !== f_done) bad = 1'b1;
    start    = 1'b0;
    inj_bit  = 1'b0;
    chan_bad = 1'b0;
    restart  = 1'b0;
    data_in  = 1'b0;
    seed_in  = 43'h0;
    clk_en   = 1'b1;

    idle_beat();
    idle_beat();

    if (err_sticky !== 3'b111) bad = 1'b1;
    if (beats < 200) bad = 1'b1;
    if (beats > 600) bad = 1'b1;

    ips_fnv_word({24'd0, chan_err});
    ips_fnv_word({24'd0, err_tot});
    ips_fnv_word({24'd0, scr_ones});
    ips_fnv_word({28'd0, burst_max});
    ips_fnv_word({28'd0, prop_max});
    ips_fnv_word({25'd0, resync_pos});
    ips_fnv_word({29'd0, err_sticky});
    ips_fnv_word(beats);

    ips_verdict(!bad, "ips_scr_descrambler");
end

endmodule
