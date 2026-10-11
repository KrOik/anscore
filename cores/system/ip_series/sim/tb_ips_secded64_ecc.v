`timescale 1ns / 1ps
// tb_ips_secded64_ecc : production-line testbench for the SECDED(72,64) core.
//
// Sweep contract (models/ips_secded64_ecc.py reproduces exactly this schedule):
//   NDW data words are pushed through the encoder, and for every word the decoder
//   sees the clean codeword, then all NPOS = 72 single-bit channel flips one at a
//   time, then NDBL deterministic double-bit flips, then one idle (start = 0) beat.
//   NDW words are, in order, the all-zero payload, the all-ones payload and two
//   LCG payloads, so the degenerate codewords are covered.  A mixed encode / decode
//   stream closes the run, followed by a clk_en = 0 window that is checked but not
//   folded, and four final accounting words.
//
// Folding rule, MSB byte first, seven 32-bit words per folded beat and in this
// order -- this is the rule the golden model mirrors word for word:
//   1  {22'd0, err_pos, ce, ue, done}
//   2  {24'd0, syndrome}
//   3  {26'd0, syn_wt, err_sticky}
//   4  {24'd0, ce_cnt, ue_cnt}
//   5  code_out[31:0]
//   6  code_out[63:32]
//   7  {8'd0, chk_out}
// After the last beat, once each: {24'd0, ce_cnt}, {24'd0, ue_cnt},
// {28'd0, err_sticky} and the folded beat total.
//
// Every check uses === / !== so an X can never look like a pass (SOP trap T6).
// The expected codeword positions, H columns and syndrome weights come from the
// coding theory written out below (powers-of-two check positions, odd-weight
// column basis), not from the DUT, and the run additionally proves pairwise
// distinctness, non-zero and odd weight of all 72 observed columns, which is the
// classic degenerate-H-matrix pitfall: two equal columns, or a data column that
// duplicates a check column, silently converts a double error into a wrong
// "correction".
module tb_ips_secded64_ecc;

`include "ips_tb_common.vh"

localparam integer NDW     = 4;
localparam integer NPOS    = 72;
localparam integer NDBL    = 8;
localparam integer NMIX    = 12;
localparam [31:0]  SEED    = 32'h5EED1234;

reg                 rst_n;
reg                 clk_en;
reg                 start;
reg                 mode;
reg  [71:0]         code_in;

wire                done;
wire                ce;
wire                ue;
wire [63:0]         data_out;
wire [7:0]          chk_out;
wire [71:0]         code_out;
wire [7:0]          syndrome;
wire [3:0]          syn_wt;
wire [6:0]          err_pos;
wire [3:0]          ce_cnt;
wire [3:0]          ue_cnt;
wire [1:0]          err_sticky;

ips_secded64_ecc dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (start),
    .mode       (mode),
    .code_in    (code_in),
    .done       (done),
    .ce         (ce),
    .ue         (ue),
    .data_out   (data_out),
    .chk_out    (chk_out),
    .code_out   (code_out),
    .syndrome   (syndrome),
    .syn_wt     (syn_wt),
    .err_pos    (err_pos),
    .ce_cnt     (ce_cnt),
    .ue_cnt     (ue_cnt),
    .err_sticky (err_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// ---------------------------------------------------------------- coding theory
function is_pow2;
    input [6:0] v;
    begin
        is_pow2 = (v != 7'd0) && ((v & (v - 7'd1)) == 7'd0);
    end
endfunction

// Data bit i lives at the (i+1)-th number in 1..71 that is not a power of two.
function [6:0] data_pos;
    input integer i;
    integer q;
    integer n;
    integer f;
    begin
        n = 0;
        f = 0;
        for (q = 1; q <= 71; q = q + 1) begin
            if (!is_pow2(q[6:0])) begin
                n = n + 1;
                if (n == (i + 1) && f == 0) begin
                    f = q;
                end
            end
        end
        data_pos = f[6:0];
    end
endfunction

// Odd-weight basis column of logical codeword position q (q = 0 is the parity slot).
function [7:0] hcol;
    input [6:0] q;
    begin
        hcol = {(1'b1 ^ (^q)), q};
    end
endfunction

// The H column a single flip at flat codeword index k must produce.
function [6:0] inj_pos;
    input integer k;
    begin
        if (k < 64) begin
            inj_pos = data_pos(k);
        end else if (k < 71) begin
            inj_pos = (7'd1 << (k - 64));
        end else begin
            inj_pos = 7'd0;
        end
    end
endfunction

function [7:0] inj_col;
    input integer k;
    begin
        inj_col = hcol(inj_pos(k));
    end
endfunction

function [3:0] popcnt;
    input [7:0] v;
    integer t;
    reg   [3:0] a;
    begin
        a = 4'd0;
        for (t = 0; t < 8; t = t + 1) begin
            if (v[t]) begin
                a = a + 4'd1;
            end
        end
        popcnt = a;
    end
endfunction

// -------------------------------------------------------------------- bookkeeping
integer dw;
integer k;
integer d;
integer t;
integer q;
integer n;
integer beats;
integer f;
reg  [63:0]         word;
reg  [71:0]         clean_cw;
reg  [71:0]         inj;
reg  [71:0]         bit1;
reg  [71:0]         bit2;
reg  [7:0]          exp_syn;
reg  [6:0]          exp_pos;
reg  [71:0]         exp_code;
reg                 exp_ce;
reg                 exp_ue;
reg                 pos_free;
reg                 bad;
reg                 save_ce;
reg                 save_ue;
reg                 save_done;
reg  [7:0]          save_syn;
reg  [3:0]          save_cec;
reg  [3:0]          save_uec;
reg  [1:0]          save_stk;
reg  [71:0]         save_code;
reg  [7:0]          syn_tab [0:71];
reg  [1:0]          stk_prev;
reg  [31:0]         state;

task fold_beat;
    begin
        ips_fnv_word({22'd0, err_pos, ce, ue, done});
        ips_fnv_word({24'd0, syndrome});
        ips_fnv_word({26'd0, syn_wt, err_sticky});
        ips_fnv_word({24'd0, ce_cnt, ue_cnt});
        ips_fnv_word(code_out[31:0]);
        ips_fnv_word(code_out[63:32]);
        ips_fnv_word({8'd0, chk_out});
        beats = beats + 1;
    end
endtask

task common_checks;
    begin
        if (ce === 1'b1 && ue === 1'b1) bad = 1'b1;
        if ((^code_out) === 1'bx || (^syndrome) === 1'bx) bad = 1'b1;
        if ((^err_pos) === 1'bx || (^chk_out) === 1'bx) bad = 1'b1;
        if ((^data_out) === 1'bx || (^syn_wt) === 1'bx) bad = 1'b1;
        if ((^ce_cnt) === 1'bx || (^ue_cnt) === 1'bx) bad = 1'b1;
        if ((^err_sticky) === 1'bx) bad = 1'b1;
        // accounting may never clear and never wrap
        if (((stk_prev & ~err_sticky) !== 2'b00)) bad = 1'b1;
        if (ce_cnt < save_cec) bad = 1'b1;
        if (ue_cnt < save_uec) bad = 1'b1;
        stk_prev = err_sticky;
        save_cec = ce_cnt;
        save_uec = ue_cnt;
    end
endtask

// One started operation: present the word, take the registered result, check it
// against the expectation the coding theory produced, fold it.
task op_beat;
    input        md;
    input [71:0] cw;
    input        e_ce;
    input        e_ue;
    input [7:0]  e_syn;
    input [6:0]  e_pos;
    input        e_pos_free;
    input [71:0] e_code;
    begin
        @(negedge ips_clk);
        clk_en   = 1'b1;
        start    = 1'b1;
        mode     = md;
        code_in  = cw;
        @(negedge ips_clk);
        start    = 1'b0;
        mode     = 1'b0;
        code_in  = 72'h0;
        common_checks();
        if (done !== 1'b1) bad = 1'b1;
        if (ce !== e_ce) bad = 1'b1;
        if (ue !== e_ue) bad = 1'b1;
        if (syndrome !== e_syn) bad = 1'b1;
        if (syn_wt !== popcnt(e_syn)) bad = 1'b1;
        if (e_pos_free) begin
            if (ce === 1'b1 && err_pos === 7'd0) bad = 1'b1;
        end else begin
            if (err_pos !== e_pos) bad = 1'b1;
        end
        if (ce === 1'b0 && err_pos !== 7'd0) bad = 1'b1;
        if (code_out !== e_code) bad = 1'b1;
        if (chk_out !== e_code[71:64]) bad = 1'b1;
        if (data_out !== e_code[63:0]) bad = 1'b1;
        fold_beat();
    end
endtask

// One encode beat: the payload travels in the data field, and the emitted word is
// checked against the parity equation and against the data field only, never
// against a hard-coded check field.
task enc_beat;
    input [63:0] dword;
    begin
        @(negedge ips_clk);
        clk_en   = 1'b1;
        start    = 1'b1;
        mode     = 1'b0;
        code_in  = {8'h00, dword};
        @(negedge ips_clk);
        start    = 1'b0;
        code_in  = 72'h0;
        common_checks();
        if (ce !== 1'b0) bad = 1'b1;
        if (ue !== 1'b0) bad = 1'b1;
        if (done !== 1'b1) bad = 1'b1;
        if (syndrome !== 8'h00) bad = 1'b1;
        if (syn_wt !== 4'h0) bad = 1'b1;
        if (err_pos !== 7'd0) bad = 1'b1;
        if (data_out !== dword) bad = 1'b1;
        if (code_out[63:0] !== dword) bad = 1'b1;
        if (chk_out !== code_out[71:64]) bad = 1'b1;
        // the overall parity extension: every codeword leaves with even parity
        if ((^code_out) !== 1'b0) bad = 1'b1;
        fold_beat();
    end
endtask

task hold_beat;
    begin
        @(negedge ips_clk);
        clk_en  = 1'b1;
        start   = 1'b0;
        mode    = 1'b0;
        code_in = 72'h0;
        @(negedge ips_clk);
        common_checks();
        if (done !== 1'b0) bad = 1'b1;
        fold_beat();
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    start     = 1'b0;
    mode      = 1'b0;
    code_in   = 72'h0;
    state     = SEED;
    bad       = 1'b0;
    beats     = 0;
    save_cec  = 4'h0;
    save_uec  = 4'h0;
    stk_prev  = 2'b00;
    clean_cw  = 72'h0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (dw = 0; dw < NDW; dw = dw + 1) begin
        if (dw == 0) begin
            word = 64'h0;
        end else if (dw == 1) begin
            word = 64'hFFFFFFFFFFFFFFFF;
        end else begin
            state = state * 32'd1664525 + 32'd1013904223;
            f     = state;
            state = state * 32'd1664525 + 32'd1013904223;
            word  = {f[31:0], state[31:0]};
        end

        enc_beat(word);
        clean_cw = code_out;

        // the clean codeword must decode with no syndrome and no correction
        op_beat(1'b1, clean_cw, 1'b0, 1'b0, 8'h00, 7'd0, 1'b0, clean_cw);

        for (k = 0; k < NPOS; k = k + 1) begin
            bit1    = 72'd1 << k;
            inj     = clean_cw ^ bit1;
            exp_syn = inj_col(k);
            exp_pos = inj_pos(k);
            // the parity slot reports the core's own PAR_POS, so only its
            // non-emptiness is pinned there
            pos_free = (k == 71) ? 1'b1 : 1'b0;
            op_beat(1'b1, inj, 1'b1, 1'b0, exp_syn, exp_pos, pos_free, clean_cw);
            if (dw == 0) begin
                syn_tab[k] = syndrome;
            end
        end

        for (d = 0; d < NDBL; d = d + 1) begin
            state  = state * 32'd1664525 + 32'd1013904223;
            k      = state % NPOS;
            q      = (k + 1 + ((state >> 8) % (NPOS - 1))) % NPOS;
            bit1   = 72'd1 << k;
            bit2   = 72'd1 << q;
            inj    = clean_cw ^ bit1 ^ bit2;
            exp_syn = inj_col(k) ^ inj_col(q);
            // uncorrectable: the received word must come back untouched
            op_beat(1'b1, inj, 1'b0, 1'b1, exp_syn, 7'd0, 1'b0, inj);
        end

        hold_beat();

        if (dw == 0) begin
            // column audit: 72 distinct, non-zero, odd-weight columns
            for (t = 0; t < NPOS; t = t + 1) begin
                if (syn_tab[t] === 8'h00) bad = 1'b1;
                if ((^syn_tab[t]) !== 1'b1) bad = 1'b1;
                for (n = t + 1; n < NPOS; n = n + 1) begin
                    if (syn_tab[t] === syn_tab[n]) bad = 1'b1;
                end
            end
        end
    end

    // mixed stream: random payload, encode then decode it back clean and once with
    // a single flip, so encoder and decoder are exercised on alternating beats
    for (dw = 0; dw < NMIX; dw = dw + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        word  = {state[31:0], ~state[31:0]};
        enc_beat(word);
        clean_cw = code_out;
        if (dw == 3) begin
            bit1 = 72'd1 << 40;
            op_beat(1'b1, clean_cw ^ bit1, 1'b1, 1'b0, inj_col(40),
                    data_pos(40), 1'b0, clean_cw);
        end else begin
            op_beat(1'b1, clean_cw, 1'b0, 1'b0, 8'h00, 7'd0, 1'b0, clean_cw);
        end
    end

    // clock-enable window: with clk_en low no register may move at all
    @(negedge ips_clk);
    clk_en    = 1'b0;
    start     = 1'b1;
    mode      = 1'b1;
    code_in   = clean_cw ^ (72'd1 << 5);
    save_code = code_out;
    save_syn  = syndrome;
    save_ce   = ce;
    save_ue   = ue;
    save_done = done;
    save_stk  = err_sticky;
    repeat (3) @(negedge ips_clk);
    if (code_out !== save_code) bad = 1'b1;
    if (syndrome !== save_syn) bad = 1'b1;
    if (ce !== save_ce) bad = 1'b1;
    if (ue !== save_ue) bad = 1'b1;
    if (done !== save_done) bad = 1'b1;
    if (err_sticky !== save_stk) bad = 1'b1;
    if (ce_cnt !== save_cec) bad = 1'b1;
    if (ue_cnt !== save_uec) bad = 1'b1;
    start   = 1'b0;
    mode    = 1'b0;
    code_in = 72'h0;
    clk_en  = 1'b1;

    hold_beat();
    hold_beat();

    if (err_sticky !== 2'b11) bad = 1'b1;
    if (beats < 200) bad = 1'b1;

    ips_fnv_word({24'd0, ce_cnt});
    ips_fnv_word({24'd0, ue_cnt});
    ips_fnv_word({28'd0, err_sticky});
    ips_fnv_word(beats);

    ips_verdict(!bad, "ips_secded64_ecc");
end

endmodule
