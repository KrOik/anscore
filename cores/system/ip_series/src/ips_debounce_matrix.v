`timescale 1ns / 1ps
// ips_debounce_matrix : N-line key-matrix debouncer with a per-key stable count
// and a most-recent-change event ledger.
//
// Written contract.  sim/tb_ips_debounce_matrix.v and
// models/ips_debounce_matrix.py are both derived from this text, and the model
// re-implements the rules independently of the RTL code (docs/IP_CORE_SOP.md
// trap T1).  Every register is gated by clk_en, rst_n is the active-low
// asynchronous reset (trap T2), all per-key state lives in FLAT vectors that are
// sliced with base +: width (trap T3, no multi-dimensional arrays anywhere) and
// there is no constant multiply (trap T4): the ledger byte offset is written as a
// bit-position concatenation, which is pure wiring.
//
// Geometry.  The physical scan bus is a FIXED 12-line vector raw_in so that the
// port list never changes with the parameter; KEY_N (<= 12) states how many of
// those lines are real keys.  Line kk is live when kk < KEY_N.  Lines at or
// beyond KEY_N are treated as never pressed: their debounced state, their stable
// count and their change strobe are held at 0, so one RTL serves the 4/8/12-key
// products of the family.  The packaged default is KEY_N = 8.
//
// Sampling.  raw_in is asynchronous, so it goes through two flop stages
// (raw_q1, raw_q2) before it is used.  An internal sample tick stb is generated
// by a modulo prescaler: stb is asserted once every (SAMPLE_DIV + 1) enabled
// beats (sdiv counts 0..SAMPLE_DIV and wraps).  All key evaluation, all event
// bookkeeping and all ledger movement happen exclusively on a sample tick, so the
// debounced outputs are synchronous to this clock domain and a bounce can never
// be partly observed.  sample_tick is the registered image of stb and
// tick_total (8 bit, wraps) counts sample ticks.
//
// Per-key stable count (the debounce rule).  Each live key has a 4-bit stable
// count, stored in cnt_flat as 12 nibbles, and a debounced level key_state[kk].
// On every sample tick, with lvl = raw_q2[kk] and st = key_state[kk]:
//   lvl == st                     -> count <= 0.  If the count was non-zero the
//                                    disagreeing run was interrupted, which is
//                                    exactly one rejected bounce (bounce_now).
//   lvl != st and count < MAX      -> count <= count + 1
//   lvl != st and count == STABLE_MAX -> key_state <= lvl, count <= 0,
//                                    key_change[kk] pulses, chg_sticky[kk] latches.
// So a new level must be observed for (STABLE_MAX + 1) consecutive sample ticks
// before the debounced level moves, and ANY agreeing tick restarts the count.  A
// glitch shorter than that can never move key_state and can never raise a change
// strobe; it only raises bounce_count, which saturates at 4'd12.  Keys are fully
// independent: nothing in the per-key loop reads another key's count or state.
//
// Change-event ledger.  At most one record is pushed per sample tick: the lowest
// index that changed wins (priority scan, no loop over a matrix), and if a second
// key changed in the same tick then multi_sticky latches and multi_count steps
// (saturates at 4'd7) so simultaneous presses are never silently merged.
// A record is 8 bits: {index[3:0], seq[2:0], level}.  seq is seq_tag, a rotating
// tag 0..SEQ_MAX that lets a reader see whether records were dropped or reordered;
// it advances on every push.  event_rec is the record of the last push and
// event_valid pulses for the one enabled beat in which a push happened.
// ledger is a 64-bit flat word of 8 record slots, slot 0 (the low byte) being the
// NEWEST: slot b takes the previous slot b-1, slot 0 takes the new record, and
// slots at or beyond LED_SLOTS are forced to 0.  LED_SLOTS (default 6) is
// therefore the depth of the visible window.  led_count is the number of live
// slots and saturates at LED_SLOTS: an event that finds the window full does NOT
// lose evidence, it latches led_full and steps drop_count, which saturates at
// DROP_SAT.  event_total (8 bit) saturates at 8'hFF and counts every push for the
// life of the part, independent of any clear.
//
// clear_led is the host read/acknowledge strobe: it zeroes ledger, led_count,
// led_full and drop_count.  It takes effect BEFORE a push in the same beat, so a
// clear coincident with an event leaves a ledger holding exactly that one record,
// led_count = 1, led_full = 0 and drop_count = 0.  It never touches key_state,
// chg_sticky, bounce_count, multi_*, event_total or tick_total.
//
// Reset state: both synchroniser stages and every key state, count and strobe
// cleared, ledger and all counters and flags cleared, seq_tag 0.  Nothing can
// hang: the prescaler always advances, every count has its own saturating value,
// an inactive line simply holds its key at level 0, and the ledger is a shift
// register that cannot fill up because the oldest slot falls off.
module ips_debounce_matrix #(
    parameter KEY_N      = 4'd8,
    parameter SAMPLE_DIV = 3'd1,
    parameter STABLE_MAX = 4'd3,
    parameter LED_SLOTS  = 4'd6
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire [11:0] raw_in,
    input  wire        clear_led,

    output reg  [11:0] key_state,
    output reg  [11:0] key_change,
    output reg  [11:0] chg_sticky,
    output reg  [47:0] cnt_flat,
    output reg         sample_tick,
    output reg         event_valid,
    output reg  [7:0]  event_rec,
    output reg  [63:0] ledger,
    output reg  [3:0]  led_count,
    output reg  [2:0]  seq_tag,
    output reg         led_full,
    output reg  [3:0]  drop_count,
    output reg  [3:0]  multi_count,
    output reg         multi_sticky,
    output reg  [3:0]  bounce_count,
    output reg  [7:0]  event_total,
    output reg  [7:0]  tick_total
);

localparam [2:0] SEQ_MAX    = 3'd5;
localparam [3:0] DROP_SAT   = 4'd10;
localparam [3:0] MULTI_SAT  = 4'd7;
localparam [3:0] BOUNCE_SAT = 4'd12;
localparam [3:0] KEY_BUS    = 4'd12;
localparam [3:0] LED_BUS    = 4'd8;

reg [11:0] raw_q1;
reg [11:0] raw_q2;
reg [2:0]  sdiv;

reg        stb;
reg        live;
reg        agree;
reg        lvl;
reg        st;
reg [3:0]  kk;
reg [3:0]  bb;
reg [3:0]  pp;
reg [3:0]  ccur;
reg [7:0]  nb;
reg [7:0]  rec_val;
reg [63:0] base_led;
reg [63:0] nxt_led;
reg [47:0] nxt_cnt;
reg [11:0] nxt_state;
reg [11:0] nxt_chg;
reg [11:0] nxt_sticky;
reg        ev_any;
reg        ev_multi;
reg        ev_bounce;
reg [3:0]  ev_idx;
reg        ev_lvl;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        raw_q1       <= 12'd0;
        raw_q2       <= 12'd0;
        sdiv         <= 3'd0;
        key_state    <= 12'd0;
        key_change   <= 12'd0;
        chg_sticky   <= 12'd0;
        cnt_flat     <= 48'd0;
        sample_tick  <= 1'b0;
        event_valid  <= 1'b0;
        event_rec    <= 8'd0;
        ledger       <= 64'd0;
        led_count    <= 4'd0;
        seq_tag      <= 3'd0;
        led_full     <= 1'b0;
        drop_count   <= 4'd0;
        multi_count  <= 4'd0;
        multi_sticky <= 1'b0;
        bounce_count <= 4'd0;
        event_total  <= 8'd0;
        tick_total   <= 8'd0;
    end else if (clk_en) begin
        raw_q1      <= raw_in;
        raw_q2      <= raw_q1;

        stb = (sdiv == SAMPLE_DIV);
        sdiv <= stb ? 3'd0 : (sdiv + 3'd1);

        sample_tick <= stb;
        event_valid <= 1'b0;
        key_change  <= 12'd0;

        if (clear_led) begin
            ledger     <= 64'd0;
            led_count  <= 4'd0;
            led_full   <= 1'b0;
            drop_count <= 4'd0;
        end

        if (stb) begin
            tick_total <= tick_total + 8'd1;

            nxt_state  = key_state;
            nxt_sticky = chg_sticky;
            nxt_cnt    = cnt_flat;
            nxt_chg    = 12'd0;

            ev_any    = 1'b0;
            ev_multi  = 1'b0;
            ev_bounce = 1'b0;
            ev_idx    = 4'd0;
            ev_lvl    = 1'b0;

            for (kk = 4'd0; kk < KEY_BUS; kk = kk + 4'd1) begin
                live = (kk < KEY_N);
                ccur = cnt_flat[{kk, 2'b00} +: 4];
                st   = key_state[kk];
                lvl  = raw_q2[kk] & live;

                if (!live) begin
                    nxt_cnt[{kk, 2'b00} +: 4] = 4'd0;
                    nxt_state[kk]             = 1'b0;
                end else begin
                    agree = (lvl == st);
                    if (agree) begin
                        if (ccur != 4'd0) begin
                            nxt_cnt[{kk, 2'b00} +: 4] = 4'd0;
                            ev_bounce = 1'b1;
                        end
                    end else if (ccur == STABLE_MAX) begin
                        nxt_cnt[{kk, 2'b00} +: 4] = 4'd0;
                        nxt_state[kk]             = lvl;
                        nxt_chg[kk]               = 1'b1;
                        nxt_sticky[kk]            = 1'b1;
                        if (ev_any) begin
                            ev_multi = 1'b1;
                        end else begin
                            ev_any = 1'b1;
                            ev_idx = kk;
                            ev_lvl = lvl;
                        end
                    end else begin
                        nxt_cnt[{kk, 2'b00} +: 4] = ccur + 4'd1;
                    end
                end
            end

            key_state  <= nxt_state;
            chg_sticky <= nxt_sticky;
            cnt_flat   <= nxt_cnt;
            key_change <= nxt_chg;

            if (ev_bounce) begin
                if (bounce_count != BOUNCE_SAT) begin
                    bounce_count <= bounce_count + 4'd1;
                end
            end
            if (ev_multi) begin
                multi_sticky <= 1'b1;
                if (multi_count != MULTI_SAT) begin
                    multi_count <= multi_count + 4'd1;
                end
            end

            if (ev_any) begin
                event_valid <= 1'b1;
                rec_val     = {ev_idx, seq_tag, ev_lvl};
                event_rec   <= rec_val;
                seq_tag     <= (seq_tag == SEQ_MAX) ? 3'd0 : (seq_tag + 3'd1);

                base_led = clear_led ? 64'd0 : ledger;
                nxt_led  = 64'd0;
                for (bb = 4'd0; bb < LED_BUS; bb = bb + 4'd1) begin
                    if (bb == 4'd0) begin
                        nb = rec_val;
                    end else if (bb < LED_SLOTS) begin
                        pp = bb - 4'd1;
                        nb = base_led[{pp, 3'b000} +: 8];
                    end else begin
                        nb = 8'd0;
                    end
                    nxt_led[{bb, 3'b000} +: 8] = nb;
                end
                ledger <= nxt_led;

                if (clear_led) begin
                    led_count <= 4'd1;
                end else if (led_count == LED_SLOTS) begin
                    led_full   <= 1'b1;
                    if (drop_count != DROP_SAT) begin
                        drop_count <= drop_count + 4'd1;
                    end
                end else begin
                    led_count <= led_count + 4'd1;
                end

                if (event_total != 8'hFF) begin
                    event_total <= event_total + 8'd1;
                end
            end
        end
    end
end

endmodule
