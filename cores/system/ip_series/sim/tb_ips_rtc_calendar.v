`timescale 1ns / 1ps
// tb_ips_rtc_calendar : production-line testbench for the civil calendar core.
//
// Folding rule, restated verbatim in models/ips_rtc_calendar.py.  The expected
// stream is computed there from the core's written contract and from Python's
// calendar module, never from this file (docs/IP_CORE_SOP.md trap T1):
//   one index i = one core clock cycle.  A cycle whose clk_en is low is a stall:
//   it folds nothing and does not advance ips_cycle.  Every enabled cycle folds
//   the complete registered state as FOUR 32-bit words, MSB byte first:
//     W1 = {year, mon, day, hour}
//     W2 = {dim, leap, tick, alarm_hit, alarm_sticky, set_ack, set_err,
//           clamp_sticky, mon_sticky, mon_count}
//     W3 = {tick_count, day_count}
//     W4 = {err_count, clamp_count, alarm_count}
//
// Stimulus contract (the golden model generates the identical stream):
//   BEATS = 400; state starts at SEED and advances exactly once per index with
//   the shared LCG state = state*1664525 + 1013904223 (mod 2**32), including the
//   stalled indices, which draw a value but issue no stimulus.
//     stall(i)      : (i % 40) == 39 -> clk_en low, all stimulus 0.
//     sweep 60..179 : j = (i-60)/5, o = (i-60)%5.  At o == 0 a preset is strobed
//                     with {SW_YR[j], SW_MO[j], day 31, hour (j<20 ? 23 : 0)}.
//                     Day 31 is past the end of every short month, so the core's
//                     clamp lands it exactly on the month end and the tick at
//                     o == 3 crosses that boundary; the free-running ticks in
//                     between show the intra-month steps.  mode = j % 6 picks the
//                     alarm work: 0 arm an exact match on the day about to be
//                     entered, 3 disable the alarm, 4 arm with mask 0 (fires once
//                     per calendar day), 5 arm hour-only and pulse alarm_ack at
//                     o == 2, 1 and 2 leave the alarm registers alone.
//     free 180..259 : stimulus 0, so days and months roll with no preset help.
//     probe 260..319: LCG presets that are frequently illegal (month 0, day 0,
//                     hour > 23), LCG alarm re-arms and acks.
//     tail 320..399 : as probe but with set_stb at state[2:0]==3, al_stb at 6 and
//                     alarm_ack at 1.
//
// Checks are transition invariants, so they hold whatever the arithmetic
// constants turn out to be: fields step by at most one, day/month/year only move
// in cascade, dim and leap only follow the date, a tick always moves the hour and
// a non-tick never moves it, the alarm fires only when enabled, only when every
// compared field agrees and at most once per calendar day, set_ack pulses exactly
// on a legal preset and is mutually exclusive with the set_err pulse of an
// illegal one, and a clk_en stall holds the complete registered state including
// every one-beat pulse.  All comparisons use === / !== (trap T6).
module tb_ips_rtc_calendar;

`include "ips_tb_common.vh"

localparam integer BEATS       = 400;
localparam integer SWEEP_START = 60;
localparam integer SWEEP_N     = 24;
localparam integer SWEEP_WIN   = 5;
localparam integer FREE_START  = 180;
localparam integer PROBE_START = 260;
localparam integer TAIL_START  = 320;
localparam [31:0]  SEED        = 32'h2C15A7E3;

reg                rst_n;
reg                clk_en;
reg  [31:0]        state;

reg                set_stb;
reg  [8:0]         set_year;
reg  [3:0]         set_mon;
reg  [5:0]         set_day;
reg  [4:0]         set_hour;

reg                al_stb;
reg                al_en;
reg  [3:0]         al_mask;
reg  [8:0]         al_year;
reg  [3:0]         al_mon;
reg  [5:0]         al_day;
reg  [4:0]         al_hour;
reg                alarm_ack;

wire [8:0]         year;
wire [3:0]         mon;
wire [5:0]         day;
wire [4:0]         hour;
wire [5:0]         dim;
wire               leap;
wire               tick;
wire [7:0]         tick_count;
wire [7:0]         day_count;
wire [3:0]         mon_count;
wire               mon_sticky;
wire               alarm_hit;
wire               alarm_sticky;
wire [7:0]         alarm_count;
wire               set_ack;
wire               set_err;
wire [3:0]         err_count;
wire               clamp_sticky;
wire [3:0]         clamp_count;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_rtc_calendar dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .set_stb      (set_stb),
    .set_year     (set_year),
    .set_mon      (set_mon),
    .set_day      (set_day),
    .set_hour     (set_hour),
    .al_stb       (al_stb),
    .al_en        (al_en),
    .al_mask      (al_mask),
    .al_year      (al_year),
    .al_mon       (al_mon),
    .al_day       (al_day),
    .al_hour      (al_hour),
    .alarm_ack    (alarm_ack),
    .year         (year),
    .mon          (mon),
    .day          (day),
    .hour         (hour),
    .dim          (dim),
    .leap         (leap),
    .tick         (tick),
    .tick_count   (tick_count),
    .day_count    (day_count),
    .mon_count    (mon_count),
    .mon_sticky   (mon_sticky),
    .alarm_hit    (alarm_hit),
    .alarm_sticky (alarm_sticky),
    .alarm_count  (alarm_count),
    .set_ack      (set_ack),
    .set_err      (set_err),
    .err_count    (err_count),
    .clamp_sticky (clamp_sticky),
    .clamp_count  (clamp_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Directed sweep table: (year mod 400, month) presets.  Months 1..12 of year
// index 24 (2024) sweep every month length and include the leap February;
// indices 100/200/300 are century common years, index 0 is the 400-year leap
// year, 399 -> 0 is the year wrap, and 3/4 are ordinary common/leap Februaries.
reg [8:0] SW_YR [0:SWEEP_N-1];
reg [3:0] SW_MO [0:SWEEP_N-1];

integer i;
integer jj;
integer oo;
reg     rec_stall;
reg     rec_set;
reg     rec_al;
reg     bad;
reg     step_chk;
reg     hit_seen;
reg     preset_after_hit;

reg [8:0] p_year;
reg [3:0] p_mon;
reg [5:0] p_day;
reg [4:0] p_hour;
reg [5:0] p_dim;
reg       p_leap;
reg       p_tick;
reg       p_ahit;
reg       p_astk;
reg       p_sack;
reg       p_serr;
reg [3:0] p_err;
reg       p_clst;
reg [3:0] p_clcnt;
reg       p_mstk;
reg [7:0] p_dayc;
reg [3:0] p_monic;
reg [7:0] p_alc;
reg [7:0] p_tkc;
reg [7:0] last_hit_day;

reg       m_al_en;
reg [3:0] m_al_mask;
reg [8:0] m_al_year;
reg [3:0] m_al_mon;
reg [5:0] m_al_day;
reg [4:0] m_al_hour;

task idle_inputs;
    begin
        set_stb   = 1'b0;
        al_stb    = 1'b0;
        alarm_ack = 1'b0;
        set_year  = 9'd0;
        set_mon   = 4'd0;
        set_day   = 6'd0;
        set_hour  = 5'd0;
        al_en     = m_al_en;
        al_mask   = m_al_mask;
        al_year   = m_al_year;
        al_mon    = m_al_mon;
        al_day    = m_al_day;
        al_hour   = m_al_hour;
    end
endtask

task sweep_inputs;
    input integer j;
    begin
        set_stb  = 1'b1;
        set_year = SW_YR[j];
        set_mon  = SW_MO[j];
        set_day  = 6'd31;
        set_hour = (j <= 20) ? 5'd23 : 5'd0;
        al_stb   = 1'b0;
        al_en    = m_al_en;
        al_mask  = m_al_mask;
        case (j % 6)
            0: begin
                al_stb  = 1'b1;
                al_en   = 1'b1;
                al_mask = 4'hF;
                al_day  = 6'd1;
                al_hour = 5'd0;
                al_mon  = (SW_MO[j] == 4'd12) ? 4'd1 : (SW_MO[j] + 4'd1);
                if (SW_MO[j] == 4'd12) begin
                    al_year = (SW_YR[j] == 9'd399) ? 9'd0 : (SW_YR[j] + 9'd1);
                end else begin
                    al_year = SW_YR[j];
                end
            end
            3: begin
                al_stb  = 1'b1;
                al_en   = 1'b0;
                al_mask = 4'hF;
                al_year = 9'd0;
                al_mon  = 4'd0;
                al_day  = 6'd0;
                al_hour = 5'd0;
            end
            4: begin
                al_stb  = 1'b1;
                al_en   = 1'b1;
                al_mask = 4'h0;
                al_year = 9'd0;
                al_mon  = 4'd0;
                al_day  = 6'd0;
                al_hour = 5'd0;
            end
            5: begin
                al_stb  = 1'b1;
                al_en   = 1'b1;
                al_mask = 4'h1;
                al_year = 9'd0;
                al_mon  = 4'd1;
                al_day  = 6'd1;
                al_hour = 5'd0;
            end
            default: begin
                al_year = m_al_year;
                al_mon  = m_al_mon;
                al_day  = m_al_day;
                al_hour = m_al_hour;
            end
        endcase
    end
endtask

task probe_inputs;
    begin
        set_stb   = (state[2:0] == 3'd5);
        al_stb    = (state[2:0] == 3'd2);
        alarm_ack = (state[2:0] == 3'd7);
        set_mon   = state[7:4];
        set_day   = state[13:8];
        set_hour  = state[18:14];
        set_year  = state[27:19];
        al_en     = state[3];
        al_mask   = state[13:10];
        al_year   = ~state[27:19];
        al_mon    = state[17:14];
        al_day    = state[23:18];
        al_hour   = state[28:24];
    end
endtask

task drive_cycle;
    input integer k;
    begin
        rec_stall = ((k % 40) == 39);
        rec_set   = 1'b0;
        rec_al    = 1'b0;
        state     = state * 32'd1664525 + 32'd1013904223;
        if (rec_stall) begin
            idle_inputs();
            clk_en = 1'b0;
        end else begin
            clk_en = 1'b1;
            if ((k >= SWEEP_START) && (k < SWEEP_START + SWEEP_N * SWEEP_WIN)) begin
                jj = (k - SWEEP_START) / SWEEP_WIN;
                oo = (k - SWEEP_START) % SWEEP_WIN;
                if (oo == 0) begin
                    sweep_inputs(jj);
                end else begin
                    idle_inputs();
                    if ((jj % 6) == 5) begin
                        alarm_ack = (oo == 2);
                    end
                end
            end else if (k >= PROBE_START) begin
                probe_inputs();
                if (k >= TAIL_START) begin
                    set_stb   = (state[2:0] == 3'd3);
                    al_stb    = (state[2:0] == 3'd6);
                    alarm_ack = (state[2:0] == 3'd1);
                end
            end else begin
                idle_inputs();
            end
            if (set_stb === 1'b1) rec_set = 1'b1;
            if (al_stb  === 1'b1) rec_al  = 1'b1;
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    state     = SEED;
    bad       = 1'b0;
    rec_stall = 1'b0;
    rec_set   = 1'b0;
    rec_al    = 1'b0;
    set_stb   = 1'b0;
    al_stb    = 1'b0;
    alarm_ack = 1'b0;
    set_year  = 9'd0;
    set_mon   = 4'd0;
    set_day   = 6'd0;
    set_hour  = 5'd0;
    al_en     = 1'b0;
    al_mask   = 4'd0;
    al_year   = 9'd0;
    al_mon    = 4'd0;
    al_day    = 6'd0;
    al_hour   = 5'd0;

    SW_YR[0]  = 9'd24;  SW_MO[0]  = 4'd1;
    SW_YR[1]  = 9'd24;  SW_MO[1]  = 4'd2;
    SW_YR[2]  = 9'd24;  SW_MO[2]  = 4'd3;
    SW_YR[3]  = 9'd24;  SW_MO[3]  = 4'd4;
    SW_YR[4]  = 9'd24;  SW_MO[4]  = 4'd5;
    SW_YR[5]  = 9'd24;  SW_MO[5]  = 4'd6;
    SW_YR[6]  = 9'd24;  SW_MO[6]  = 4'd7;
    SW_YR[7]  = 9'd24;  SW_MO[7]  = 4'd8;
    SW_YR[8]  = 9'd24;  SW_MO[8]  = 4'd9;
    SW_YR[9]  = 9'd24;  SW_MO[9]  = 4'd10;
    SW_YR[10] = 9'd24;  SW_MO[10] = 4'd11;
    SW_YR[11] = 9'd24;  SW_MO[11] = 4'd12;
    SW_YR[12] = 9'd100; SW_MO[12] = 4'd2;
    SW_YR[13] = 9'd200; SW_MO[13] = 4'd2;
    SW_YR[14] = 9'd300; SW_MO[14] = 4'd2;
    SW_YR[15] = 9'd0;   SW_MO[15] = 4'd2;
    SW_YR[16] = 9'd0;   SW_MO[16] = 4'd12;
    SW_YR[17] = 9'd25;  SW_MO[17] = 4'd2;
    SW_YR[18] = 9'd99;  SW_MO[18] = 4'd12;
    SW_YR[19] = 9'd100; SW_MO[19] = 4'd12;
    SW_YR[20] = 9'd399; SW_MO[20] = 4'd12;
    SW_YR[21] = 9'd3;   SW_MO[21] = 4'd2;
    SW_YR[22] = 9'd4;   SW_MO[22] = 4'd2;
    SW_YR[23] = 9'd24;  SW_MO[23] = 4'd1;

    m_al_en      = 1'b0;
    m_al_mask    = 4'd0;
    m_al_year    = 9'd0;
    m_al_mon     = 4'd0;
    m_al_day     = 6'd0;
    m_al_hour    = 5'd0;
    hit_seen     = 1'b0;
    preset_after_hit = 1'b0;
    last_hit_day = 8'd0;
    p_year       = 9'd0;
    p_mon        = 4'd1;
    p_day        = 6'd1;
    p_hour       = 5'd0;
    p_dim        = 6'd31;
    p_leap       = 1'b1;
    p_tick       = 1'b0;
    p_ahit       = 1'b0;
    p_astk       = 1'b0;
    p_sack       = 1'b0;
    p_serr       = 1'b0;
    p_err        = 4'd0;
    p_clst       = 1'b0;
    p_clcnt      = 4'd0;
    p_mstk       = 1'b0;
    p_dayc       = 8'd0;
    p_monic      = 4'd0;
    p_alc        = 8'd0;
    p_tkc        = 8'd0;

    repeat (4) @(negedge ips_clk);
    rst_n = 1'b1;
    drive_cycle(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (rec_stall) begin
            // Trap T2: with clk_en low the whole registered state must hold, every
            // pulse output included, and no field may move.
            if ((year !== p_year)       || (mon !== p_mon)     || (day !== p_day) ||
                (hour !== p_hour)       || (dim !== p_dim)     || (leap !== p_leap) ||
                (tick !== p_tick)       || (alarm_hit !== p_ahit) ||
                (alarm_sticky !== p_astk) || (set_ack !== p_sack) ||
                (set_err !== p_serr)    || (err_count !== p_err) ||
                (clamp_sticky !== p_clst) || (clamp_count !== p_clcnt) ||
                (mon_sticky !== p_mstk)   || (mon_count !== p_monic) ||
                (tick_count !== p_tkc)  || (day_count !== p_dayc) ||
                (alarm_count !== p_alc)) begin
                bad = 1'b1;
            end
        end else begin
            if ((^year === 1'bx) || (^mon === 1'bx)    || (^day === 1'bx) ||
                (^hour === 1'bx) || (^dim === 1'bx)    || (^leap === 1'bx) ||
                (^tick === 1'bx) || (^alarm_hit === 1'bx) ||
                (^alarm_sticky === 1'bx) || (^set_ack === 1'bx) ||
                (^set_err === 1'bx) || (^clamp_sticky === 1'bx) ||
                (^mon_sticky === 1'bx)) begin
                bad = 1'b1;
            end
            if ((^tick_count === 1'bx) || (^day_count === 1'bx) ||
                (^mon_count === 1'bx)  || (^alarm_count === 1'bx) ||
                (^err_count === 1'bx)  || (^clamp_count === 1'bx)) begin
                bad = 1'b1;
            end

            if (day === 6'd0) bad = 1'b1;
            if (mon === 4'd0) bad = 1'b1;
            if (rec_set && (set_ack !== 1'b0) && (tick === 1'b1)) bad = 1'b1;
            if (set_ack === 1'b1 && alarm_hit === 1'b1) bad = 1'b1;
            if (set_err === 1'b1 && set_ack === 1'b1)   bad = 1'b1;

            step_chk = (set_ack !== 1'b1);
            if (step_chk) begin
                if ((day !== p_day) && (day !== (p_day + 6'd1)) &&
                    !((day === 6'd1) && (p_day !== 6'd1))) bad = 1'b1;
                if ((hour !== p_hour) && (hour !== (p_hour + 5'd1)) &&
                    !((hour === 5'd0) && (p_hour !== 5'd0))) bad = 1'b1;
                if ((mon !== p_mon) && (mon !== (p_mon + 4'd1)) &&
                    !((mon === 4'd1) && (p_mon !== 4'd1))) bad = 1'b1;
                // year steps by one, or wraps to 0 at the modulo-400 top.
                if ((year !== p_year) && (year !== (p_year + 9'd1)) &&
                    !((year === 9'd0) && (p_year !== 9'd0))) bad = 1'b1;
                if ((mon !== p_mon) && (day !== 6'd1)) bad = 1'b1;
                if ((year !== p_year) && (mon !== 4'd1)) bad = 1'b1;
                if ((tick === 1'b1) && (hour === p_hour)) bad = 1'b1;
                if ((tick !== 1'b1) && (hour !== p_hour)) bad = 1'b1;
                if ((tick !== 1'b1) && ((day !== p_day) || (mon !== p_mon) ||
                    (year !== p_year) || (dim !== p_dim) || (leap !== p_leap))) begin
                    bad = 1'b1;
                end
                if ((dim !== p_dim) && (mon === p_mon) && (year === p_year)) begin
                    bad = 1'b1;
                end
                if ((day_count !== p_dayc) &&
                    ((day_count !== (p_dayc + 8'd1)) || (hour !== 5'd0))) bad = 1'b1;
                if ((mon_count !== p_monic) &&
                    ((mon_count !== (p_monic + 4'd1)) || (day !== 6'd1))) bad = 1'b1;
                if ((alarm_count !== p_alc) &&
                    ((alarm_count !== (p_alc + 8'd1)) || (alarm_hit !== 1'b1))) begin
                    bad = 1'b1;
                end
                if ((alarm_hit === 1'b1) && (alarm_count === p_alc)) bad = 1'b1;
            end

            if (set_ack === 1'b1) preset_after_hit = 1'b1;
            if (alarm_hit === 1'b1) begin
                if (m_al_en !== 1'b1) bad = 1'b1;
                if (m_al_mask[0] && (hour !== m_al_hour)) bad = 1'b1;
                if (m_al_mask[1] && (day  !== m_al_day))  bad = 1'b1;
                if (m_al_mask[2] && (mon  !== m_al_mon))  bad = 1'b1;
                if (m_al_mask[3] && (year !== m_al_year)) bad = 1'b1;
                // One fire per calendar day.  A legal preset re-bases the day and
                // re-arms the one-shot, which is why it is allowed here.
                if (hit_seen && (day_count === last_hit_day) && !preset_after_hit) begin
                    bad = 1'b1;
                end
                hit_seen         = 1'b1;
                preset_after_hit = 1'b0;
                last_hit_day     = day_count;
            end

            ips_fnv_word({year, mon, day, hour});
            ips_fnv_word({dim, leap, tick, alarm_hit, alarm_sticky, set_ack,
                          set_err, clamp_sticky, mon_sticky, mon_count});
            ips_fnv_word({tick_count, day_count});
            ips_fnv_word({err_count, clamp_count, alarm_count});

            p_year  = year;
            p_mon   = mon;
            p_day   = day;
            p_hour  = hour;
            p_dim   = dim;
            p_leap  = leap;
            p_tick  = tick;
            p_ahit  = alarm_hit;
            p_astk  = alarm_sticky;
            p_sack  = set_ack;
            p_serr  = set_err;
            p_err   = err_count;
            p_clst  = clamp_sticky;
            p_clcnt = clamp_count;
            p_mstk  = mon_sticky;
            p_dayc  = day_count;
            p_monic = mon_count;
            p_alc   = alarm_count;
            p_tkc   = tick_count;
        end

        if (rec_al) begin
            m_al_en   = al_en;
            m_al_mask = al_mask;
            m_al_year = al_year;
            m_al_mon  = al_mon;
            m_al_day  = al_day;
            m_al_hour = al_hour;
        end

        if ((i + 1) < BEATS) begin
            drive_cycle(i + 1);
        end
    end

    repeat (4) @(negedge ips_clk);
    ips_verdict(!bad, "ips_rtc_calendar");
end

endmodule
