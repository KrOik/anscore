`timescale 1ns / 1ps
// tb_ips_debounce_matrix : production-line testbench for the key-matrix debouncer.
//
// Folding rule, restated verbatim in models/ips_debounce_matrix.py.  The expected
// stream is computed there from the core's written contract in src, never from
// this file (docs/IP_CORE_SOP.md trap T1):
//   one index i = one core clock cycle.  A cycle whose clk_en is low is a stall:
//   it folds nothing and does not advance ips_cycle.  Every enabled cycle folds
//   the complete registered state as SEVEN 32-bit words, MSB byte first:
//     W1 = {key_state, chg_sticky}
//     W2 = ledger[63:32]
//     W3 = ledger[31:0]
//     W4 = {key_change, event_rec, seq_tag, led_count, drop_count}
//     W5 = {event_total, tick_total, bounce_count, multi_count, led_full,
//           multi_sticky, sample_tick, event_valid}
//     W6 = cnt_flat[47:24]
//     W7 = cnt_flat[23:0]
//
// Stimulus contract (the golden model generates the identical stream).  Line 5 is
// never driven anywhere, so it is the independence witness: key 5 must stay
// inactive for the whole run whatever the parameters say.
//   BEATS = 560; state starts at SEED and advances exactly once per index with the
//   shared LCG state = state*1664525 + 1013904223 (mod 2**32), including the
//   stalled indices, which draw a value but issue no stimulus.
//     stall(i)          : (i % 40) == 39 -> clk_en low, bus and strobe idle.
//     16..47            key 0 pressed and held.
//     48..79            released.
//     80..103           key 1 glitched: a 2-beat pulse every 12 beats, i.e. one or
//                       two sample ticks, well below the stable count -> rejected.
//     104..135 / 136..167  key 2 press / release.
//     168..191          key 3 glitched: a 1-beat pulse every 5 beats -> rejected.
//     192..223 / 224..255  keys 4 AND 6 pressed / released together: one priority
//                          record only, plus multi_sticky/multi_count evidence.
//     256..287 / 288..319  key 7 press / release.
//     320..351 / 352..383  rows 11..8 held high / low.  With the declared KEY_N
//                          these lines are not keys, so they must not move any
//                          debounced state; they are folded, and the KEY_N mutant
//                          turns them into real presses.
//     384..503          keys 0,1,2,3,4,6 toggle on staggered 20-beat half periods:
//                       far more events than the ledger window holds, so led_count
//                       saturates, led_full latches and drop_count climbs.
//     504..559          LCG bus (line 5 masked off) with LCG clear_led strobes, so
//                       a clear coincident with a push is exercised too.
//
// Checks are transition invariants plus the directed edge cases above: a key's
// debounced level may only move on the beat its change strobe is high, and then it
// moves to the synchronised input level of two enabled beats earlier (the two-flop
// chain is mirrored in this testbench); change strobes only appear on sample
// ticks; chg_sticky is strictly 0->1; exactly one ledger record per sample tick,
// carrying the lowest changed index, the new level and the seq tag that was live
// before the push; slots shift by one on a push and the ledger is frozen otherwise;
// a push into a full window must show up as a drop_count step with led_full held,
// so an overflow can never be silent; clear_led empties the window and a
// coincident push leaves exactly one record; every counter moves only on the beat
// its own event strobe says; and a clk_en stall holds the complete registered state
// including every one-beat pulse.  All comparisons use === / !== (trap T6).
module tb_ips_debounce_matrix;

`include "ips_tb_common.vh"

localparam integer BEATS = 560;
localparam [31:0]  SEED  = 32'h5A17F00D;

reg                rst_n;
reg                clk_en;
reg  [31:0]        state;
reg  [11:0]        raw_bus;
reg                clear_led;

wire [11:0]        key_state;
wire [11:0]        key_change;
wire [11:0]        chg_sticky;
wire [47:0]        cnt_flat;
wire               sample_tick;
wire               event_valid;
wire [7:0]         event_rec;
wire [63:0]        ledger;
wire [3:0]         led_count;
wire [2:0]         seq_tag;
wire               led_full;
wire [3:0]         drop_count;
wire [3:0]         multi_count;
wire               multi_sticky;
wire [3:0]         bounce_count;
wire [7:0]         event_total;
wire [7:0]         tick_total;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_debounce_matrix dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .raw_in      (raw_bus),
    .clear_led   (clear_led),
    .key_state   (key_state),
    .key_change  (key_change),
    .chg_sticky  (chg_sticky),
    .cnt_flat    (cnt_flat),
    .sample_tick (sample_tick),
    .event_valid (event_valid),
    .event_rec   (event_rec),
    .ledger      (ledger),
    .led_count   (led_count),
    .seq_tag     (seq_tag),
    .led_full    (led_full),
    .drop_count  (drop_count),
    .multi_count (multi_count),
    .multi_sticky(multi_sticky),
    .bounce_count(bounce_count),
    .event_total (event_total),
    .tick_total  (tick_total)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer q;
reg     rec_stall;
reg     rec_clr;
reg     bad;
reg [11:0] r_h1;
reg [11:0] r_h2;
reg [11:0] p_state;
reg [11:0] p_sticky;
reg [11:0] p_change;
reg [47:0] p_cnt;
reg [63:0] p_ledger;
reg [7:0]  p_rec;
reg [3:0]  p_ledc;
reg [2:0]  p_seq;
reg [3:0]  p_drop;
reg [3:0]  p_mcnt;
reg [3:0]  p_bnc;
reg [7:0]  p_etot;
reg [7:0]  p_tk;
reg        p_tick;
reg        p_ev;
reg        p_lfull;
reg        p_mstk;
reg [3:0]  ev_idx;
reg        low_set;

task idle_inputs;
    begin
        raw_bus   = 12'd0;
        clear_led = 1'b0;
    end
endtask

task drive_cycle;
    input integer k;
    begin
        rec_stall = ((k % 40) == 39);
        rec_clr   = 1'b0;
        state     = state * 32'd1664525 + 32'd1013904223;
        if (rec_stall) begin
            idle_inputs();
            clk_en = 1'b0;
        end else begin
            clk_en  = 1'b1;
            idle_inputs();
            if ((k >= 16) && (k <= 47)) begin
                raw_bus[0] = 1'b1;
            end else if ((k >= 80) && (k <= 103)) begin
                raw_bus[1] = ((((k - 80) % 12)) < 2);
            end else if ((k >= 104) && (k <= 135)) begin
                raw_bus[2] = 1'b1;
            end else if ((k >= 168) && (k <= 191)) begin
                raw_bus[3] = (((k - 168) % 5) == 0);
            end else if ((k >= 192) && (k <= 223)) begin
                raw_bus[4] = 1'b1;
                raw_bus[6] = 1'b1;
            end else if ((k >= 256) && (k <= 287)) begin
                raw_bus[7] = 1'b1;
            end else if ((k >= 320) && (k <= 351)) begin
                raw_bus[11:8] = 4'hF;
            end else if ((k >= 384) && (k <= 503)) begin
                raw_bus[0] = ((((k - 384 + 1)  / 20) % 2) == 1);
                raw_bus[1] = ((((k - 384 + 4)  / 20) % 2) == 1);
                raw_bus[2] = ((((k - 384 + 7)  / 20) % 2) == 1);
                raw_bus[3] = ((((k - 384 + 10) / 20) % 2) == 1);
                raw_bus[4] = ((((k - 384 + 13) / 20) % 2) == 1);
                raw_bus[6] = ((((k - 384 + 16) / 20) % 2) == 1);
            end else if (k >= 504) begin
                raw_bus   = state[11:0];
                raw_bus[5] = 1'b0;
                clear_led = (state[2:0] == 3'd2);
                rec_clr   = clear_led;
            end
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    state       = SEED;
    bad         = 1'b0;
    rec_stall   = 1'b0;
    rec_clr     = 1'b0;
    i           = 0;
    q           = 0;
    idle_inputs();
    r_h1        = 12'd0;
    r_h2        = 12'd0;
    p_state     = 12'd0;
    p_sticky    = 12'd0;
    p_change    = 12'd0;
    p_cnt       = 48'd0;
    p_ledger    = 64'd0;
    p_rec       = 8'd0;
    p_ledc      = 4'd0;
    p_seq       = 3'd0;
    p_drop      = 4'd0;
    p_mcnt      = 4'd0;
    p_bnc       = 4'd0;
    p_etot      = 8'd0;
    p_tk        = 8'd0;
    p_tick      = 1'b0;
    p_ev        = 1'b0;
    p_lfull     = 1'b0;
    p_mstk      = 1'b0;
    ev_idx      = 4'd0;
    low_set     = 1'b0;

    repeat (4) @(negedge ips_clk);
    rst_n = 1'b1;
    drive_cycle(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (rec_stall) begin
            // Trap T2: with clk_en low the whole registered state must hold,
            // synchroniser stages and one-beat strobes included.
            if ((key_state   !== p_state)  || (key_change !== p_change) ||
                (chg_sticky  !== p_sticky) || (cnt_flat   !== p_cnt)    ||
                (sample_tick !== p_tick)   || (event_valid !== p_ev)    ||
                (event_rec   !== p_rec)    || (ledger     !== p_ledger) ||
                (led_count   !== p_ledc)   || (seq_tag    !== p_seq)    ||
                (led_full    !== p_lfull)  || (drop_count !== p_drop)   ||
                (multi_count !== p_mcnt)   || (multi_sticky !== p_mstk) ||
                (bounce_count !== p_bnc)   || (event_total !== p_etot)  ||
                (tick_total  !== p_tk)) begin
                bad = 1'b1;
            end
        end else begin
            if ((^key_state   === 1'bx) || (^key_change === 1'bx) ||
                (^chg_sticky  === 1'bx) || (^cnt_flat   === 1'bx) ||
                (^sample_tick === 1'bx) || (^event_valid === 1'bx) ||
                (^event_rec   === 1'bx) || (^ledger      === 1'bx) ||
                (^led_count   === 1'bx) || (^seq_tag     === 1'bx) ||
                (^led_full    === 1'bx) || (^drop_count  === 1'bx) ||
                (^multi_count === 1'bx) || (^multi_sticky === 1'bx) ||
                (^bounce_count === 1'bx) || (^event_total === 1'bx) ||
                (^tick_total  === 1'bx)) begin
                bad = 1'b1;
            end

            // Independence witness: line 5 is never driven, so key 5 may never
            // move no matter what the geometry parameters say.
            if ((key_state[5] !== 1'b0) || (chg_sticky[5] !== 1'b0) ||
                (key_change[5] === 1'b1) || (cnt_flat[23:20] !== 4'd0)) begin
                bad = 1'b1;
            end

            // A debounced level only moves on the beat its strobe is high, a strobe
            // only appears on a sample tick, and the new level is the synchronised
            // input of two enabled beats earlier.
            for (q = 0; q < 12; q = q + 1) begin
                if (key_change[q] === 1'b1) begin
                    if (key_state[q] === p_state[q])            bad = 1'b1;
                    if (sample_tick !== 1'b1)                   bad = 1'b1;
                    if (chg_sticky[q] !== 1'b1)                 bad = 1'b1;
                    if (key_state[q] !== r_h2[q])               bad = 1'b1;
                end else if (key_state[q] !== p_state[q]) begin
                    bad = 1'b1;
                end
                if (chg_sticky[q] !== p_sticky[q]) begin
                    if (!((chg_sticky[q] === 1'b1) && (key_change[q] === 1'b1))) begin
                        bad = 1'b1;
                    end
                end
            end

            // Counters and ledger only move on the beat that owns them.
            if ((cnt_flat !== p_cnt) && (sample_tick !== 1'b1))       bad = 1'b1;
            if ((tick_total !== p_tk) &&
                !((sample_tick === 1'b1) && (tick_total === (p_tk + 8'd1)))) bad = 1'b1;
            if ((bounce_count !== p_bnc) &&
                !((sample_tick === 1'b1) && (bounce_count === (p_bnc + 4'd1)))) bad = 1'b1;
            if ((multi_count !== p_mcnt) &&
                !((sample_tick === 1'b1) && (multi_count === (p_mcnt + 4'd1)))) bad = 1'b1;
            if ((multi_sticky !== p_mstk) &&
                !((multi_sticky === 1'b1) && (multi_count !== p_mcnt)))          bad = 1'b1;
            if ((event_valid === 1'b1) && (sample_tick !== 1'b1))  bad = 1'b1;
            if ((|key_change) && (event_valid !== 1'b1))           bad = 1'b1;
            if ((key_change !== 12'd0) && (sample_tick !== 1'b1))  bad = 1'b1;
            if ((event_total !== p_etot) && (event_valid !== 1'b1)) bad = 1'b1;
            if (event_valid !== 1'b1) begin
                if (event_rec !== p_rec) bad = 1'b1;
                if (seq_tag   !== p_seq) bad = 1'b1;
                if (event_total !== p_etot) bad = 1'b1;
            end else begin
                if (!((p_etot === 8'hFF) || (event_total === (p_etot + 8'd1)))) bad = 1'b1;
            end

            if (event_valid === 1'b1) begin
                ev_idx = event_rec[7:4];
                if (ev_idx > 4'd11) begin
                    bad = 1'b1;
                end else begin
                    if (key_change[ev_idx] !== 1'b1)      bad = 1'b1;
                    if (key_state[ev_idx] !== event_rec[0]) bad = 1'b1;
                    if (event_rec[3:1] !== p_seq)         bad = 1'b1;
                    low_set = 1'b0;
                    for (q = 0; q < 12; q = q + 1) begin
                        if ((q < ev_idx) && (key_change[q] === 1'b1)) low_set = 1'b1;
                    end
                    if (low_set) bad = 1'b1;
                end
            end

            if (rec_clr) begin
                // clear takes effect before a coincident push.
                if (event_valid === 1'b1) begin
                    if ((ledger[63:8] !== 56'd0) || (led_count !== 4'd1)) bad = 1'b1;
                end else begin
                    if ((ledger !== 64'd0) || (led_count !== 4'd0) ||
                        (drop_count !== 4'd0) || (led_full !== 1'b0)) bad = 1'b1;
                end
            end else begin
                if (event_valid === 1'b1) begin
                    if (ledger[7:0]   !== event_rec)        bad = 1'b1;
                    if (ledger[15:8]  !== p_ledger[7:0])    bad = 1'b1;
                    if (ledger[23:16] !== p_ledger[15:8])   bad = 1'b1;
                    if (ledger[31:24] !== p_ledger[23:16])  bad = 1'b1;
                    if (ledger[39:32] !== p_ledger[31:24])  bad = 1'b1;
                    if (ledger[47:40] !== p_ledger[39:32])  bad = 1'b1;
                    if (led_count !== p_ledc) begin
                        if (led_count !== (p_ledc + 4'd1)) bad = 1'b1;
                    end else begin
                        // window full: the event must be visible as a drop, never
                        // silently swallowed
                        if (drop_count === p_drop) begin
                            if (p_lfull !== 1'b1) bad = 1'b1;
                        end else if (drop_count !== (p_drop + 4'd1)) begin
                            bad = 1'b1;
                        end
                    end
                    if (led_full !== p_lfull) begin
                        if (!((led_full === 1'b1) && (p_lfull === 1'b0))) bad = 1'b1;
                    end
                end else if (ledger !== p_ledger) begin
                    bad = 1'b1;
                end
            end
            if (drop_count < p_drop) begin
                if (!(rec_clr && (drop_count === 4'd0))) bad = 1'b1;
            end

            // Directed edge cases.
            if (i == 47)  if (key_state[0] !== 1'b1) bad = 1'b1;
            if (i == 79)  if (key_state[0] !== 1'b0) bad = 1'b1;
            if (i == 103) if ((key_state[1] !== 1'b0) || (chg_sticky[1] !== 1'b0)) bad = 1'b1;
            if (i == 135) if (key_state[2] !== 1'b1) bad = 1'b1;
            if (i == 167) if (key_state[2] !== 1'b0) bad = 1'b1;
            if (i == 191) if ((key_state[3] !== 1'b0) || (chg_sticky[3] !== 1'b0)) bad = 1'b1;
            if (i == 223) begin
                if ((key_state[4] !== 1'b1) || (key_state[6] !== 1'b1) ||
                    (chg_sticky[4] !== 1'b1) || (chg_sticky[6] !== 1'b1) ||
                    (multi_sticky !== 1'b1) || (multi_count === 4'd0)) bad = 1'b1;
            end
            if (i == 255) begin
                if ((key_state[4] !== 1'b0) || (key_state[6] !== 1'b0)) bad = 1'b1;
            end
            if (i == 287) if (key_state[7] !== 1'b1) bad = 1'b1;
            if (i == 319) if (key_state[7] !== 1'b0) bad = 1'b1;
            if (i == 499) begin
                if ((led_full !== 1'b1) || (drop_count === 4'd0) ||
                    (event_total === 8'd0) || (led_count === 4'd0)) bad = 1'b1;
            end

            ips_fnv_word({key_state, chg_sticky});
            ips_fnv_word(ledger[63:32]);
            ips_fnv_word(ledger[31:0]);
            ips_fnv_word({key_change, event_rec, seq_tag, led_count, drop_count});
            ips_fnv_word({event_total, tick_total, bounce_count, multi_count,
                          led_full, multi_sticky, sample_tick, event_valid});
            ips_fnv_word(cnt_flat[47:24]);
            ips_fnv_word(cnt_flat[23:0]);

            p_state  = key_state;
            p_sticky = chg_sticky;
            p_change = key_change;
            p_cnt    = cnt_flat;
            p_ledger = ledger;
            p_rec    = event_rec;
            p_ledc   = led_count;
            p_seq    = seq_tag;
            p_drop   = drop_count;
            p_mcnt   = multi_count;
            p_bnc    = bounce_count;
            p_etot   = event_total;
            p_tk     = tick_total;
            p_tick   = sample_tick;
            p_ev     = event_valid;
            p_lfull  = led_full;
            p_mstk   = multi_sticky;

            // mirror of the two-flop synchroniser, advanced only on enabled beats
            r_h2 = r_h1;
            r_h1 = raw_bus;
        end

        if ((i + 1) < BEATS) begin
            drive_cycle(i + 1);
        end
    end

    repeat (4) @(negedge ips_clk);
    ips_verdict(!bad, "ips_debounce_matrix");
end

endmodule
