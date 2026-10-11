`timescale 1ns / 1ps
// tb_ips_trng_vonng_cond : production-line testbench for the entropy conditioner.
//
// EPISODES conditioning runs are driven against a deterministic, LCG-selected
// stimulus script.  Every run warms up on a strictly alternating entropy pin (so
// the watchdog can never arm), then takes one of four stress shapes: a long frozen
// stretch on level 0, a short frozen stretch, a choppy mix of short freezes and
// alternation, or a long frozen stretch on level 1.  The long stretches must raise
// the stuck alarm, the short and choppy ones must not, and the tail of strictly
// alternating bits proves the alarm is sticky -- it may not fall by itself.  After
// every beat this bench re-checks the accounting identity
//     bit_cnt == 2*(out_bit_cnt + disc_pair_cnt) + pair_pending
// the single-step growth of each counter, that out_bit_cnt only grows when
// out_valid rose, and that nothing moves once the sampling run stops.  The
// conditioned bit stream itself is NOT written here; models/ips_trng_vonng_cond.py
// computes it independently from the published von Neumann contract
// (docs/IP_CORE_SOP.md trap T1).  Only DUT outputs are folded, plus a final
// configuration stamp read out of the DUT instance.
module tb_ips_trng_vonng_cond;

`include "ips_tb_common.vh"

localparam integer EPISODES   = 10;
localparam integer HOLD_LONG  = 90;
localparam integer HOLD_SHORT = 24;
localparam integer TAIL_LEN   = 12;
localparam [31:0]  SEED       = 32'h77AC0E00;

reg                 rst_n;
reg                 clk_en;
reg                 cond_start;
reg                 cond_run;
reg                 src_drv;
reg  [31:0]         state;
reg                 alt;
reg  [11:0]         prev_bit;
reg  [11:0]         prev_out;
reg  [11:0]         prev_disc;
reg  [11:0]         hold_bit;
reg  [11:0]         hold_out;
reg  [11:0]         hold_disc;

wire                out_bit;
wire                out_valid;
wire                stuck_alarm;
wire                pair_pending;
wire [11:0]         out_bit_cnt;
wire [11:0]         disc_pair_cnt;
wire [11:0]         bit_cnt;

// No #() override: the bench exercises the declared default geometry, which is
// the configuration the manifest records and the mutation station checks.
ips_trng_vonng_cond dut (
    .clk           (ips_clk),
    .clk_en        (clk_en),
    .rst_n         (rst_n),
    .cond_start    (cond_start),
    .cond_run      (cond_run),
    .src_bit       (src_drv),
    .out_bit       (out_bit),
    .out_valid     (out_valid),
    .stuck_alarm   (stuck_alarm),
    .pair_pending  (pair_pending),
    .out_bit_cnt   (out_bit_cnt),
    .disc_pair_cnt (disc_pair_cnt),
    .bit_cnt       (bit_cnt)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer e;
integer b;
integer p;
integer kind;
integer wlen;
reg     hold_lvl;
reg     exp_alarm;
reg     prev_alarm;
reg     bad;
reg     obs_x;

wire [15:0] sum_pairs = {4'd0, out_bit_cnt} + {4'd0, disc_pair_cnt};
wire [15:0] acct_bits = (sum_pairs << 1) + {15'd0, pair_pending};
wire [15:0] d_bit     = {4'd0, bit_cnt}       - {4'd0, prev_bit};
wire [15:0] d_out     = {4'd0, out_bit_cnt}   - {4'd0, prev_out};
wire [15:0] d_disc    = {4'd0, disc_pair_cnt} - {4'd0, prev_disc};

function [31:0] next_state;
    input [31:0] s0;
    begin
        next_state = s0 * 32'd1664525 + 32'd1013904223;
    end
endfunction

task beat;
    input start;
    input run;
    input bit_v;
    begin
        @(negedge ips_clk);
        cond_start = start;
        cond_run   = run;
        src_drv    = bit_v;

        @(negedge ips_clk);
        cond_start = 1'b0;
        cond_run   = 1'b0;

        obs_x = (^{out_bit, out_valid, stuck_alarm, pair_pending, out_bit_cnt,
                   disc_pair_cnt, bit_cnt}) === 1'bx;
        if (obs_x) bad = 1'b1;

        // Whole-run accounting: every consumed bit is either emitted, dropped as a
        // rejected pair, or still waiting for its partner.
        if (acct_bits[11:0] !== bit_cnt) bad = 1'b1;

        if (start === 1'b0) begin
            // at most one settled bit, one emitted bit and one discarded pair
            if (d_bit  !== 16'd0 && d_bit  !== 16'd1) bad = 1'b1;
            if (d_out  !== 16'd0 && d_out  !== 16'd1) bad = 1'b1;
            if (d_disc !== 16'd0 && d_disc !== 16'd1) bad = 1'b1;
            // out_bit_cnt moves exactly when a conditioned bit comes out
            if (d_out !== {15'd0, out_valid}) bad = 1'b1;
            // the stuck alarm never falls on its own
            if (prev_alarm === 1'b1 && stuck_alarm !== 1'b1) bad = 1'b1;
        end

        prev_bit   = bit_cnt;
        prev_out   = out_bit_cnt;
        prev_disc  = disc_pair_cnt;
        prev_alarm = stuck_alarm;

        ips_fnv_word({4'd0, bit_cnt});
        ips_fnv_word({4'd0, out_bit_cnt});
        ips_fnv_word({4'd0, disc_pair_cnt});
        ips_fnv_word({28'd0, stuck_alarm, pair_pending, out_valid, out_bit});
    end
endtask

// one phase of strictly alternating entropy bits
task altern;
    input integer len;
    begin
        for (b = 0; b < len; b = b + 1) begin
            alt = ~alt;
            beat(1'b0, 1'b1, alt);
        end
    end
endtask

// one phase of frozen entropy bits
task frozen;
    input integer len;
    input         lvl;
    begin
        for (b = 0; b < len; b = b + 1) begin
            beat(1'b0, 1'b1, lvl);
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n        = 1'b0;
    clk_en       = 1'b0;
    cond_start   = 1'b0;
    cond_run     = 1'b0;
    src_drv      = 1'b0;
    state        = SEED;
    alt          = 1'b0;
    bad          = 1'b0;
    obs_x        = 1'b0;
    prev_alarm   = 1'b0;
    prev_bit     = 12'd0;
    prev_out     = 12'd0;
    prev_disc    = 12'd0;
    hold_bit     = 12'd0;
    hold_out     = 12'd0;
    hold_disc    = 12'd0;
    kind         = 0;
    wlen         = 0;
    hold_lvl     = 1'b0;
    exp_alarm    = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (e = 0; e < EPISODES; e = e + 1) begin
        state = next_state(state);
        kind  = state[1:0];
        wlen  = 12 + state[4:0];

        // restart: counters, pairing state and the sticky alarm all clear
        beat(1'b1, 1'b0, 1'b0);

        altern(wlen);

        case (kind)
            2'd0: begin
                frozen(HOLD_LONG, 1'b0);
                exp_alarm = 1'b1;
            end
            2'd1: begin
                frozen(HOLD_SHORT, 1'b1);
                exp_alarm = 1'b0;
            end
            2'd2: begin
                for (p = 0; p < 2; p = p + 1) begin
                    hold_lvl = (p == 0) ? 1'b0 : 1'b1;
                    frozen(HOLD_SHORT, hold_lvl);
                    altern(wlen);
                end
                exp_alarm = 1'b0;
            end
            default: begin
                frozen(HOLD_LONG, 1'b1);
                exp_alarm = 1'b1;
            end
        endcase

        // sticky proof: the input moves again, the alarm must stay up
        altern(TAIL_LEN);
        if (stuck_alarm !== exp_alarm) bad = 1'b1;
    end

    // drain: no sample is offered, so the synchroniser empties and stops
    repeat (3) beat(1'b0, 1'b0, alt);

    // quiet beat: every register must hold
    hold_bit  = bit_cnt;
    hold_out  = out_bit_cnt;
    hold_disc = disc_pair_cnt;
    beat(1'b0, 1'b0, alt);
    if (bit_cnt !== hold_bit) bad = 1'b1;
    if (out_bit_cnt !== hold_out) bad = 1'b1;
    if (disc_pair_cnt !== hold_disc) bad = 1'b1;

    ips_fnv_word(EPISODES);
    ips_fnv_word(HOLD_LONG);
    ips_fnv_word(dut.CNT_BITS);
    ips_fnv_word(dut.SYNC_STAGES);

    ips_verdict(!bad, "ips_trng_vonng_cond");
end

endmodule
