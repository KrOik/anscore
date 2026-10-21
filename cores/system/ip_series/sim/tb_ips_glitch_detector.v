`timescale 1ns / 1ps
// tb_ips_glitch_detector : production-line testbench for the pulse-width monitor.
//
// FOLDING RULE (mirrored independently by models/ips_glitch_detector.py -- trap T1):
// one FNV-1a word stream, MSB byte first.  Every beat folds, in this order,
//   0 vio_sticky, 1 w_min, 2 w_max, 3 cur_w, 4 cur_rw, 5 pulse_cnt, 6 glitch_cnt,
//   7 div_cnt, 8 gap_cnt, 9 event_flags, 10 sample_state, 11 {width_valid, tick_f}.
// After the beat loop the word BEATS is folded once.  Testbench wires are several
// bits wider than the core's default geometry, so a widened field still reaches the
// digest, and every comparison uses === so X can never look like a pass (trap T6).
//
// BEAT CONTRACT.  One iteration is one clock period, and because the core samples the
// monitored lines on BOTH edges, each period is driven twice: the level that beat n's
// RISING edge must see is applied before that edge, the level that beat n's FALLING
// edge must see is applied one time unit after it.  Every input, clk_en included, is
// therefore stable for the whole half period in which it is sampled, and the falling
// edge of period n really receives the plan's falling-edge level.  Observing happens
// one time unit after the rising edge, so the registered results of beat n are read
// long before any new level is applied.  clk_en is low for two windows (240..252 and
// 256..262) and a clock pulse, a reset pulse and a falling-edge blip are driven inside
// the first one so that a sampler which ignored its clk_en gate could not survive.
// Stimulus is the shared LCG, state = state*1664525 + 1013904223, advanced exactly
// once per beat index, so the golden model can reproduce the stream without this file.
//
// WHAT IS CHECKED.  The testbench carries a shadow of the two-edge sampler and a
// shadow of the reference watchdog that are derived from the written contract, from
// src/ips_glitch_detector.v's header text, and use no numeric geometry of the core:
// every expectation is expressed with the values the core itself reports (its own
// width_valid, its own cur_w, its own init value of w_min), so a widened or retuned
// build is still judged correctly.  Per beat it proves: no X on any folded output; a
// disabled beat moves nothing; sample_state is exactly {prd, sr_n, sr_p, spd, s_n,
// s_p}; rise_f/fall_f/glitch_f/cfg_f follow the sampled pair; the live widths are 1
// after a rise, otherwise +1 or parked at their own maximum, otherwise 0; the sticky
// word is exactly its previous content (cleared on vio_clr) plus this beat's own
// event bits, with no priority stage between the clock and the reset path; while
// width_valid is low no type bit fires and w_min, w_max, pulse_cnt and glitch_cnt do
// not move at all, which is the "configuration error instead of fake widths" rule; and
// the min/max record is exactly the running min/max of the widths the core itself
// reported, forced to 0 by a sub-period event and restarted by meas_clr.
module tb_ips_glitch_detector;

`include "ips_tb_common.vh"

localparam integer BEATS   = 680;
localparam [31:0]  SEED    = 32'h5117C0DE;

// sticky bit values, from the contract text, used only to rebuild the word
localparam [7:0] V_GLITCH = 8'h01, V_SHORT = 8'h02, V_LONG = 8'h04,
                 V_RSTG   = 8'h08, V_CFG   = 8'h10;

reg         rst_n_tb;
reg         clk_en;
reg         mon;
reg         mon_rst;
reg         tick_en;
reg         vio_clr;
reg         meas_clr;

wire [15:0] w_min;
wire [15:0] w_max;
wire [15:0] cur_w;
wire [15:0] cur_rw;
wire [15:0] pulse_cnt;
wire [7:0]  vio_sticky;
wire [3:0]  glitch_cnt;
wire [15:0] div_cnt;
wire [15:0] gap_cnt;
wire        width_valid;
wire        tick_f;
wire [5:0]  sample_state;
wire [7:0]  event_flags;

// No #() override: the core's declared defaults are the shipped configuration and the
// mutation station mutates them, so overriding here would hide them.
ips_glitch_detector dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n_tb),
    .mon         (mon),
    .mon_rst     (mon_rst),
    .tick_en     (tick_en),
    .vio_clr     (vio_clr),
    .meas_clr    (meas_clr),
    .w_min       (w_min),
    .w_max       (w_max),
    .cur_w       (cur_w),
    .cur_rw      (cur_rw),
    .pulse_cnt   (pulse_cnt),
    .vio_sticky  (vio_sticky),
    .glitch_cnt  (glitch_cnt),
    .div_cnt     (div_cnt),
    .gap_cnt     (gap_cnt),
    .width_valid (width_valid),
    .tick_f      (tick_f),
    .sample_state(sample_state),
    .event_flags (event_flags)
);

// one cycle counted per enabled rising edge, as the shared testbench contract asks
always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// ---------------------------------------------------------------------------
// The stimulus plan: rising-edge levels mp/rp, falling-edge levels mn/rn and the
// four control lines, one entry per beat index.
// ---------------------------------------------------------------------------
reg        mp    [0:BEATS + 1];
reg        mn    [0:BEATS + 1];
reg        rp    [0:BEATS + 1];
reg        rn    [0:BEATS + 1];
reg        ckena [0:BEATS + 1];
reg        tkena [0:BEATS + 1];
reg        vclra [0:BEATS + 1];
reg        mclra [0:BEATS + 1];
reg [31:0] lcg   [0:BEATS + 1];
reg [31:0] state;

task clk_run;
    input integer s;
    input integer w;
    integer k;
    begin
        for (k = s; k < s + w; k = k + 1) mp[k] = 1'b1;
    end
endtask

task rst_run;
    input integer s;
    input integer w;
    integer k;
    begin
        for (k = s; k < s + w; k = k + 1) rp[k] = 1'b1;
    end
endtask

task make_plan;
    integer n;
    begin
        for (n = 0; n <= BEATS + 1; n = n + 1) begin
            mp[n]    = 1'b0;
            mn[n]    = 1'b0;
            rp[n]    = 1'b0;
            rn[n]    = 1'b0;
            ckena[n] = 1'b1;
            tkena[n] = 1'b1;
            vclra[n] = 1'b0;
            mclra[n] = 1'b0;
            lcg[n]   = 32'd0;
        end

        // clock-line pulses: conforming, then too narrow, then too wide, then a
        // stuck-high line that must saturate instead of wrapping
        clk_run(12, 4);                      // conforming, sets the min
        clk_run(20, 7);                      // conforming
        clk_run(30, 12);                     // conforming, exactly at MAX_W
        clk_run(54, 1);                      // below MIN_W
        clk_run(60, 2);                      // below MIN_W
        clk_run(66, 3);                      // conforming, exactly at MIN_W
        clk_run(92, 6);                      // conforming, carries a negative blip
        clk_run(116, 13);                    // above MAX_W
        clk_run(134, 20);                    // above MAX_W
        clk_run(178, 2);                     // below MIN_W
        clk_run(200, 1);                     // below MIN_W, completes with the reset
        clk_run(206, 2);                     // below MIN_W
        clk_run(230, 4);                     // first pulse after meas_clr
        clk_run(238, 2);                     // still high when the clock is disabled
        clk_run(245, 2);                     // inside a disabled beat: invisible
        clk_run(320, 1);                     // while the reference is stale
        clk_run(326, 12);                    // completes while the reference is stale
        clk_run(360, 300);                   // saturates cur_w and pulse reporting

        // reset-line pulses
        rst_run(144, 2);                     // below MIN_W -> V_RSTG
        rst_run(152, 6);                     // conforming
        rst_run(160, 14);                    // above MAX_W -> V_RSTG
        rst_run(187, 14);                    // above MAX_W, completes with the clock
        rst_run(238, 2);                     // still high when the clock is disabled
        rst_run(246, 3);                     // inside a disabled beat: invisible
        rst_run(322, 2);                     // while the reference is stale
        rst_run(330, 8);                     // completes while the reference is stale

        // disabled windows and the reference outage
        for (n = 240; n <= 252; n = n + 1) ckena[n] = 1'b0;
        for (n = 256; n <= 262; n = n + 1) ckena[n] = 1'b0;
        for (n = 310; n <= 339; n = n + 1) tkena[n] = 1'b0;

        // sticky read/clear sequence and the measurement restart
        vclra[201] = 1'b1;
        vclra[214] = 1'b1;
        vclra[660] = 1'b1;
        mclra[226] = 1'b1;

        // one LCG advance per beat index; the tail regions take their levels from it
        state = SEED;
        for (n = 0; n <= BEATS; n = n + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            lcg[n] = state;
            if (((n >= 339) && (n <= 357)) || ((n >= 661) && (n < BEATS))) begin
                mp[n] = mp[n] | ((lcg[n] >> 21) & 32'd1);
            end
        end
        for (n = 661; n < BEATS; n = n + 1) begin
            rp[n] = rp[n] | ((lcg[n] >> 17) & 32'd1);
        end

        // the falling-edge level equals the rising-edge one except where the plan
        // deliberately puts mid-period activity on a line
        for (n = 0; n <= BEATS; n = n + 1) begin
            mn[n] = mp[n];
            rn[n] = rp[n];
        end
        mn[84]  = ~mp[84];    // ultra-short pulse: covers no rising edge at all
        mn[94]  = ~mp[94];    // negative blip inside a conforming run
        mn[100] = ~mp[100];   // ultra-short pulse again
        mn[248] = ~mp[248];   // same blip inside a disabled beat: must stay invisible
        rn[352] = ~rp[352];   // ultra-short pulse on the reset line
        for (n = 661; n < BEATS; n = n + 1) begin
            mn[n] = mn[n] ^ ((lcg[n] >> 9) & 32'd1);
            rn[n] = rn[n] ^ ((lcg[n] >> 5) & 32'd1);
        end
    end
endtask

task beat_apply;
    input integer n;
    begin
        mon      = mp[n];
        mon_rst  = rp[n];
        clk_en   = ckena[n];
        tick_en  = tkena[n];
        vio_clr  = vclra[n];
        meas_clr = mclra[n];
    end
endtask

task mid_apply;
    input integer n;
    begin
        mon     = mn[n];
        mon_rst = rn[n];
    end
endtask

// ---------------------------------------------------------------------------
// shadow of the sampler and of the record, plus per-beat expectations
// ---------------------------------------------------------------------------
reg         bad;
integer     i;
reg         t_sp, t_sn, t_spd;
reg         t_rp, t_rn, t_prd;
reg         exp_rise, exp_fall, exp_rrise, exp_rfall;
reg         exp_glk, exp_rglk, exp_sub, exp_gclk, exp_cfg;
reg  [15:0] exp_wmn, exp_wmx, exp_pc, init_min_ref;
reg  [3:0]  exp_gc;
reg  [7:0]  exp_vio;
reg  [15:0] pv_wmin, pv_wmax, pv_curw, pv_currw, pv_pc;
reg  [3:0]  pv_gc;
reg  [7:0]  pv_vio;
reg  [15:0] pv_div, pv_gap;
reg  [7:0]  pv_ef;
reg  [5:0]  pv_ss;
reg         pv_vld, pv_tickf;
reg  [15:0] rec_min313, rec_max313, rec_pc313;
reg  [3:0]  rec_gc313;

initial begin
    ips_fnv_reset;
    bad = 1'b0;

    rst_n_tb = 1'b0;
    clk_en   = 1'b0;
    mon      = 1'b0;
    mon_rst  = 1'b0;
    tick_en  = 1'b0;
    vio_clr  = 1'b0;
    meas_clr = 1'b0;

    t_sp = 1'b0;  t_sn = 1'b0;  t_spd = 1'b0;
    t_rp = 1'b0;  t_rn = 1'b0;  t_prd = 1'b0;

    make_plan();

    // asynchronous reset holds every register at its stated reset value
    #3;
    init_min_ref = w_min;
    pv_wmin = w_min; pv_wmax = w_max; pv_curw = cur_w; pv_currw = cur_rw;
    pv_pc   = pulse_cnt; pv_gc = glitch_cnt; pv_vio = vio_sticky;
    pv_div  = div_cnt;   pv_gap = gap_cnt;  pv_ef = event_flags;
    pv_ss   = sample_state; pv_vld = width_valid; pv_tickf = tick_f;

    // the reset values themselves are part of the contract
    if (w_max !== 16'd0 || cur_w !== 16'd0 || cur_rw !== 16'd0 ||
        pulse_cnt !== 16'd0 || glitch_cnt !== 4'd0 || vio_sticky !== 8'd0 ||
        event_flags !== 8'd0 || sample_state !== 6'd0 ||
        width_valid !== 1'b0 || tick_f !== 1'b0) begin
        bad = 1'b1;
    end
    rst_n_tb = 1'b1;
    beat_apply(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(posedge ips_clk);
        #1;

        // ---- purity: nothing folded may be unknown -----------------------
        if (^{vio_sticky, w_min, w_max, cur_w, cur_rw, pulse_cnt, glitch_cnt,
              div_cnt, gap_cnt, event_flags, sample_state,
              width_valid, tick_f} === 1'bx) begin
            bad = 1'b1;
        end

        // ---- the sampler shadow is what the core must have stored --------
        exp_rise  = t_sp  & ~t_spd;
        exp_fall  = ~t_sp & t_spd;
        exp_rrise = t_rp  & ~t_prd;
        exp_rfall = ~t_rp & t_prd;
        exp_glk   = t_sp  ^ t_sn;
        exp_rglk  = t_rp  ^ t_rn;
        exp_gclk  = exp_glk & width_valid;
        exp_sub   = (exp_glk | exp_rglk) & width_valid;
        exp_cfg   = ~width_valid & (t_sp | t_rp | exp_glk | exp_rglk |
                                    exp_fall | exp_rfall);

        // ---- a disabled beat must not move one register ------------------
        // (sample_state and event_flags are snapshots of the pair the core evaluated,
        // so on a disabled beat they legitimately lag the sampler flip-flops by one
        // period; the equality that matters there is the frozen-output check below)
        if (clk_en === 1'b0) begin
            if (vio_sticky !== pv_vio || w_min !== pv_wmin || w_max !== pv_wmax ||
                cur_w !== pv_curw || cur_rw !== pv_currw || pulse_cnt !== pv_pc ||
                glitch_cnt !== pv_gc || div_cnt !== pv_div || gap_cnt !== pv_gap ||
                event_flags !== pv_ef || sample_state !== pv_ss ||
                width_valid !== pv_vld || tick_f !== pv_tickf) begin
                bad = 1'b1;
            end
        end else begin
            // ---- the sampler shadow is what the core must have stored -------
            if (sample_state !== {t_prd, t_rn, t_rp, t_spd, t_sn, t_sp}) bad = 1'b1;
            if (event_flags[2:0] !== {exp_gclk, exp_fall, exp_rise}) bad = 1'b1;
            if (event_flags[6]   !== exp_cfg)     bad = 1'b1;
            if (event_flags[7]   !== width_valid) bad = 1'b1;

            // ---- reference watchdog: divider and gap counter --------------
            if (tick_en === 1'b0) begin
                if (div_cnt !== 16'd0) bad = 1'b1;
            end else if (tick_f === 1'b1) begin
                if (div_cnt !== 16'd0 || gap_cnt !== 16'd0) bad = 1'b1;
            end else begin
                if (div_cnt !== pv_div + 16'd1) bad = 1'b1;
                if (gap_cnt !== pv_gap + 16'd1) begin
                    if (gap_cnt !== pv_gap || width_valid !== 1'b0) bad = 1'b1;
                end
            end

            // ---- live widths: 1 after a rise, else +1 or parked, else 0 ---
            if (exp_rise) begin
                if (cur_w !== 16'd1) bad = 1'b1;
            end else if (t_sp) begin
                if (cur_w !== pv_curw && cur_w !== pv_curw + 16'd1) bad = 1'b1;
            end else begin
                if (cur_w !== 16'd0) bad = 1'b1;
            end
            if (exp_rrise) begin
                if (cur_rw !== 16'd1) bad = 1'b1;
            end else if (t_rp) begin
                if (cur_rw !== pv_currw && cur_rw !== pv_currw + 16'd1) bad = 1'b1;
            end else begin
                if (cur_rw !== 16'd0) bad = 1'b1;
            end

            // ---- the sticky word is its old content plus this beat's bits,
            // ---- cleared first, with no priority between the two lines ----
            exp_vio = (vio_clr === 1'b1) ? 8'd0 : pv_vio;
            if (event_flags[2] === 1'b1) exp_vio = exp_vio | V_GLITCH;
            if (event_flags[3] === 1'b1) exp_vio = exp_vio | V_SHORT;
            if (event_flags[4] === 1'b1) exp_vio = exp_vio | V_LONG;
            if (event_flags[5] === 1'b1) exp_vio = exp_vio | V_RSTG;
            if (event_flags[6] === 1'b1) exp_vio = exp_vio | V_CFG;
            if (vio_sticky !== exp_vio) bad = 1'b1;

            // ---- no reporting at all while the reference is stale --------
            if (width_valid === 1'b0 && event_flags[5:2] !== 4'b0000) bad = 1'b1;

            // ---- min/max record: exactly the widths the core reported -----
            exp_wmn = (meas_clr === 1'b1) ? init_min_ref : pv_wmin;
            exp_wmx = (meas_clr === 1'b1) ? 16'd0        : pv_wmax;
            exp_pc  = (meas_clr === 1'b1) ? 16'd0        : pv_pc;
            exp_gc  = (meas_clr === 1'b1) ? 4'd0         : pv_gc;
            if (event_flags[1] === 1'b1 && width_valid === 1'b1) begin
                if (pv_curw < exp_wmn) exp_wmn = pv_curw;
                if (pv_curw > exp_wmx) exp_wmx = pv_curw;
                exp_pc = exp_pc + 16'd1;
            end
            if (exp_rfall && width_valid === 1'b1) begin
                if (pv_currw < exp_wmn) exp_wmn = pv_currw;
                if (pv_currw > exp_wmx) exp_wmx = pv_currw;
            end
            if (exp_sub) exp_wmn = 16'd0;
            if (exp_sub && !(pv_gc === 4'hF && meas_clr === 1'b0)) begin
                exp_gc = exp_gc + 4'd1;
            end
            if (w_min !== exp_wmn || w_max !== exp_wmx) bad = 1'b1;
            if (pulse_cnt !== exp_pc) bad = 1'b1;
            if (glitch_cnt !== exp_gc) bad = 1'b1;
        end

        // ---- scripted checkpoints ----------------------------------------
        // before the first tick: nothing is measured, nothing is flagged
        if (i == 5 && (width_valid !== 1'b0 || vio_sticky !== 8'd0 ||
                       w_min !== init_min_ref || pulse_cnt !== 16'd0)) bad = 1'b1;
        // the reference is up and the first three pulses are conforming
        if (i == 12 && width_valid !== 1'b1) bad = 1'b1;
        if (i == 45 && (vio_sticky !== 8'd0 || w_min !== 16'd4 ||
                        w_max !== 16'd12 || pulse_cnt !== 16'd3 ||
                        glitch_cnt !== 4'd0)) bad = 1'b1;
        // a pulse exactly MAX_W wide and one exactly MIN_W wide are conforming: no
        // type bit may fire for them, and the record still sees the width
        if (i == 43 && event_flags !== 8'h82) bad = 1'b1;
        if (i == 70 && (event_flags !== 8'h82 || vio_sticky !== V_SHORT ||
                        w_min !== 16'd1 || w_max !== 16'd12 || pulse_cnt !== 16'd6 ||
                        glitch_cnt !== 4'd0)) bad = 1'b1;
        // a below-MIN_W pulse is reported and lowers the record
        if (i == 56 && (vio_sticky & V_SHORT) !== V_SHORT) bad = 1'b1;
        // the ultra-short pulse at period 84 covers no rising edge: the core caught
        // it only because s_n disagreed with s_p, and it is recorded as width 0
        if (i == 85 && (event_flags[2] !== 1'b1 || vio_sticky !== 8'h03 ||
                        sample_state[1:0] !== 2'b10 || w_min !== 16'd0 ||
                        glitch_cnt !== 4'd1 || cur_w !== 16'd0)) bad = 1'b1;
        // a negative blip inside a conforming run is a glitch, not a short pulse
        if (i == 95 && (event_flags[2] !== 1'b1 || sample_state[1:0] !== 2'b01 ||
                        glitch_cnt !== 4'd2)) bad = 1'b1;
        // three sub-period events so far: the record minimum is 0 and they stepped
        if (i == 105 && (vio_sticky !== 8'h03 || w_min !== 16'd0 || w_max !== 16'd12 ||
                         pulse_cnt !== 16'd7 || glitch_cnt !== 4'd3)) bad = 1'b1;
        // an above-MAX_W clock pulse latches V_LONG and raises the maximum
        if (i == 130) begin
            if ((vio_sticky & V_LONG) !== V_LONG || w_max !== 16'd13) bad = 1'b1;
        end
        // the reset line reports through its own bit, its width joins the record
        if (i == 147 && ((vio_sticky & V_RSTG) !== V_RSTG || w_max !== 16'd13 ||
                         pulse_cnt !== 16'd8)) bad = 1'b1;
        // a 20-period clock pulse: fall_f together with long_f and nothing else
        if (i == 155 && (event_flags !== 8'h92 || w_max !== 16'd20 ||
                         pulse_cnt !== 16'd9 || w_min !== 16'd0 ||
                         glitch_cnt !== 4'd3)) bad = 1'b1;
        if (i == 201 && vio_sticky !== 8'd0) bad = 1'b1;
        // simultaneous clock-line and reset-line violation: both bits, same beat,
        // neither one masking the other, and the clear on the beat before was real
        if (i == 202 && (vio_sticky !== 8'h0A || event_flags[3] !== 1'b1 ||
                         event_flags[5] !== 1'b1 || pulse_cnt !== 16'd11 ||
                         glitch_cnt !== 4'd3 || w_min !== 16'd0 || w_max !== 16'd20))
            bad = 1'b1;
        if (i == 214 && vio_sticky !== 8'd0) bad = 1'b1;
        // meas_clr restarts the record
        if (i == 227 && (w_min !== init_min_ref || w_max !== 16'd0 ||
                         pulse_cnt !== 16'd0 || glitch_cnt !== 4'd0 ||
                         vio_sticky !== 8'd0)) bad = 1'b1;
        if (i == 235 && (w_min !== 16'd4 || w_max !== 16'd4 || pulse_cnt !== 16'd1 ||
                         vio_sticky !== 8'd0)) bad = 1'b1;
        // the samplers are frozen as well: at the first enabled beat after the window
        // the core still holds the pair sampled BEFORE the clock was disabled, so the
        // pulse is completed there and measured in enabled reference periods only
        if (i == 253 && (sample_state !== 6'h3F || cur_w !== 16'd2 ||
                         cur_rw !== 16'd2 || event_flags[1] !== 1'b0 ||
                         event_flags[2] !== 1'b0)) bad = 1'b1;
        if (i == 254 && (vio_sticky !== 8'h0A || w_min !== 16'd2 || w_max !== 16'd4 ||
                         pulse_cnt !== 16'd2 || glitch_cnt !== 4'd0)) bad = 1'b1;
        // the pulses and the blip driven inside the disabled window stayed invisible
        if (i == 255 && (vio_sticky !== 8'h0A || w_min !== 16'd2 || w_max !== 16'd4 ||
                         pulse_cnt !== 16'd2 || glitch_cnt !== 4'd0 ||
                         cur_w !== 16'd0 || cur_rw !== 16'd0)) bad = 1'b1;
        // reference outage: nothing is reported, only the configuration error appears
        if (i == 313) begin
            rec_min313 = w_min; rec_max313 = w_max;
            rec_pc313  = pulse_cnt; rec_gc313 = glitch_cnt;
        end
        if (i == 320 && (vio_sticky & V_CFG) !== 8'd0) bad = 1'b1;
        if (i == 321 && (vio_sticky & V_CFG) !== V_CFG) bad = 1'b1;
        if (i == 339 && (w_min !== rec_min313 || w_max !== rec_max313 ||
                         pulse_cnt !== rec_pc313 || glitch_cnt !== rec_gc313 ||
                         (vio_sticky & V_CFG) !== V_CFG ||
                         width_valid !== 1'b0 || event_flags[5:2] !== 4'b0000))
            bad = 1'b1;
        // the reference comes back with the next tick and measurement resumes
        if (i == 348 && width_valid !== 1'b1) bad = 1'b1;
        // an ultra-short pulse on the reset line is a glitch on that line
        if (i == 353 && (event_flags[5] !== 1'b1 || w_min !== 16'd0 ||
                         (vio_sticky & V_RSTG) !== V_RSTG ||
                         sample_state[4:3] !== 2'b10)) bad = 1'b1;
        // the stuck-high line ended: its saturated width is the new maximum and the
        // clear on the beat before had really emptied the word
        if (i == 660 && vio_sticky !== 8'd0) bad = 1'b1;
        if (i == 661 && (vio_sticky !== V_LONG || event_flags[4] !== 1'b1 ||
                         event_flags[1] !== 1'b1 || cur_w !== 16'd0 ||
                         w_max !== pv_curw)) bad = 1'b1;

        // ---- fold --------------------------------------------------------
        ips_fnv_word({24'd0, vio_sticky});
        ips_fnv_word({16'd0, w_min});
        ips_fnv_word({16'd0, w_max});
        ips_fnv_word({16'd0, cur_w});
        ips_fnv_word({16'd0, cur_rw});
        ips_fnv_word({16'd0, pulse_cnt});
        ips_fnv_word({28'd0, glitch_cnt});
        ips_fnv_word({16'd0, div_cnt});
        ips_fnv_word({16'd0, gap_cnt});
        ips_fnv_word({24'd0, event_flags});
        ips_fnv_word({26'd0, sample_state});
        ips_fnv_word({30'd0, width_valid, tick_f});

        // ---- snapshot and advance the sampler shadow ---------------------
        pv_wmin = w_min;  pv_wmax = w_max;  pv_curw = cur_w;  pv_currw = cur_rw;
        pv_pc   = pulse_cnt; pv_gc = glitch_cnt; pv_vio = vio_sticky;
        pv_div  = div_cnt;  pv_gap = gap_cnt;   pv_ef = event_flags;
        pv_ss   = sample_state; pv_vld = width_valid; pv_tickf = tick_f;

        if (clk_en === 1'b1) begin
            t_spd = t_sp;  t_sp = mp[i];
            t_prd = t_rp;  t_rp = rp[i];
            t_sn  = mn[i];
            t_rn  = rn[i];
        end

        mid_apply(i);
        @(negedge ips_clk);
        #1;
        beat_apply(i + 1);
    end

    clk_en   = 1'b0;
    mon      = 1'b0;
    mon_rst  = 1'b0;
    tick_en  = 1'b0;
    vio_clr  = 1'b0;
    meas_clr = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_glitch_detector");
end

endmodule
