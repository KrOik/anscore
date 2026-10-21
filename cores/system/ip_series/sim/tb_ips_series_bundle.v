`timescale 1ns / 1ps
// tb_ips_series_bundle : production-line integration bench for the packaged
// ip_series_20k wrappers.
//
// What this proves and what it does not:
//   - every gw2a_ips_<name> wrapper delivered under ip/<name>/ instantiates in a
//     single design unit and its port passthrough is drivable, which the per-core
//     gate only checks by standalone elaboration;
//   - the composed system is X-free and error-free on every shipped-crossing
//     invariant for the whole run (no fifo over/underflow, no CDC protocol errors,
//     no packer or RAM errors) while data actually flows (liveness counters);
//   - the bundle honours clk_en gating, so a series-level integration does not
//     depend on the core ignoring its enable;
//   - it does NOT re-prove per-core functional equivalence: that is the golden
//     model station's job, and no Python model is required here because the
//     bundle is a coherence harness, not a portfolio core.
// The fold order below is the bundle observation contract; it is not shared with a
// model, only with the run log, and any change to it changes the recorded digest.
module tb_ips_series_bundle;

`include "ips_tb_common.vh"

localparam integer BEATS = 1400;

reg       rst_n;
reg       clk_en;
reg [7:0] gate_hold;
reg [7:0] gate_beat;

wire signed [15:0] add_y;
wire               add_sat_pos;
wire               add_sat_neg;
wire [1:0]         add_headroom;
wire [7:0]         add_clip_count;
wire               chain_sample;
wire [7:0]         tap_data;
wire               tap_valid;
wire               tap_ready;
wire [7:0]         tap_beats;
wire [7:0]         tap_drops;
wire               tap_drop_sticky;
wire [7:0]         fifo_rdata;
wire [4:0]         fifo_level;
wire               fifo_full;
wire               fifo_empty;
wire [3:0]         fifo_ov;
wire [3:0]         fifo_uf;
wire [7:0]         pkt_word;
wire               pkt_valid;
wire               pkt_last;
wire               pkt_ready;
wire [4:0]         pkt_resid;
wire [7:0]         pkt_fields;
wire [7:0]         pkt_words;
wire [1:0]         pkt_err;
wire [5:0]         pkt_sat;
wire [11:0]        cdc_data;
wire [11:0]        cdc_dst_data;
wire               cdc_dst_valid;
wire               cdc_pend;
wire               cdc_outstanding;
wire [3:0]         cdc_tx;
wire [3:0]         cdc_rx;
wire [3:0]         cdc_err;
wire               cdc_err_sticky;
wire [31:0]        irq_pin_out;
wire [15:0]        irq_pend;
wire [31:0]        irq_rdata;
wire [3:0]         irq_vec;
wire               irq_active;
wire               irq_storm;
wire               irq_acked;
wire               irq_level_any;
wire               trng_bit;
wire               trng_valid;
wire               trng_stuck;
wire               trng_pair;
wire [11:0]        trng_out_cnt;
wire [11:0]        trng_disc_cnt;
wire               i2s_sclk;
wire               i2s_lrclk;
wire               i2s_sd;
wire               i2s_fresh_l;
wire               i2s_fresh_r;
wire [7:0]         i2s_words;
wire [7:0]         i2s_under;
wire               i2s_under_sticky;
wire [11:0]        sm_rmax;
wire [12:0]        sm_rsum;
wire [7:0]         sm_p;
wire               sm_pvld;
wire               sm_sat;
wire [7:0]         sm_clip;
wire [31:0]        sm_cfg;
wire [7:0]         ewma_y;
wire [7:0]         ewma_mean;
wire               ewma_valid;
wire               ewma_busy;
wire               ewma_stall;
wire [2:0]         ewma_stage;
wire [31:0]        ram_rdata;
wire [7:0]         ram_hits;
wire [7:0]         ram_guard;
wire               ram_error;
wire [15:0]        gen_beats;
wire [31:0]        gen_lfsr;
wire [15:0]        cnt_produced;
wire [15:0]        cnt_accepted;
wire [15:0]        cnt_written;
wire [15:0]        cnt_pops;
wire [15:0]        cnt_packed;
wire [15:0]        cnt_dropped;

ips_series_bundle dut (
    .clk             (ips_clk),
    .clk_en          (clk_en),
    .rst_n           (rst_n),
    .add_y           (add_y),
    .add_sat_pos     (add_sat_pos),
    .add_sat_neg     (add_sat_neg),
    .add_headroom    (add_headroom),
    .add_clip_count  (add_clip_count),
    .chain_sample    (chain_sample),
    .tap_data        (tap_data),
    .tap_valid       (tap_valid),
    .tap_ready       (tap_ready),
    .tap_beats       (tap_beats),
    .tap_drops       (tap_drops),
    .tap_drop_sticky (tap_drop_sticky),
    .fifo_rdata      (fifo_rdata),
    .fifo_level      (fifo_level),
    .fifo_full       (fifo_full),
    .fifo_empty      (fifo_empty),
    .fifo_ov         (fifo_ov),
    .fifo_uf         (fifo_uf),
    .pkt_word        (pkt_word),
    .pkt_valid       (pkt_valid),
    .pkt_last        (pkt_last),
    .pkt_ready       (pkt_ready),
    .pkt_resid       (pkt_resid),
    .pkt_fields      (pkt_fields),
    .pkt_words       (pkt_words),
    .pkt_err         (pkt_err),
    .pkt_sat         (pkt_sat),
    .cdc_data        (cdc_data),
    .cdc_dst_data    (cdc_dst_data),
    .cdc_dst_valid   (cdc_dst_valid),
    .cdc_pend        (cdc_pend),
    .cdc_outstanding (cdc_outstanding),
    .cdc_tx          (cdc_tx),
    .cdc_rx          (cdc_rx),
    .cdc_err         (cdc_err),
    .cdc_err_sticky  (cdc_err_sticky),
    .irq_pin_out     (irq_pin_out),
    .irq_pend        (irq_pend),
    .irq_rdata       (irq_rdata),
    .irq_vec         (irq_vec),
    .irq_active      (irq_active),
    .irq_storm       (irq_storm),
    .irq_acked       (irq_acked),
    .irq_level_any   (irq_level_any),
    .trng_bit        (trng_bit),
    .trng_valid      (trng_valid),
    .trng_stuck      (trng_stuck),
    .trng_pair       (trng_pair),
    .trng_out_cnt    (trng_out_cnt),
    .trng_disc_cnt   (trng_disc_cnt),
    .i2s_sclk        (i2s_sclk),
    .i2s_lrclk       (i2s_lrclk),
    .i2s_sd          (i2s_sd),
    .i2s_fresh_l     (i2s_fresh_l),
    .i2s_fresh_r     (i2s_fresh_r),
    .i2s_words       (i2s_words),
    .i2s_under       (i2s_under),
    .i2s_under_sticky(i2s_under_sticky),
    .sm_rmax         (sm_rmax),
    .sm_rsum         (sm_rsum),
    .sm_p            (sm_p),
    .sm_pvld         (sm_pvld),
    .sm_sat          (sm_sat),
    .sm_clip         (sm_clip),
    .sm_cfg          (sm_cfg),
    .ewma_y          (ewma_y),
    .ewma_mean       (ewma_mean),
    .ewma_valid      (ewma_valid),
    .ewma_busy       (ewma_busy),
    .ewma_stall      (ewma_stall),
    .ewma_stage      (ewma_stage),
    .ram_rdata       (ram_rdata),
    .ram_hits        (ram_hits),
    .ram_guard       (ram_guard),
    .ram_error       (ram_error),
    .gen_beats       (gen_beats),
    .gen_lfsr        (gen_lfsr),
    .cnt_produced    (cnt_produced),
    .cnt_accepted    (cnt_accepted),
    .cnt_written     (cnt_written),
    .cnt_pops        (cnt_pops),
    .cnt_packed      (cnt_packed),
    .cnt_dropped     (cnt_dropped)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer j;
integer k;
reg [4:0] lvl_prev;
reg       bad;
reg       latched_any;
reg [7:0] hold_add;
reg [7:0] hold_lfsr;

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b1;
    gate_hold  = 8'd0;
    gate_beat  = 8'd0;
    bad        = 1'b0;
    j          = 0;
    k          = 0;
    lvl_prev   = 5'd0;
    latched_any = 1'b0;

    repeat (6) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        // Series-level clk_en discipline: park the whole bundle for three clocks
        // every 251st beat and require the enabled-beat state to survive it.
        if ((i % 251) == 100) begin
            hold_add  = add_clip_count;
            hold_lfsr = gen_lfsr[7:0];
            clk_en    = 1'b0;
            gate_hold = 8'd3;
        end
        if (gate_hold != 8'd0) begin
            gate_hold = gate_hold - 8'd1;
            if ((gate_hold == 8'd0) && clk_en !== 1'b1) begin
                if (add_clip_count !== hold_add || gen_lfsr[7:0] !== hold_lfsr) begin
                    bad = 1'b1;
                end
                clk_en = 1'b1;
            end
        end

        // X freedom over every observation group (docs/IP_CORE_SOP.md trap T6).
        if ((^{add_headroom, add_sat_neg, add_sat_pos, chain_sample, add_y,
              add_clip_count, tap_data, tap_beats, tap_drops}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{fifo_level, fifo_full, fifo_empty, fifo_rdata, fifo_ov, fifo_uf,
              pkt_valid, pkt_last, pkt_ready, pkt_resid, pkt_word, pkt_err,
              pkt_fields, pkt_words, pkt_sat}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{cdc_pend, cdc_outstanding, cdc_dst_valid, cdc_tx, cdc_rx, cdc_err,
              cdc_err_sticky, cdc_data, cdc_dst_data, irq_active, irq_storm,
              irq_acked, irq_level_any, irq_vec, irq_pend, irq_rdata,
              irq_pin_out}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{trng_bit, trng_valid, trng_stuck, trng_pair, trng_out_cnt,
              trng_disc_cnt, i2s_sclk, i2s_lrclk, i2s_sd, i2s_fresh_l, i2s_fresh_r,
              i2s_under_sticky, i2s_words, i2s_under}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{sm_pvld, sm_sat, sm_rmax, sm_p, sm_clip, sm_rsum, sm_cfg,
              ewma_valid, ewma_busy, ewma_stall, ewma_stage, ewma_y, ewma_mean,
              ram_error, ram_hits, ram_guard, ram_rdata}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{gen_beats, gen_lfsr, cnt_produced, cnt_accepted, cnt_written,
              cnt_pops, cnt_packed, cnt_dropped}) === 1'bx) begin
            bad = 1'b1;
        end

        // Shipped-crossing invariants: the bundle drives every core inside its
        // contract, so no core may report an interface error at series level.
        if (fifo_ov !== 4'd0 || fifo_uf !== 4'd0) begin
            bad = 1'b1;
        end
        if (cdc_err !== 4'd0 || cdc_err_sticky !== 1'b0) begin
            bad = 1'b1;
        end
        if (pkt_err !== 2'd0) begin
            bad = 1'b1;
        end
        if (ram_error !== 1'b0) begin
            bad = 1'b1;
        end

        // Ledger station 1: the delay line never loses a sample silently.  Every
        // sample delay_tap accepted has either been pushed into the FIFO, been
        // charged to a FIFO-full loss on an advancing beat, or is still inside the
        // tap line, which holds at most MAX_DELAY+1 = 16 positions.
        if (cnt_written > cnt_accepted ||
            (cnt_written + cnt_dropped) > cnt_accepted ||
            (cnt_accepted - cnt_written - cnt_dropped) > 16'd16) begin
            bad = 1'b1;
        end

        // Ledger station 2: the FIFO is a perfect queue.  With no over/underflow,
        // pushes minus pops equals the reported level on every enabled beat.
        if (cnt_written - cnt_pops !== {11'd0, fifo_level}) begin
            bad = 1'b1;
        end

        // Ledger station 3: a pop always lands in the packer, so pops can only
        // match the fields the packer has taken while its own counters are still
        // unsaturated (cnt_sat[0] is the cnt_fields ceiling bit).
        if (!pkt_sat[0] && cnt_pops !== pkt_fields) begin
            bad = 1'b1;
        end

        // Liveness, measured on the last beat that actually moved traffic: the
        // FIFO occupancy changing and a packer output are both required to have
        // happened recently, so a design that fills up and wedges cannot pass.
        if (fifo_level !== lvl_prev) begin
            lvl_prev = fifo_level;
            j = i;
        end
        if (pkt_valid) begin
            k = i;
        end
        if ((i - j) > 300 || (i - k) > 300) begin
            bad = 1'b1;
        end

        if (pkt_valid === 1'b1) begin
            latched_any = 1'b1;
        end

        // Bundle observation contract, one documented group per fold.
        ips_fnv_word({add_headroom, add_sat_neg, add_sat_pos, chain_sample, add_y});
        ips_fnv_word({add_clip_count, tap_data, tap_valid, tap_ready, tap_drop_sticky});
        ips_fnv_word({tap_beats, tap_drops});
        ips_fnv_word({fifo_level, fifo_full, fifo_empty, fifo_rdata, fifo_ov, fifo_uf});
        ips_fnv_word({pkt_valid, pkt_last, pkt_ready, pkt_resid, pkt_word, pkt_err});
        ips_fnv_word({pkt_fields, pkt_words, pkt_sat});
        ips_fnv_word({cdc_pend, cdc_outstanding, cdc_dst_valid, cdc_tx, cdc_rx,
                      cdc_err, cdc_err_sticky, cdc_data});
        ips_fnv_word({cdc_dst_data});
        ips_fnv_word({irq_active, irq_storm, irq_acked, irq_level_any, irq_vec,
                      irq_pend});
        ips_fnv_word({irq_rdata});
        ips_fnv_word({irq_pin_out});
        ips_fnv_word({trng_bit, trng_valid, trng_stuck, trng_pair, trng_out_cnt,
                      trng_disc_cnt});
        ips_fnv_word({i2s_sclk, i2s_lrclk, i2s_sd, i2s_fresh_l, i2s_fresh_r,
                      i2s_under_sticky, i2s_words, i2s_under});
        ips_fnv_word({sm_pvld, sm_sat, sm_rmax, sm_p, sm_clip});
        ips_fnv_word({sm_rsum});
        ips_fnv_word({sm_cfg});
        ips_fnv_word({ewma_valid, ewma_busy, ewma_stall, ewma_stage, ewma_y,
                      ewma_mean});
        ips_fnv_word({ram_error, ram_hits, ram_guard});
        ips_fnv_word({ram_rdata});
        ips_fnv_word(gen_lfsr);
        ips_fnv_word({gen_beats, cnt_produced});
        ips_fnv_word({cnt_accepted, cnt_written});
        ips_fnv_word({cnt_pops, cnt_packed});
        ips_fnv_word({cnt_dropped, fifo_level, cdc_tx, cdc_rx});
    end

    repeat (4) @(negedge ips_clk);

    // Liveness: the chain must have carried samples all the way to the packer, and
    // every ledger stage must have moved.
    if (cnt_produced === 16'd0 || cnt_accepted === 16'd0 || cnt_written === 16'd0 ||
        cnt_pops === 16'd0 || cnt_packed === 16'd0 || !latched_any) begin
        bad = 1'b1;
    end

    ips_fnv_word({cnt_produced, cnt_accepted});
    ips_fnv_word({cnt_written, cnt_pops});
    ips_fnv_word({cnt_packed, cnt_dropped});
    ips_fnv_word(gen_lfsr);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_series_bundle");
end

endmodule
