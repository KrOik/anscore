`timescale 1ns / 1ps
// ips_glitch_detector : clock and reset pulse-width (glitch) monitor with a sticky
// violation word, an observed min/max width record, and a divide-by reference tick
// whose absence is itself reported as a configuration error.
//
// WRITTEN CONTRACT.  src/ips_glitch_detector.v and models/ips_glitch_detector.py are
// both derived from this text.  Neither is back-filled from simulation output
// (docs/IP_CORE_SOP.md trap T1) and every register is gated by clk_en with rst_n as
// the active-low asynchronous reset (trap T2).
//
// Units.  One reference period is one enabled beat of the reference clock.  Pulse
// widths are counted in reference periods by cur_w (monitored line) and cur_rw
// (reset line) and compared against the limits MIN_W and MAX_W.
//
// Honest sub-period capture.  The monitored line is sampled on BOTH edges of the
// reference clock: s_p on the rising edge, s_n on the falling edge, each half gated by
// clk_en.  A pulse that opens and closes strictly inside one reference period covers
// neither of that period's rising edges, so a rising-edge-only sampler cannot report
// it at all.  The falling-edge sample sits in the middle of the period, so any such
// pulse that covers it leaves s_n disagreeing with s_p.  That disagreement IS the
// capture: glitch_f pulses, the sticky V_GLITCH bit latches, glitch_cnt steps,
// and the event is recorded with width zero -- the core's way of saying "narrower
// than one reference period" -- so w_min falls to zero and the event can never be
// mistaken for a conforming pulse, because a conforming pulse is at least MIN_W
// periods wide.  A negative blip inside an otherwise high run is caught by the same
// disagreement and is counted as a glitch even though the rising-edge run continues.
// The resolution this buys is half a reference period: every pulse that covers at
// least one of the two sample instants of its period is caught, which is strictly more
// than a single-edge sampler sees, and no two-sample-per-period monitor can do better.
// glitch_cnt steps on a sub-period event on EITHER line (clock or reset), since in
// both cases the true width is narrower than one reference period; the sticky V_GLITCH
// bit and the glitch_f flag are the clock-line ones only.
//
// Pulse classification (rising-edge domain).  A pulse is a maximal run of reference
// periods with s_p high; it completes on fall_f and its width is the run length held
// by cur_w.  Width < MIN_W latches V_SHORT, width > MAX_W latches the stuck/long
// violation V_LONG, every reported completed CLOCK-line pulse steps pulse_cnt (a
// reset-line completion joins the record but does not count as a pulse), and the
// ever-seen record updates as w_min = min(w_min, width), w_max = max(w_max, width).
// Both width counters saturate at all ones and never wrap, so a stuck-high line parks
// at the maximum width instead of faking a short one.
//
// Reset-glitch input.  mon_rst runs through the identical dual-edge sampler, its own
// width counter and the same limits.  Any reset-line violation -- sub-period, too
// narrow or too wide -- latches V_RSTG and nothing else, so the two paths share no
// priority stage: a clock-line and a reset-line violation completing on the same beat
// set their own bits together.  Reset-line widths join the shared ever-seen record,
// because a measured reset pulse really was that wide.
//
// Reference tick.  div_cnt counts enabled beats and produces one tick every DIV_N+1
// of them while tick_en is high; disabling the generator parks the divider and stops
// the ticks.  gap_cnt counts enabled beats since the last tick and saturates, and
// width_valid is high only while the reference is fresh (gap_cnt within GAP_LIM).
// While it is low the core reports no width at all: w_min, w_max, pulse_cnt and
// glitch_cnt hold, the type bits (glitch_f, short_f, long_f, rst_f) stay clear and a
// pulse that completes while the reference is stale is not counted and not recorded,
// so no fake width can appear; the live counters cur_w and cur_rw keep tracking the
// two lines and the only new evidence is V_CFG, latched when monitored activity shows
// up with no usable reference.  A missing reference therefore yields a configuration
// error instead of fake widths, and width_valid returns with the next tick.
//
// Clears.  vio_clr empties the sticky violation word and meas_clr restarts the record
// (w_min to all ones, w_max to zero, pulse_cnt and glitch_cnt to zero); both are
// applied before that beat's events are latched, so a violation arriving on the same
// beat as vio_clr is still recorded.  Neither clear touches the live width counters or
// the reference watchdog.
//
// event_flags, most significant bit first:
//   ref_fresh, cfg_f, rst_f, long_f, short_f, glitch_f, fall_f, rise_f
// sample_state, most significant bit first:
//   prd, sr_n, sr_p, spd, s_n, s_p
module ips_glitch_detector #(
    parameter W_W     = 8,
    parameter DIV_N   = 6,
    parameter MIN_W   = 3,
    parameter MAX_W   = 12,
    parameter GAP_LIM = 7
)(
    input  wire              clk,
    input  wire              clk_en,
    input  wire              rst_n,

    input  wire              mon,
    input  wire              mon_rst,
    input  wire              tick_en,
    input  wire              vio_clr,
    input  wire              meas_clr,

    output reg  [W_W-1:0]    w_min,
    output reg  [W_W-1:0]    w_max,
    output reg  [W_W-1:0]    cur_w,
    output reg  [W_W-1:0]    cur_rw,
    output reg  [W_W-1:0]    pulse_cnt,
    output reg  [7:0]        vio_sticky,
    output reg  [3:0]        glitch_cnt,
    output reg  [DIV_N:0]    div_cnt,
    output reg  [GAP_LIM:0]  gap_cnt,
    output reg               width_valid,
    output reg               tick_f,
    output reg  [5:0]        sample_state,
    output reg  [7:0]        event_flags
);

localparam [7:0] V_GLITCH = 8'h01, V_SHORT = 8'h02, V_LONG = 8'h04, V_RSTG = 8'h08, V_CFG = 8'h10;

localparam [W_W-1:0] MIN_LIM = MIN_W;
localparam [W_W-1:0] MAX_LIM = MAX_W;

reg             s_p;
reg             s_n;
reg             sr_p;
reg             sr_n;
reg             spd;
reg             prd;
reg [W_W-1:0]   pcx;
reg [3:0]       gcx;
reg [W_W-1:0]   wmn;
reg [W_W-1:0]   wmx;

// ---------------------------------------------------------------------------
// dual-edge samplers.  Both halves are clk_en-gated, so a disabled beat freezes
// the rising and the falling sample together.
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_p  <= 1'b0;
        spd  <= 1'b0;
        sr_p <= 1'b0;
        prd  <= 1'b0;
    end else if (clk_en) begin
        s_p  <= mon;
        spd  <= s_p;
        sr_p <= mon_rst;
        prd  <= sr_p;
    end
end

always @(negedge clk or negedge rst_n) begin
    if (!rst_n) begin
        s_n  <= 1'b0;
        sr_n <= 1'b0;
    end else if (clk_en) begin
        s_n  <= mon;
        sr_n <= mon_rst;
    end
end

// ---------------------------------------------------------------------------
// what the just-finished reference period says.  s_p and s_n here are the pair
// belonging to that period, which is what makes a sub-period pulse visible.
// ---------------------------------------------------------------------------
wire glitch_now  = (s_p != s_n);
wire rglitch_now = (sr_p != sr_n);

wire rise_now  = s_p  & ~spd;
wire fall_now  = ~s_p & spd;
wire rrise_now = sr_p & ~prd;
wire rfall_now = ~sr_p & prd;

wire tick_now = tick_en & (div_cnt == DIV_N);

wire [GAP_LIM:0] gap_nx = tick_now ? {((GAP_LIM + 1)){1'b0}}
                                   : ((&gap_cnt) ? gap_cnt : (gap_cnt + 1'b1));

wire ref_fresh  = (gap_nx <= GAP_LIM);
wire measure_ok = ref_fresh;

wire [W_W-1:0] done_w  = cur_w;
wire [W_W-1:0] done_rw = cur_rw;

wire gclk_now  = glitch_now  & measure_ok;
wire sub_now   = (glitch_now | rglitch_now) & measure_ok;
wire short_now = fall_now    & measure_ok & (done_w < MIN_LIM);
wire long_now  = fall_now    & measure_ok & (done_w > MAX_LIM);
wire rst_now   = measure_ok & (rglitch_now
                    | (rfall_now & ((done_rw < MIN_LIM) | (done_rw > MAX_LIM))));
wire cfg_now   = ~ref_fresh & (s_p | sr_p | glitch_now | rglitch_now
                               | fall_now | rfall_now);

// ---------------------------------------------------------------------------
// record, live widths, sticky violations, reference watchdog
// ---------------------------------------------------------------------------
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        w_min        <= {(W_W){1'b1}};
        w_max        <= {(W_W){1'b0}};
        cur_w        <= {(W_W){1'b0}};
        cur_rw       <= {(W_W){1'b0}};
        pulse_cnt    <= {(W_W){1'b0}};
        glitch_cnt   <= {(4){1'b0}};
        vio_sticky   <= {(8){1'b0}};
        div_cnt      <= {(DIV_N + 1){1'b0}};
        gap_cnt      <= {(GAP_LIM + 1){1'b1}};
        width_valid  <= 1'b0;
        tick_f       <= 1'b0;
        sample_state <= {(6){1'b0}};
        event_flags  <= {(8){1'b0}};
    end else if (clk_en) begin
        // the clears are applied first, then this beat's widths fold in
        wmn = meas_clr ? {(W_W){1'b1}} : w_min;
        wmx = meas_clr ? {(W_W){1'b0}} : w_max;
        pcx = meas_clr ? {(W_W){1'b0}} : pulse_cnt;
        gcx = meas_clr ? {(4){1'b0}}   : glitch_cnt;

        if (fall_now & measure_ok) begin
            if (done_w < wmn) wmn = done_w;
            if (done_w > wmx) wmx = done_w;
            if (!(&pcx)) pcx = pcx + 1'b1;
        end
        if (rfall_now & measure_ok) begin
            if (done_rw < wmn) wmn = done_rw;
            if (done_rw > wmx) wmx = done_rw;
        end
        if (sub_now) begin
            wmn = {(W_W){1'b0}};
            if (!(&gcx)) gcx = gcx + 4'h1;
        end

        w_min      <= wmn;
        w_max      <= wmx;
        pulse_cnt  <= pcx;
        glitch_cnt <= gcx;

        // live widths, saturating and never wrapping
        if (rise_now) begin
            cur_w <= {{(W_W - 1){1'b0}}, 1'b1};
        end else if (s_p) begin
            if (!(&cur_w)) cur_w <= cur_w + 1'b1;
        end else begin
            cur_w <= {(W_W){1'b0}};
        end
        if (rrise_now) begin
            cur_rw <= {{(W_W - 1){1'b0}}, 1'b1};
        end else if (sr_p) begin
            if (!(&cur_rw)) cur_rw <= cur_rw + 1'b1;
        end else begin
            cur_rw <= {(W_W){1'b0}};
        end

        // sticky violation word: cleared first, then this beat's events latch
        vio_sticky <= (vio_clr ? {(8){1'b0}} : vio_sticky)
                      | (gclk_now  ? V_GLITCH : {(8){1'b0}})
                      | (short_now ? V_SHORT  : {(8){1'b0}})
                      | (long_now  ? V_LONG   : {(8){1'b0}})
                      | (rst_now   ? V_RSTG   : {(8){1'b0}})
                      | (cfg_now   ? V_CFG    : {(8){1'b0}});

        // reference tick generator and its watchdog
        if (!tick_en || tick_now) begin
            div_cnt <= {(DIV_N + 1){1'b0}};
        end else begin
            div_cnt <= div_cnt + 1'b1;
        end
        gap_cnt     <= gap_nx;
        width_valid <= ref_fresh;
        tick_f      <= tick_now;

        sample_state <= {prd, sr_n, sr_p, spd, s_n, s_p};
        event_flags  <= {ref_fresh, cfg_now, rst_now, long_now, short_now,
                         gclk_now, fall_now, rise_now};
    end
end

endmodule
