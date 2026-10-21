`timescale 1ns / 1ps
// tb_ips_micro_sequencer16 : production-line testbench for the 16-entry program
// sequencer.
//
// Folding rule (mirrored by models/ips_micro_sequencer16.py): one enabled rising
// edge is one beat; on every beat exactly these four 32-bit words are folded with
// ips_fnv_word, in this order and with these alignments:
//   W0 = {18'd0, wait_cnt, pc, cur_op, out_word}
//   W1 = {24'd0, step_count}
//   W2 = {19'd0, tmo_flag, run, halted, state, err_cause, err_seen}
//   W3 = {24'd0, tmo_total}
// then the run closes with {24'd0, step_count}, {24'd0, tmo_total},
// {20'd0, pc, cur_op, out_word}, {19'd0, tmo_flag, run, halted, state, err_cause,
// err_seen}, the number of beats attempted and the number of those beats that were
// enabled (clk_en high).  Disabled beats step neither the DUT nor ips_cycle and fold
// nothing.
//
// The expectation is NOT written here: models/ips_micro_sequencer16.py replays the
// sequencer contract independently and the gate compares the two digests
// (docs/IP_CORE_SOP.md trap T1).  Every check uses === so an X can never read as a
// pass (trap T6).  The script is deterministic; in_word is either scripted or drawn
// from the shared LCG.  PGM_LEN is 12, so entries 0..11 are the running program and
// entries 12..15 are stored but out of range.  Each terminal cause is triggered at its
// OWN station, which is what makes the cause codes observable one by one:
//   load    all sixteen entries through the update port (two gated beats first)
//   run A   every opcode once; a bounded loop with both JZ legs; BRA skipping a
//           decoy; three WAITs that never match -> three timeouts and deterministic
//           one-instruction resumes; ends on a TAKEN branch past entry 11 -> ERR_TGT
//   run B   the WAITs re-programmed to NOP and the branch to HALT -> a clean stop with
//           no new timeout (tmo_total must not move)
//   run C   the branch re-programmed to INC -> the program runs off its end; entry 12
//           also holds an undefined opcode, so this station proves ERR_RUN outranks
//           ERR_OPC
//   run D   an undefined opcode INSIDE the program (entry 5) -> ERR_OPC
//   run E   the run-A program again with in_word from the LCG: stall lengths vary beat
//           by beat and the same ERR_TGT station repeats (a repeat cause sets no new
//           err_seen bit but must still be terminal)
//   run F   an outer loop re-entered by a branch (JNZ taken -> entry 4) that is
//           re-programmed WHILE RUNNING to HALT: proves the update port owns its beat
//           and that a live run picks up the new word
//   tail    idle beats, a held arm pulse on a gated beat (must not start a run) and
//           beats with the clock enabled and then gated again
module tb_ips_micro_sequencer16;

`include "ips_tb_common.vh"

localparam [31:0]  SEED      = 32'h16A05EED;
localparam integer ITER_MAX  = 600;
localparam integer ITER_MIN  = 200;

// TB-side encodings, written from the instruction table in the core's header.  They
// are deliberately not taken from the DUT, so they check the core instead of echoing it.
localparam [1:0]  ST_IDLE  = 2'd0;
localparam [1:0]  ST_RUN   = 2'd1;
localparam [1:0]  ST_HALT  = 2'd2;
localparam [1:0]  ST_ERR   = 2'd3;
localparam [3:0]  OP_NOP   = 4'h0;
localparam [3:0]  OP_SET   = 4'h1;
localparam [3:0]  OP_CLR   = 4'h2;
localparam [3:0]  OP_INC   = 4'h3;
localparam [3:0]  OP_JZ    = 4'h4;
localparam [3:0]  OP_JNZ   = 4'h5;
localparam [3:0]  OP_BRA   = 4'h6;
localparam [3:0]  OP_WAIT  = 4'h7;
localparam [3:0]  OP_HALT  = 4'h8;
localparam [1:0]  ACT_IDLE = 2'd0;
localparam [1:0]  ACT_LOAD = 2'd1;
localparam [1:0]  ACT_ARM  = 2'd2;
localparam [1:0]  ACT_RUN  = 2'd3;
localparam [15:0] OPS_ALL  = 16'h01FF;   // every opcode in the table retired once
localparam [2:0]  EC_NONE  = 3'd0;       // cause codes, from the core's table
localparam [2:0]  EC_TGT   = 3'd1;
localparam [2:0]  EC_OPC   = 3'd2;
localparam [2:0]  EC_RUN   = 3'd3;
localparam [3:0]  OP_UNDEF = 4'hC;       // an opcode outside the instruction table

reg               rst_n;
reg               clk_en;
reg               en_b;
reg               ld_e;
reg        [3:0]  ld_i;
reg        [11:0] ld_d;
reg               arm_b;
reg        [3:0]  iw;
reg        [1:0]  act;
reg        [1:0]  iw_mode;      // 0 = scripted iw_scr, 1 = take in_word from the LCG
reg        [3:0]  iw_scr;
reg        [31:0] state;

wire [3:0]        pc;
wire [3:0]        cur_op;
wire              run;
wire              halted;
wire [1:0]        state_q;
wire [3:0]        out_word;
wire [7:0]        step_count;
wire [5:0]        wait_cnt;
wire [7:0]        tmo_total;
wire              tmo_flag;
wire [2:0]        err_cause;
wire [4:0]        err_seen;

// No #() override: the core's declared defaults are the shipped configuration, and
// overriding them here would hide the defaults from the mutation station.
ips_micro_sequencer16 dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .ld_en      (ld_e),
    .ld_idx     (ld_i),
    .ld_data    (ld_d),
    .arm        (arm_b),
    .in_word    (iw),
    .pc         (pc),
    .cur_op     (cur_op),
    .run        (run),
    .halted     (halted),
    .state      (state_q),
    .out_word   (out_word),
    .step_count (step_count),
    .wait_cnt   (wait_cnt),
    .tmo_total  (tmo_total),
    .tmo_flag   (tmo_flag),
    .err_cause  (err_cause),
    .err_seen   (err_seen)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer        niter;
integer        nbeat;
integer        k;
integer        err_entries;
integer        halt_enters;
integer        stall_beats;
integer        tmo_beats;
integer        err_changes;
integer        run_a_steps;
reg            bad;
reg     [7:0]  sp0;          // step_count snapshot taken on each arm beat
reg            new_tgt;
reg            new_opc;
reg            new_run;
reg            new_other;
reg            looped_f;
reg    [11:0]  img [0:15];
reg    [15:0]  ops_seen;

reg    [3:0]   prev_pc;
reg    [3:0]   prev_op;
reg    [3:0]   prev_out;
reg    [1:0]   prev_state;
reg    [7:0]   prev_step;
reg    [5:0]   prev_wait;
reg    [7:0]   prev_tmo;
reg            prev_tmo_flag;
reg    [2:0]   prev_err;
reg    [4:0]   prev_seen;
reg            prev_run;
reg            prev_halted;

// ---- one beat ------------------------------------------------------------
// The caller has already driven ld_*/arm for this beat.  Exactly one rising edge lies
// between the drive point and the sample point, and clk_en is forced low again at the
// sample point, so one call is exactly one beat of the DUT and of ips_cycle.
task do_beat;
begin
    state = state * 32'd1664525 + 32'd1013904223;
    if (iw_mode === 2'd1) begin
        iw = {state[31], state[20], state[11], state[0]};
    end else begin
        iw = iw_scr;
    end
    niter = niter + 1;

    @(negedge ips_clk);
    clk_en = en_b;

    @(negedge ips_clk);
    clk_en = 1'b0;

    if (en_b !== 1'b1) begin
        // A gated beat must leave the whole visible state untouched, including a held
        // arm pulse: it never reaches an enabled edge, so it never runs.
        if (state_q !== prev_state || pc !== prev_pc || cur_op !== prev_op ||
            out_word !== prev_out || step_count !== prev_step ||
            wait_cnt !== prev_wait || tmo_total !== prev_tmo ||
            tmo_flag !== prev_tmo_flag || err_cause !== prev_err ||
            err_seen !== prev_seen || run !== prev_run || halted !== prev_halted) begin
            bad = 1'b1;
        end
    end else begin
        nbeat = nbeat + 1;

        // ---- which causes (if any) appeared on this beat -------------------
        new_tgt   = (err_seen[EC_TGT] !== prev_seen[EC_TGT]);
        new_opc   = (err_seen[EC_OPC] !== prev_seen[EC_OPC]);
        new_run   = (err_seen[EC_RUN] !== prev_seen[EC_RUN]);
        new_other = (err_seen[0] !== prev_seen[0]) || (err_seen[4] !== prev_seen[4]);

        // ---- X safety on every reported output ----------------------------
        if ((^pc === 1'bx) || (^cur_op === 1'bx) || (run === 1'bx) ||
            (halted === 1'bx) || (^state_q === 1'bx) || (^out_word === 1'bx) ||
            (^step_count === 1'bx) || (^wait_cnt === 1'bx) || (^tmo_total === 1'bx) ||
            (tmo_flag === 1'bx) || (^err_cause === 1'bx) || (^err_seen === 1'bx)) begin
            bad = 1'b1;
        end

        // ---- state decode and mutual exclusion ---------------------------
        if (run && halted) bad = 1'b1;
        if (run !== (state_q === ST_RUN)) bad = 1'b1;
        if (halted !== (state_q === ST_HALT)) bad = 1'b1;

        // ---- a re-arm is a full, clean restart of the run state -----------
        if (act === ACT_ARM) begin
            if (state_q !== ST_RUN) bad = 1'b1;
            if (out_word !== 4'h0 || wait_cnt !== 6'h0 || tmo_flag !== 1'b0 ||
                cur_op !== 4'h0) bad = 1'b1;
        end

        // ---- terminal states are only left by an explicit arm -------------
        if (act !== ACT_ARM && (prev_state === ST_ERR || prev_state === ST_HALT)) begin
            if (state_q !== prev_state) bad = 1'b1;
            if (pc !== prev_pc || cur_op !== prev_op || out_word !== prev_out ||
                step_count !== prev_step || wait_cnt !== prev_wait ||
                tmo_total !== prev_tmo || tmo_flag !== prev_tmo_flag) bad = 1'b1;
        end

        // ---- nothing executes and nothing moves while the sequencer is idle
        if (prev_state === ST_IDLE && act !== ACT_ARM) begin
            if (state_q !== ST_IDLE) bad = 1'b1;
            if (pc !== prev_pc || step_count !== prev_step ||
                out_word !== prev_out || cur_op !== prev_op) bad = 1'b1;
        end

        // ---- a load beat and an idle beat never retire an instruction -----
        // (the update port owns its beat, even in the middle of run F)
        if (act === ACT_LOAD || act === ACT_IDLE) begin
            if (pc !== prev_pc || out_word !== prev_out ||
                step_count !== prev_step || cur_op !== prev_op ||
                wait_cnt !== prev_wait || tmo_total !== prev_tmo) bad = 1'b1;
        end

        // ---- counters never jump and never run backwards ------------------
        if (!(step_count === prev_step || step_count === (prev_step + 8'h01))) bad = 1'b1;
        if (!(tmo_total === prev_tmo || tmo_total === (prev_tmo + 8'h01))) bad = 1'b1;

        // ---- the timeout flag tracks the timeout counter and the re-arm ----
        if (tmo_flag === 1'b1 && prev_tmo_flag === 1'b0 && tmo_total === prev_tmo) bad = 1'b1;
        if (tmo_flag === 1'b0 && prev_tmo_flag === 1'b1 && act !== ACT_ARM) bad = 1'b1;

        // ---- the stall counter belongs to a WAIT step and to nothing else --
        if (cur_op !== OP_WAIT && wait_cnt !== 6'h0) bad = 1'b1;
        if (wait_cnt !== 6'h0 && state_q !== ST_RUN) bad = 1'b1;

        // ---- the output word only moves through set/clear/inc or a re-arm --
        if (out_word !== prev_out && act !== ACT_ARM) begin
            if (!(cur_op === OP_SET || cur_op === OP_CLR || cur_op === OP_INC)) bad = 1'b1;
        end

        // ---- fetch/decode replayed against the TB's own program image ------
        if (act === ACT_RUN && prev_state === ST_RUN) begin
            if (cur_op !== img[prev_pc][11:8]) bad = 1'b1;
            if (!(pc === (prev_pc + 4'h1) || pc === prev_pc ||
                  pc === img[prev_pc][7:4])) bad = 1'b1;
            // a stalled WAIT holds its address; only a passing WAIT advances it
            if (cur_op === OP_WAIT && wait_cnt !== 6'h0 && pc !== prev_pc) bad = 1'b1;
        end

        // ---- an error is always terminal, explicit and never silent -------
        if (state_q === ST_ERR) begin
            if (err_cause === 3'd0) bad = 1'b1;
            if (err_seen === 5'b00000) bad = 1'b1;
        end
        // ---- at most one cause bit appears per beat -----------------------
        if (new_tgt && (new_opc || new_run || new_other)) bad = 1'b1;
        if (new_opc && (new_run || new_other)) bad = 1'b1;
        if (new_run && new_other) bad = 1'b1;

        // ---- scenario coverage counters -----------------------------------
        if (state_q === ST_ERR && prev_state !== ST_ERR) err_entries = err_entries + 1;
        if (state_q === ST_HALT && prev_state !== ST_HALT) halt_enters = halt_enters + 1;
        if (wait_cnt !== 6'h0) stall_beats = stall_beats + 1;
        if (tmo_total !== prev_tmo) tmo_beats = tmo_beats + 1;
        if (err_cause !== prev_err) err_changes = err_changes + 1;
        if (act === ACT_RUN && prev_state === ST_RUN && state_q !== ST_ERR) begin
            ops_seen[cur_op] = 1'b1;
        end
        if (act === ACT_RUN && prev_state === ST_RUN && pc < prev_pc) begin
            looped_f = 1'b1;
        end
        if (err_seen !== (prev_seen | err_seen)) bad = 1'b1;

        // ---- fold (four words; the rule is stated at the top of this file) --
        ips_fnv_word({18'd0, wait_cnt, pc, cur_op, out_word});
        ips_fnv_word({24'd0, step_count});
        ips_fnv_word({19'd0, tmo_flag, run, halted, state_q, err_cause, err_seen});
        ips_fnv_word({24'd0, tmo_total});

        prev_pc        = pc;
        prev_op        = cur_op;
        prev_out       = out_word;
        prev_state     = state_q;
        prev_step      = step_count;
        prev_wait      = wait_cnt;
        prev_tmo       = tmo_total;
        prev_tmo_flag  = tmo_flag;
        prev_err       = err_cause;
        prev_seen      = err_seen;
        prev_run       = run;
        prev_halted    = halted;
    end
end
endtask

task idle_beat(input enb);
begin
    en_b    = enb;
    ld_e    = 1'b0;
    arm_b   = 1'b0;
    act     = ACT_IDLE;
    iw_mode = 2'd0;
    iw_scr  = 4'h0;
    do_beat;
end
endtask

task load_beat(input [3:0] idx, input [11:0] data);
begin
    en_b    = 1'b1;
    ld_e    = 1'b1;
    ld_i    = idx;
    ld_d    = data;
    img[idx] = data;   // keep the TB's own image in step with the update port
    arm_b   = 1'b0;
    act     = ACT_LOAD;
    iw_mode = 2'd0;
    iw_scr  = 4'h0;
    do_beat;
end
endtask

task arm_beat;
begin
    en_b    = 1'b1;
    ld_e    = 1'b0;
    arm_b   = 1'b1;
    act     = ACT_ARM;
    iw_mode = 2'd0;
    iw_scr  = 4'h0;
    do_beat;
end
endtask

task run_beat;
begin
    en_b  = 1'b1;
    ld_e  = 1'b0;
    arm_b = 1'b0;
    act   = ACT_RUN;
    do_beat;
end
endtask

// exactly n run beats with the in_word source the caller selected
task run_n(input integer n);
begin
    for (k = 0; k < n; k = k + 1) begin
        run_beat;
    end
end
endtask

// run beats until the sequencer leaves S_RUN, with a hard beat budget so no mutant
// can make this testbench spin
task run_to_stop(input integer max);
reg done;
begin
    done = 1'b0;
    for (k = 0; k < max; k = k + 1) begin
        if (done === 1'b0) begin
            if (run === 1'b1) begin
                run_beat;
            end else begin
                done = 1'b1;
            end
        end
    end
    if (run === 1'b1) bad = 1'b1;
end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    en_b      = 1'b1;
    ld_e      = 1'b0;
    ld_i      = 4'h0;
    ld_d      = 12'h000;
    arm_b     = 1'b0;
    iw        = 4'h0;
    act       = ACT_IDLE;
    iw_mode   = 2'd0;
    iw_scr    = 4'h0;
    state     = SEED;
    bad         = 1'b0;
    niter       = 0;
    nbeat       = 0;
    err_entries = 0;
    halt_enters = 0;
    stall_beats = 0;
    tmo_beats   = 0;
    err_changes = 0;
    run_a_steps = 0;
    ops_seen    = 16'h000;
    new_tgt     = 1'b0;
    new_opc     = 1'b0;
    new_run     = 1'b0;
    new_other   = 1'b0;
    looped_f    = 1'b0;

    // ---- the program image (see the run map in the header comment) --------
    img[0]  = 12'h000;   // NOP              station 1
    img[1]  = 12'h103;   // SET  0011        station 2
    img[2]  = 12'h203;   // CLR  0011        station 3 (out_word -> 0)
    img[3]  = 12'h300;   // INC              station 4 (out_word -> 1)
    img[4]  = 12'h300;   // INC  (loop head) station 5
    img[5]  = 12'h448;   // JZ   bit3 -> 4   station 6 (bounded trip count, both legs)
    img[6]  = 12'h705;   // WAIT in_word[1]==1  station 7 (times out in run A)
    img[7]  = 12'h680;   // BRA  8           station 8 (skips nothing, retargets run F)
    img[8]  = 12'h704;   // WAIT in_word[0]==1  station 9
    img[9]  = 12'h707;   // WAIT in_word[3]==1  station 10 (times out in run A)
    img[10] = 12'h300;   // INC              station 11
    img[11] = 12'h5C8;   // JNZ  bit3 -> 12  station 12 (taken branch past PGM_LEN)
    img[12] = 12'hC02;   // undefined opcode, outside the program: run C proves that a
                             // step which both runs off the end and decodes a bad opcode
                             // reports ERR_RUN, not ERR_OPC
    img[13] = 12'h000;   // filler, outside the program
    img[14] = 12'h000;   // filler, outside the program
    img[15] = 12'h000;   // filler, outside the program

    repeat (4) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (3) @(negedge ips_clk);
    // Capture the reset state of the outputs without spending an enabled beat.
    prev_pc       = pc;
    prev_op       = cur_op;
    prev_out      = out_word;
    prev_state    = state_q;
    prev_step     = step_count;
    prev_wait     = wait_cnt;
    prev_tmo      = tmo_total;
    prev_tmo_flag = tmo_flag;
    prev_err      = err_cause;
    prev_seen     = err_seen;
    prev_run      = run;
    prev_halted   = halted;

    // ---- the reset state is the documented idle state ----------------------
    if (prev_state !== ST_IDLE || prev_out !== 4'h0 || prev_step !== 8'h00 ||
        prev_wait !== 6'h0 || prev_tmo !== 8'h00 || prev_tmo_flag !== 1'b0 ||
        prev_err !== 3'd0 || prev_seen !== 5'b00000 || prev_run !== 1'b0 ||
        prev_halted !== 1'b0 || prev_op !== 4'h0) bad = 1'b1;

    // ---- two gated beats before anything is loaded -------------------------
    idle_beat(1'b0);
    idle_beat(1'b0);

    // ---- load the whole sixteen-entry program through the update port ------
    for (k = 0; k < 16; k = k + 1) begin
        load_beat(k[3:0], img[k]);
    end
    idle_beat(1'b1);

    // ---- run A: every opcode, three timeouts, a taken branch past the end --
    arm_beat;
    sp0 = step_count;
    iw_mode = 2'd0;
    iw_scr  = 4'h0;          // no WAIT condition is ever satisfied
    run_to_stop(120);
    if (state_q !== ST_ERR || run !== 1'b0) bad = 1'b1;
    if (pc !== 4'hB) bad = 1'b1;          // the error step holds its own address
    if (cur_op !== OP_JNZ) bad = 1'b1;
    if (out_word !== 4'h9) bad = 1'b1;    // 1 + 7 loop trips + one INC
    if (step_count !== 8'd23) bad = 1'b1; // 18 to reach the WAIT chain, then 5 more
    if (tmo_total !== 8'h03) bad = 1'b1;  // three timeouts, one per stalled WAIT
    if (tmo_flag !== 1'b1) bad = 1'b1;
    if (!new_tgt || new_opc || new_run) bad = 1'b1;   // cause = ERR_TGT
    if (err_cause !== EC_TGT) bad = 1'b1;
    if (err_seen !== 5'b00010) bad = 1'b1;
    run_a_steps = step_count;

    // ---- run B: the WAITs become NOPs and the branch becomes a clean HALT --
    load_beat(4'd6,  12'h000);
    load_beat(4'd8,  12'h000);
    load_beat(4'd9,  12'h000);
    load_beat(4'd11, 12'h800);
    idle_beat(1'b1);
    arm_beat;
    sp0 = step_count;
    iw_scr = 4'h0;
    run_to_stop(60);
    if (state_q !== ST_HALT || halted !== 1'b1 || run !== 1'b0) bad = 1'b1;
    if (pc !== 4'hB) bad = 1'b1;          // HALT leaves pc pointing at itself
    if (step_count - sp0 !== 8'd24) bad = 1'b1; // every step retired, including the HALT
    if (tmo_total !== 8'h03) bad = 1'b1;  // no WAIT was stalled, so no new timeout
    if (tmo_flag !== 1'b0) bad = 1'b1;    // the re-arm cleared it
    if (new_tgt || new_opc || new_run) bad = 1'b1;

    // ---- run C: run off the end of the program -> ERR_RUN beats ERR_OPC ----
    load_beat(4'd11, 12'h300);
    arm_beat;
    sp0 = step_count;
    iw_scr = 4'h0;
    run_to_stop(60);
    if (state_q !== ST_ERR) bad = 1'b1;
    if (pc !== 4'hC) bad = 1'b1;          // the first out-of-range entry
    if (cur_op !== 4'hC) bad = 1'b1;      // it is also an undefined opcode...
    if (err_cause !== EC_TGT) bad = 1'b1; // ...but the first cause stays ERR_TGT
    if (!new_run || new_opc) bad = 1'b1;  // this step reports ERR_RUN, not ERR_OPC
    if (err_seen !== 5'b01010) bad = 1'b1;
    if (step_count - sp0 !== 8'd24) bad = 1'b1;

    // ---- run D: an undefined opcode inside the program -> ERR_OPC ----------
    load_beat(4'd5, 12'hC00);
    arm_beat;
    sp0 = step_count;
    iw_scr = 4'h0;
    run_to_stop(60);
    if (state_q !== ST_ERR) bad = 1'b1;
    if (pc !== 4'h5) bad = 1'b1;
    if (cur_op !== 4'hC) bad = 1'b1;
    if (!new_opc || new_run || new_tgt) bad = 1'b1;  // a distinct cause code
    if (err_seen !== 5'b01110) bad = 1'b1;
    if (step_count - sp0 !== 8'd5) bad = 1'b1;  // NOP, SET, CLR, INC, INC and stop

    // ---- run E: the run-A program again, with in_word from the LCG ---------
    load_beat(4'd5,  12'h448);
    load_beat(4'd6,  12'h705);
    load_beat(4'd8,  12'h704);
    load_beat(4'd9,  12'h707);
    load_beat(4'd11, 12'h5C8);
    arm_beat;
    sp0 = step_count;
    iw_mode = 2'd1;      // stall lengths now vary beat by beat
    run_to_stop(120);
    if (state_q !== ST_ERR) bad = 1'b1;
    if (pc !== 4'hB) bad = 1'b1;
    if (out_word !== 4'h9) bad = 1'b1;
    if (step_count - sp0 !== 8'd23) bad = 1'b1;
    // a repeated cause sets no new bit but is still terminal
    if (new_tgt || new_opc || new_run) bad = 1'b1;
    if (err_seen !== 5'b01110) bad = 1'b1;
    if (tmo_total < 8'h03 || tmo_total > 8'h06) bad = 1'b1;

    // ---- run F: an outer loop, re-programmed while it is running -----------
    load_beat(4'd11, 12'h541);   // JNZ bit0 -> 4 : re-enters the loop while bit0 is set
    iw_mode = 2'd0;
    iw_scr  = 4'h1;              // in_word[0] high, in_word[1] and [3] low
    arm_beat;
    sp0 = step_count;
    run_n(60);
    if (state_q !== ST_RUN) bad = 1'b1;    // still looping after 60 beats
    load_beat(4'd11, 12'h800);   // rewrite the branch as a HALT, run still live
    if (state_q !== ST_RUN) bad = 1'b1;    // the update beat did not disturb the run
    run_to_stop(200);
    if (state_q !== ST_HALT || halted !== 1'b1) bad = 1'b1;
    if (pc !== 4'hB) bad = 1'b1;
    if (looped_f === 1'b0) bad = 1'b1;     // a branch really did jump backwards

    // ---- tail: an arm pulse on a gated beat must not start anything ---------
    en_b    = 1'b0;
    ld_e    = 1'b0;
    arm_b   = 1'b1;
    act     = ACT_ARM;
    iw_mode = 2'd0;
    iw_scr  = 4'h0;
    do_beat;
    arm_b   = 1'b0;
    act     = ACT_IDLE;
    do_beat;
    idle_beat(1'b1);
    idle_beat(1'b0);
    idle_beat(1'b1);
    idle_beat(1'b1);
    idle_beat(1'b0);
    idle_beat(1'b1);
    idle_beat(1'b1);
    idle_beat(1'b0);
    idle_beat(1'b1);
    idle_beat(1'b1);
    idle_beat(1'b1);
    idle_beat(1'b0);
    idle_beat(1'b1);

    // ---- the run must have exercised what it claims -------------------------
    if (niter < ITER_MIN || niter > ITER_MAX) bad = 1'b1;
    if (step_count === 8'h00) bad = 1'b1;
    if (ops_seen !== OPS_ALL) bad = 1'b1;
    if (err_entries < 4) bad = 1'b1;
    if (halt_enters < 2) bad = 1'b1;
    if (tmo_beats < 3) bad = 1'b1;
    if (stall_beats < 20) bad = 1'b1;
    if (err_changes > 1) bad = 1'b1;
    if (run_a_steps !== 23) bad = 1'b1;
    if (err_cause !== EC_TGT) bad = 1'b1;
    if (err_seen !== 5'b01110) bad = 1'b1;
    if (run !== 1'b0 || state_q !== ST_HALT) bad = 1'b1;
    if (pc !== 4'hB) bad = 1'b1;

    ips_fnv_word({24'd0, step_count});
    ips_fnv_word({24'd0, tmo_total});
    ips_fnv_word({20'd0, pc, cur_op, out_word});
    ips_fnv_word({19'd0, tmo_flag, run, halted, state_q, err_cause, err_seen});
    ips_fnv_word(niter[31:0]);
    ips_fnv_word(nbeat[31:0]);

    ips_verdict(!bad, "ips_micro_sequencer16");
end

endmodule
