`timescale 1ns / 1ps
// tb_ips_baud_detect_uart : production-line testbench for the UART baud estimator.
//
// Quantum/timing base, stimulus plan, fold rule (the same contract is stated at
// the top of models/ips_baud_detect_uart.py; both are written from the core's
// written contract and never from simulation output -- docs/IP_CORE_SOP.md T1):
//
// Beats.  One beat is one input quantum: the estimator sees a tick, samples rx and
// measures low runs in quanta.  Gap beats (tick held low, GAPN of them) and stall
// beats (clk_en held low, STN of them) are appended *inside* a low run at fixed
// quantum indices GQ/SQ; they are not quanta, so the run still closes with exactly
// the length the plan drove, while the fold proves the engine froze.
//
// Waveform.  RUNQ(L, sp) pulls rx low for L quanta and releases it for sp quanta.
// A sequence RSEQ(L, n, sp) repeats it n times, which is what a burst of 0 bits of
// a UART stream at bit length L looks like to a run-length estimator: every low run
// is one bit and the released part is never measured.  The plan sits on every
// decision boundary of the shipped default geometry:
//   L = 16 exact rate        -> seeds, agrees, LOCKS on the 3rd run (LOCK_N = 3)
//   L = 18 slightly off      -> |18-16| = 2 <= TOL, stays locked and tracks
//   L = 14 rate jump         -> |14-18| = 4 = TOL+1, unlocks and re-seeds
//   L = 12 = RUN_MIN         -> accepted, keeps the lock (mutant RUN_MIN rejects)
//   L = 11 = RUN_MIN-1       -> out of range, error flag, no lock
//   L = 20 = RUN_MAX         -> accepted, re-locks
//   L = 21 = RUN_MAX+1       -> out of range
//   L = 6  far too fast      -> error flag instead of a lock
//   L = 26 far too slow      -> error flag instead of a lock
//   L = 1,2 < GLITCH         -> line noise, discarded, glitch flag
//   L = 64 long break        -> the run counter saturates at LEN_MAX
// restart is pulsed while locked (second unlock path), and three LCG-driven
// sequences sweep the accepted range so the lock/hold/unlock trajectory depends on
// every timing constant.
//
// Fold rule, identical in the model: every beat folds three words, in this order,
// using the values observed after that beat's enabled clock edge:
//   w1 = {4'd0,  state, rx_q, locked, len, tick_est, meas}
//   w2 = {3'd0,  agree, run_count, run_valid, lock_valid, glitch_sticky,
//         range_sticky, min_len, max_len}
//   w3 = {8'd0,  bit_len, lock_count, unlock_count, hold_count, err_count}
// After the plan, nbeats and one summary word {17'd0, lcg[2:0], lock_count,
// unlock_count, err_count} are folded.
//
// Observed only with === / !== so an unknown can never look like a pass (trap T6).
module tb_ips_baud_detect_uart;

`include "ips_tb_common.vh"

localparam integer MAXB = 2048;
localparam integer GAPN = 3;          // gap beats injected at quantum GQ
localparam integer STN  = 4;          // stall beats injected at quantum SQ
localparam integer GQ   = 5;
localparam integer SQ   = 9;

reg        rst_n;
reg        clk_en;
reg        tick;
reg        rx;
reg        restart;
reg [31:0] lcg;

wire       locked;
wire [1:0] st_q;
wire [7:0] len;
wire [7:0] meas;
wire [7:0] bit_len;
wire [7:0] min_len;
wire [7:0] max_len;
wire [7:0] tick_est;
wire [2:0] agree;
wire [5:0] run_count;
wire [3:0] lock_count;
wire [3:0] unlock_count;
wire [3:0] hold_count;
wire [3:0] err_count;
wire       rx_q;
wire       run_valid;
wire       lock_valid;
wire       glitch_sticky;
wire       range_sticky;

reg       rx_b   [0:MAXB - 1];
reg       tick_b [0:MAXB - 1];
reg       en_b   [0:MAXB - 1];
reg       rst_b  [0:MAXB - 1];
integer   chk_b  [0:7];
reg [7:0] chk_v  [0:7];
reg       chk_h  [0:7];

reg       cur_rx;
reg       cur_tick;
reg       cur_en;
reg       cur_rst;

integer   nb;
integer   nbeats;
integer   nchk;
integer   nrun;
integer   last_pb;
integer   i;
integer   k;
integer   c;
reg [31:0] w1;
reg [31:0] w2;
reg [31:0] w3;
reg [31:0] pw1;
reg        bad;
reg        dump;
reg        lock_seen;

// No #() override here: the testbench exercises the shipped default geometry,
// which is the configuration the manifest records.
ips_baud_detect_uart dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .tick        (tick),
    .rx          (rx),
    .restart     (restart),
    .locked      (locked),
    .state       (st_q),
    .len         (len),
    .meas        (meas),
    .bit_len     (bit_len),
    .min_len     (min_len),
    .max_len     (max_len),
    .tick_est    (tick_est),
    .agree       (agree),
    .run_count   (run_count),
    .lock_count  (lock_count),
    .unlock_count(unlock_count),
    .hold_count  (hold_count),
    .err_count   (err_count),
    .rx_q        (rx_q),
    .run_valid   (run_valid),
    .lock_valid  (lock_valid),
    .glitch_sticky(glitch_sticky),
    .range_sticky(range_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

task PB;
    begin
        rx_b[nb]   = cur_rx;
        tick_b[nb] = cur_tick;
        en_b[nb]   = cur_en;
        rst_b[nb]  = cur_rst;
        last_pb    = nb;
        nb         = nb + 1;
    end
endtask

task CHK;
    input integer exp;
    begin
        if (nchk < 8) begin
            chk_b[nchk] = last_pb;
            chk_v[nchk] = exp[7:0];
            chk_h[nchk] = 1'b0;
            nchk        = nchk + 1;
        end
    end
endtask

task IDLEB;
    input integer n;
    integer     p;
    begin
        for (p = 0; p < n; p = p + 1) begin
            cur_rx   = 1'b1;
            cur_tick = 1'b1;
            cur_en   = 1'b1;
            cur_rst  = 1'b0;
            PB;
        end
    end
endtask

// One low run of L quanta, released for sp quanta afterwards.  gq/sq are the
// quantum indices that carry the gap/stall injection, -1 disables them; exp > 0
// marks the beat the run closes on and the length it must have measured.
task RUNQ;
    input integer L;
    input integer sp;
    input integer gq;
    input integer sq;
    input integer exp;
    integer     p;
    begin
        for (p = 0; p < L; p = p + 1) begin
            cur_rx   = 1'b0;
            cur_tick = 1'b1;
            cur_en   = 1'b1;
            cur_rst  = 1'b0;
            PB;
            if ((gq >= 0) && (p == gq)) begin
                cur_tick = 1'b0;
                repeat (GAPN) begin
                    PB;
                end
                cur_tick = 1'b1;
            end
            if ((sq >= 0) && (p == sq)) begin
                cur_en = 1'b0;
                repeat (STN) begin
                    PB;
                end
                cur_en = 1'b1;
            end
        end
        for (p = 0; p < sp; p = p + 1) begin
            cur_rx   = 1'b1;
            cur_tick = 1'b1;
            cur_en   = 1'b1;
            cur_rst  = 1'b0;
            PB;
            if ((exp > 0) && (p == 0)) begin
                CHK(exp);
            end
        end
    end
endtask

task RSEQ;
    input integer L;
    input integer n;
    input integer sp;
    input       gapi;
    input       stli;
    input integer exp;
    integer     j;
    begin
        for (j = 0; j < n; j = j + 1) begin
            RUNQ(L, sp, ((gapi == 1) && (j == 0)) ? GQ : -1,
                 ((stli == 1) && (j == 0)) ? SQ : -1,
                 ((exp > 0) && (j == 0)) ? exp : 0);
        end
    end
endtask

task RSTR;
    input integer n;
    integer     p;
    begin
        for (p = 0; p < n; p = p + 1) begin
            cur_rx   = 1'b1;
            cur_tick = 1'b1;
            cur_en   = 1'b1;
            cur_rst  = 1'b1;
            PB;
        end
        cur_rst = 1'b0;
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    tick     = 1'b0;
    rx       = 1'b1;
    restart  = 1'b0;
    lcg      = 32'hB16B1351;
    bad      = 1'b0;
    dump     = $test$plusargs("DUMP");
    nb       = 0;
    nchk     = 0;
    nrun     = 0;
    lock_seen= 1'b0;

    // ---- plan ---------------------------------------------------------------
    IDLEB(6);
    RSEQ(16, 3, 3, 1, 0, 16);          // exact rate -> lock
    RSEQ(18, 2, 3, 0, 1, 18);          // slightly off -> tolerated while locked
    RUNQ(14, 3, -1, -1, 14);           // rate jump of TOL+1 -> unlock, re-seed
    RSEQ(14, 2, 1, 0, 0, 0);           // -> lock again
    RSEQ(12, 2, 3, 0, 0, 12);          // RUN_MIN boundary, accepted
    RSTR(2);                           // restart while locked -> counted unlock
    RSEQ(11, 2, 3, 0, 0, 0);           // RUN_MIN-1 -> out of range
    RSEQ(20, 3, 3, 1, 0, 20);          // RUN_MAX boundary -> lock
    RSEQ(21, 2, 3, 0, 1, 0);           // RUN_MAX+1 -> out of range
    RSEQ(6, 3, 3, 0, 0, 6);            // far too fast -> error, never locks
    RSEQ(26, 2, 3, 0, 0, 0);           // far too slow  -> error, never locks
    RUNQ(1, 3, -1, -1, 0);             // line noise
    RUNQ(2, 3, -1, -1, 0);             // line noise
    RUNQ(64, 4, -1, -1, 0);            // long break -> saturating measurement

    for (c = 0; c < 3; c = c + 1) begin
        lcg = lcg * 32'd1664525 + 32'd1013904223;
        RSEQ(12 + (lcg % 32'd9), 2 + ((lcg >> 7) % 32'd3), 2, (c == 1), (c == 2), 0);
        lcg = lcg * 32'd1664525 + 32'd1013904223;
    end
    IDLEB(4);

    nbeats = nb;

    // ---- run ----------------------------------------------------------------
    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    if (nbeats < 200 || nbeats >= MAXB || nchk < 3) bad = 1'b1;

    for (i = 0; i < nbeats; i = i + 1) begin
        @(negedge ips_clk);
        tick    = tick_b[i];
        clk_en  = en_b[i];
        rx      = rx_b[i];
        restart = rst_b[i];

        @(negedge ips_clk);
        clk_en  = 1'b0;
        restart = 1'b0;

        w1 = {4'd0, st_q, rx_q, locked, len, tick_est, meas};
        w2 = {3'd0, agree, run_count, run_valid, lock_valid, glitch_sticky,
              range_sticky, min_len, max_len};
        w3 = {8'd0, bit_len, lock_count, unlock_count, hold_count, err_count};

        if ((^st_q === 1'bx) || (^len === 1'bx) || (^meas === 1'bx))             bad = 1'b1;
        if ((^bit_len === 1'bx) || (^min_len === 1'bx) || (^max_len === 1'bx))    bad = 1'b1;
        if ((^tick_est === 1'bx) || (^agree === 1'bx) || (^run_count === 1'bx))   bad = 1'b1;
        if ((^lock_count === 1'bx) || (^unlock_count === 1'bx))                   bad = 1'b1;
        if ((^hold_count === 1'bx) || (^err_count === 1'bx))                      bad = 1'b1;
        if ((locked === 1'bx) || (rx_q === 1'bx) || (run_valid === 1'bx))         bad = 1'b1;
        if ((lock_valid === 1'bx) || (glitch_sticky === 1'bx) ||
            (range_sticky === 1'bx))                                              bad = 1'b1;
        // structural invariants of the written contract
        if ((run_valid === 1'b1) && (len !== 8'd0))                               bad = 1'b1;
        if ((lock_valid === 1'b1) && (locked !== 1'b1))                            bad = 1'b1;
        if ((st_q === 2'd0) && (len !== 8'd0))                                     bad = 1'b1;
        if ((locked === 1'b1) && (agree !== 3'd0))                                 bad = 1'b1;
        if ((range_sticky === 1'b0) && (err_count !== 4'h0))                       bad = 1'b1;
        if ((lock_count === 4'h0) && (unlock_count !== 4'h0))                      bad = 1'b1;
        if ((i > 0) && ((en_b[i] === 1'b0) || (tick_b[i] === 1'b0)) && (w1 !== pw1)) bad = 1'b1;
        // the marked runs must have measured exactly the length the plan drove
        for (k = 0; k < nchk; k = k + 1) begin
            if ((i === chk_b[k]) && ((run_valid !== 1'b1) || (meas !== chk_v[k]))) bad = 1'b1;
            if (i === chk_b[k]) chk_h[k] = 1'b1;
        end
        if (run_valid === 1'b1) nrun = nrun + 1;
        if (locked === 1'b1)    lock_seen = 1'b1;

        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        pw1 = w1;
        if (dump && ((i % 64) == 63)) $display("DBG %0d %h %h %h", i, w1, w2, w3);
    end

    // every path the core is sold for has to have been exercised
    if (!lock_seen)                                                               bad = 1'b1;
    if ((lock_count === 4'h0) || (unlock_count === 4'h0) || (hold_count === 4'h0)) bad = 1'b1;
    if ((range_sticky !== 1'b1) || (glitch_sticky !== 1'b1) ||
        (err_count === 4'h0))                                                     bad = 1'b1;
    if ((run_count === 6'd0) || (nrun < 20))                                      bad = 1'b1;
    if ((min_len === 8'hFF) || (max_len === 8'h00) || (tick_est === 8'h00))        bad = 1'b1;
    for (k = 0; k < nchk; k = k + 1) begin
        if (!chk_h[k])                                                            bad = 1'b1;
    end

    ips_fnv_word(nbeats);
    ips_fnv_word({17'd0, lcg[2:0], lock_count, unlock_count, err_count});
    ips_verdict(!bad, "ips_baud_detect_uart");
end

endmodule
