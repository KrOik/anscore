`timescale 1ns / 1ps
// tb_ips_err_log_sticky : production-line testbench for the first-N error log.
//
// FOLDING RULE (mirrored independently by models/ips_err_log_sticky.py -- trap T1):
// one FNV-1a word stream, MSB byte first.  Every beat folds, in this order,
//   0 ts_count, 1 stk_word, 2 ovf_count, 3 drop_count, 4 src_sticky,
//   5 rd_record, 6 rd_ts, 7 rd_src, 8 n_unread, 9 wr_ptr, 10 rd_ptr,
//   11 pop_slot, 12 log_used, 13 flags = {rd_valid, log_full, log_empty,
//      ovf_sticky, dup_sticky, full_sticky, seen_sticky, epop_sticky},
//   14..17 log_flat, most significant 32-bit word first.
// After the beat loop the word BEATS is folded once.  Testbench wires are several
// bits wider than the core's default geometry, so a widened field still reaches the
// digest, and every comparison uses === so X can never look like a pass (trap T6).
//
// BEAT CONTRACT.  One iteration is one clock period: the plan for beat n is driven
// at a falling edge, the rising edge in the middle applies it, and the next falling
// edge observes the registered result.  clk_en is low for two windows (300..311 and
// 316..320) and an event plus a read attempt are deliberately driven inside the
// first one, so a register that missed its clk_en gate cannot survive.  Stimulus is
// the shared LCG, state = state*1664525 + 1013904223, advanced exactly once per beat
// index, so the golden model can reproduce the stream without this file.
//
// COVERAGE.  Fewer events than slots (all readable, in order), exactly NSLOTS
// events, far more than NSLOTS events (the overflow counter grows, saturates, never
// wraps, and the stored records are provably unchanged), per-source sticky coverage
// for all sixteen sources, sticky clear and log re-arm, pop on empty, disabled-beat
// immunity, and a double event in one beat: the LOWER source code takes the slot, an
// equal pair resolves to channel a, the loser is dropped and still sets its own
// sticky bit.  The queue below records what the core actually stored, sampled at the
// rising edge that wrote it, and every pop is checked against it.
module tb_ips_err_log_sticky;

`include "ips_tb_common.vh"

localparam integer BEATS = 600;
localparam [31:0]  SEED  = 32'h5EED1234;

reg         rst_n_tb;
reg         clk_en;
reg         err_a_valid;
reg  [7:0]  err_a_src;
reg         err_b_valid;
reg  [7:0]  err_b_src;
reg         rd_en;
reg         clr_all;
reg         stk_clr;
reg  [31:0] state;

wire [15:0] ts_count;
wire [7:0]  ovf_count;
wire [7:0]  drop_count;
wire [7:0]  stk_word;
wire [31:0] src_sticky;
wire [31:0] rd_record;
wire [15:0] rd_ts;
wire [7:0]  rd_src;
wire [7:0]  wr_ptr;
wire [7:0]  rd_ptr;
wire [7:0]  n_unread;
wire [7:0]  pop_slot;
wire [7:0]  log_used;
wire        log_full;
wire        log_empty;
wire        rd_valid;
wire        ovf_sticky;
wire        dup_sticky;
wire        full_sticky;
wire        seen_sticky;
wire        epop_sticky;
wire [127:0] log_flat;

// No #() override: the core's declared defaults are the shipped configuration and
// the mutation station mutates them, so overriding here would hide them.
ips_err_log_sticky dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n_tb),
    .err_a_valid (err_a_valid),
    .err_a_src   (err_a_src),
    .err_b_valid (err_b_valid),
    .err_b_src   (err_b_src),
    .rd_en       (rd_en),
    .clr_all     (clr_all),
    .stk_clr     (stk_clr),
    .ts_count    (ts_count),
    .ovf_count   (ovf_count),
    .drop_count  (drop_count),
    .stk_word    (stk_word),
    .src_sticky  (src_sticky),
    .rd_record   (rd_record),
    .rd_ts       (rd_ts),
    .rd_src      (rd_src),
    .wr_ptr      (wr_ptr),
    .rd_ptr      (rd_ptr),
    .n_unread    (n_unread),
    .log_full    (log_full),
    .log_empty   (log_empty),
    .rd_valid    (rd_valid),
    .pop_slot    (pop_slot),
    .log_used    (log_used),
    .ovf_sticky  (ovf_sticky),
    .dup_sticky  (dup_sticky),
    .full_sticky (full_sticky),
    .seen_sticky (seen_sticky),
    .epop_sticky (epop_sticky),
    .log_flat    (log_flat)
);

// ---------------------------------------------------------------------------
// What the coming rising edge will do, judged from the pre-edge outputs, and the
// queue of records the core really stored.
// ---------------------------------------------------------------------------
reg          p_wr_fire;
reg          p_pop_fire;
reg [15:0]   p_ts;
reg [7:0]    p_src;
reg [15:0]   q_ts  [0:639];
reg [7:0]    q_src [0:639];
integer      q_tail;
integer      q_head;
integer      q_head_exp;

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
        if (p_wr_fire === 1'b1) begin
            q_ts[q_tail]  = p_ts;
            q_src[q_tail] = p_src;
            q_tail = q_tail + 1;
        end
        if (p_pop_fire === 1'b1) begin
            q_head_exp = q_head_exp + 1;
        end
        // clr_all re-arms the core, so the reference queue restarts with it
        if (clr_all === 1'b1) begin
            q_tail     = 0;
            q_head     = 0;
            q_head_exp = 0;
        end
    end
end

// ---------------------------------------------------------------------------
// planned inputs for beat n -- the same schedule is written out independently in
// models/ips_err_log_sticky.py
// ---------------------------------------------------------------------------
task plan;
    input integer n;
    begin
        state = state * 32'd1664525 + 32'd1013904223;
        err_a_valid = 1'b0; err_a_src = 8'd0;
        err_b_valid = 1'b0; err_b_src = 8'd0;
        rd_en   = 1'b0;
        clr_all = 1'b0;
        stk_clr = 1'b0;
        clk_en  = 1'b1;
        if ((n >= 300 && n <= 311) || (n >= 316 && n <= 320)) clk_en = 1'b0;

        if (n == 10)      begin err_a_valid = 1'b1; err_a_src = 8'd5;  end
        else if (n == 13) begin err_a_valid = 1'b1; err_a_src = 8'd9;  end
        else if (n == 17) begin err_a_valid = 1'b1; err_a_src = 8'd2;  end
        else if (n == 22 || n == 23 || n == 24) rd_en = 1'b1;
        else if (n == 25) rd_en = 1'b1;
        else if (n == 26) clr_all = 1'b1;
        else if (n == 30) begin err_a_valid = 1'b1; err_a_src = 8'd0;  end
        else if (n == 34) begin err_a_valid = 1'b1; err_a_src = 8'd15; end
        else if (n == 38) begin err_a_valid = 1'b1; err_a_src = 8'd7;  end
        else if (n == 42) begin err_a_valid = 1'b1; err_a_src = 8'd3;  end
        else if (n == 50 || n == 51 || n == 52 || n == 53) rd_en = 1'b1;
        else if (n == 54) rd_en = 1'b1;
        else if (n == 58) clr_all = 1'b1;
        else if (n >= 60 && n <= 63) begin
            err_a_valid = 1'b1; err_a_src = (state >> 7) & 8'h0F;
        end
        else if (n >= 70 && n <= 230) begin
            err_a_valid = 1'b1; err_a_src = (state >> 7) & 8'h0F;
            if (((n - 70) % 6) == 0) begin
                err_b_valid = 1'b1; err_b_src = (state >> 19) & 8'h0F;
            end
        end
        else if (n == 240 || n == 241 || n == 242 || n == 243) rd_en = 1'b1;
        else if (n == 250) clr_all = 1'b1;
        else if (n == 251) stk_clr = 1'b1;
        else if (n >= 255 && n <= 270) begin
            err_a_valid = 1'b1; err_a_src = (n - 255) & 8'h0F;
        end
        else if (n == 275) clr_all = 1'b1;
        else if (n == 276) stk_clr = 1'b1;
        else if (n == 280) begin
            err_a_valid = 1'b1; err_a_src = 8'd3;
            err_b_valid = 1'b1; err_b_src = 8'd11;
        end
        else if (n == 282) rd_en = 1'b1;
        else if (n == 284) begin
            err_a_valid = 1'b1; err_a_src = 8'd7;
            err_b_valid = 1'b1; err_b_src = 8'd7;
        end
        else if (n == 285 || n == 286) rd_en = 1'b1;
        else if (n == 290) clr_all = 1'b1;
        else if (n == 305) begin err_a_valid = 1'b1; err_a_src = 8'd6; end
        else if (n == 308) rd_en = 1'b1;
        else if (n >= 340 && n <= 580) begin
            err_a_valid = ((state & 32'h00000007) == 32'h00000000);
            err_a_src   = (state >> 3)  & 8'h0F;
            err_b_valid = ((state & 32'h0000007F) == 32'h00000029);
            err_b_src   = (state >> 19) & 8'h0F;
            rd_en       = ((state & 32'h0000000F) == 32'h00000005);
            clr_all     = ((state & 32'h00000FFF) == 32'h000007FF);
            stk_clr     = ((state & 32'h000007FF) == 32'h000003F5);
        end

        p_wr_fire  = (((err_a_valid | err_b_valid) & ~clr_all) & ~log_full);
        p_pop_fire = ((rd_en & ~clr_all) & (n_unread != 8'd0));
        p_ts       = ts_count;
        p_src      = ((err_a_valid & ~clr_all)
                      ? (((err_b_valid & ~clr_all) && (err_b_src < err_a_src))
                         ? err_b_src : err_a_src)
                      : err_b_src);
    end
endtask

// ---------------------------------------------------------------------------
// previous-beat copies for the freeze / monotonic / frozen-log checks
// ---------------------------------------------------------------------------
reg [15:0]  pv_ts;
reg [7:0]   pv_ovf, pv_drop, pv_stk, pv_nu;
reg [31:0]  pv_src, pv_rec;
reg [127:0] pv_flat;
reg [15:0]  pv_rts;
reg [7:0]   pv_used;
reg         pv_full, pv_logfull;
reg [31:0]  src_snap;
reg         bad;

integer i;

initial begin
    ips_fnv_reset();
    rst_n_tb    = 1'b0;
    clk_en      = 1'b0;
    err_a_valid = 1'b0; err_a_src = 8'd0;
    err_b_valid = 1'b0; err_b_src = 8'd0;
    rd_en = 1'b0; clr_all = 1'b0; stk_clr = 1'b0;
    state       = SEED;
    q_tail      = 0;
    q_head      = 0;
    q_head_exp  = 0;
    bad         = 1'b0;
    p_wr_fire   = 1'b0;
    p_pop_fire  = 1'b0;
    p_ts        = 16'd0;
    p_src       = 8'd0;
    pv_full     = 1'b0;
    pv_logfull  = 1'b0;
    pv_used     = 8'd0;
    src_snap    = 32'd0;

    repeat (4) @(negedge ips_clk);
    rst_n_tb = 1'b1;
    repeat (2) @(negedge ips_clk);

    pv_ts = ts_count; pv_ovf = ovf_count; pv_drop = drop_count;
    pv_stk = stk_word; pv_nu = n_unread; pv_src = src_sticky;
    pv_rec = rd_record; pv_flat = log_flat; pv_rts = rd_ts;
    pv_full = full_sticky; pv_logfull = log_full; pv_used = log_used;

    plan(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        // ---- purity: nothing folded may be unknown ----------------------
        if (^{ts_count, ovf_count, drop_count, stk_word, src_sticky, rd_record,
              rd_ts, rd_src, wr_ptr, rd_ptr, n_unread, pop_slot, log_used, log_flat,
              log_full, log_empty, rd_valid, ovf_sticky, dup_sticky,
              full_sticky, seen_sticky, epop_sticky} === 1'bx) begin
            bad = 1'b1;
        end

        // ---- the empty flag must agree with the unread count ------------
        if (log_empty !== ((n_unread == 8'd0) ? 1'b1 : 1'b0)) bad = 1'b1;

        // ---- occupancy is exactly the unread count, so no write can have --
        // ---- landed on a record that was still unread ---------------------
        if ($countones(log_used) !== n_unread) bad = 1'b1;

        // ---- a disabled beat must not move one register -----------------
        if (clk_en === 1'b0) begin
            if (ts_count !== pv_ts || ovf_count !== pv_ovf || drop_count !== pv_drop ||
                stk_word !== pv_stk || n_unread !== pv_nu || src_sticky !== pv_src ||
                rd_record !== pv_rec || log_flat !== pv_flat || rd_ts !== pv_rts ||
                log_used !== pv_used || log_full !== pv_logfull) begin
                bad = 1'b1;
            end
        end

        // ---- saturating counters step by zero or one, never wrap --------
        if (clr_all === 1'b0) begin
            if (ovf_count !== pv_ovf && ovf_count !== (pv_ovf + 8'd1)) bad = 1'b1;
            if (drop_count !== pv_drop && drop_count !== (pv_drop + 8'd1)) bad = 1'b1;
            if (n_unread !== pv_nu && n_unread !== (pv_nu + 8'd1) &&
                n_unread !== (pv_nu - 8'd1)) bad = 1'b1;
            if (pv_logfull === 1'b1 && log_full === 1'b0) bad = 1'b1;
            if (pv_full === 1'b1 && full_sticky === 1'b0) bad = 1'b1;
        end

        // ---- log_full and its class bit rise together --------------------
        if (log_full === 1'b1 && pv_logfull === 1'b0 && full_sticky !== 1'b1) bad = 1'b1;

        // ---- while full, a non-pop beat leaves the stored log untouched --
        if (log_full === 1'b1 && pv_logfull === 1'b1 && rd_valid === 1'b0 &&
            clr_all === 1'b0 && log_flat !== pv_flat) begin
            bad = 1'b1;
        end

        // ---- the sticky source word keeps every bit until stk_clr --------
        if (stk_clr === 1'b0 && ((src_sticky & pv_src) !== pv_src)) bad = 1'b1;

        // ---- every pop returns exactly what the core stored, in order ----
        if (rd_valid === 1'b1) begin
            if (q_head >= q_tail) begin
                bad = 1'b1;
            end else begin
                if (rd_ts !== q_ts[q_head])    bad = 1'b1;
                if (rd_src !== q_src[q_head])  bad = 1'b1;
                // the slot it returned was occupied and is occupied no more
                if (pv_used[pop_slot] !== 1'b1)  bad = 1'b1;
                if (log_used[pop_slot] !== 1'b0) bad = 1'b1;
                q_head = q_head + 1;
            end
        end
        if (q_head !== q_head_exp) bad = 1'b1;

        // ---- scripted checkpoints ----------------------------------------
        if (i == 21 && n_unread !== 8'd3) bad = 1'b1;
        if (i == 25 && (log_empty !== 1'b1 || log_used !== 8'd0 ||
                        epop_sticky !== 1'b1)) bad = 1'b1;
        if (i == 27 && (log_used !== 8'd0 || ovf_sticky !== 1'b0 ||
                        epop_sticky !== 1'b0 || dup_sticky !== 1'b0 ||
                        seen_sticky !== 1'b0)) bad = 1'b1;
        if (i == 43 && n_unread !== 8'd4) bad = 1'b1;
        if (i == 55 && (log_used !== 8'd0 || q_head !== q_tail)) bad = 1'b1;
        if (i == 59 && log_used !== 8'd0) bad = 1'b1;
        if (i == 228 && (ovf_count !== pv_ovf || drop_count !== pv_drop)) bad = 1'b1;
        if (i == 229 && ovf_sticky !== 1'b1) bad = 1'b1;
        if (i == 229 && dup_sticky !== 1'b1) bad = 1'b1;
        if (i == 251 && log_used !== 8'd0) bad = 1'b1;
        if (i == 252 && src_sticky !== 32'd0) bad = 1'b1;
        if (i == 271 && (src_sticky !== 32'h0000FFFF || seen_sticky !== 1'b1)) bad = 1'b1;
        if (i == 277 && src_sticky !== 32'd0) bad = 1'b1;
        if (i == 281 && (src_sticky !== 32'h00000808 || dup_sticky !== 1'b1 ||
                         drop_count !== 8'd1 || ovf_count !== 8'd0)) bad = 1'b1;
        if (i == 286 && (epop_sticky !== 1'b1 || rd_valid !== 1'b0)) bad = 1'b1;
        if (i == 299) src_snap = src_sticky;
        if (i == 325 && (src_sticky !== src_snap || src_sticky[6] !== 1'b0)) bad = 1'b1;

        // ---- fold --------------------------------------------------------
        ips_fnv_word({16'd0, ts_count});
        ips_fnv_word({24'd0, stk_word});
        ips_fnv_word({24'd0, ovf_count});
        ips_fnv_word({24'd0, drop_count});
        ips_fnv_word(src_sticky);
        ips_fnv_word(rd_record);
        ips_fnv_word({16'd0, rd_ts});
        ips_fnv_word({24'd0, rd_src});
        ips_fnv_word({24'd0, n_unread});
        ips_fnv_word({24'd0, wr_ptr});
        ips_fnv_word({24'd0, rd_ptr});
        ips_fnv_word({24'd0, pop_slot});
        ips_fnv_word({24'd0, log_used});
        ips_fnv_word({24'd0, rd_valid, log_full, log_empty,
                      ovf_sticky, dup_sticky, full_sticky, seen_sticky, epop_sticky});
        ips_fnv_word(log_flat[127:96]);
        ips_fnv_word(log_flat[95:64]);
        ips_fnv_word(log_flat[63:32]);
        ips_fnv_word(log_flat[31:0]);

        pv_ts = ts_count; pv_ovf = ovf_count; pv_drop = drop_count;
        pv_stk = stk_word; pv_nu = n_unread; pv_src = src_sticky;
        pv_rec = rd_record; pv_flat = log_flat; pv_rts = rd_ts;
        pv_full = full_sticky; pv_logfull = log_full; pv_used = log_used;

        plan(i + 1);
    end

    clk_en      = 1'b0;
    err_a_valid = 1'b0; err_b_valid = 1'b0;
    rd_en = 1'b0; clr_all = 1'b0; stk_clr = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_err_log_sticky");
end

endmodule
