`timescale 1ns / 1ps
// ips_series_bundle : series-level integration top for the ip_series_20k portfolio.
//
// This is not another portfolio core: it is the coherence proof for the packaged
// artefacts.  Every instance below is a shipped wrapper (gw2a_ips_<name>) taken
// from ip/<name>/, so a green bundle run demonstrates that the licensable files
// -- not just the internal src/ RTL -- instantiate together in one design unit,
// that the namespace holds, and that the wrapper port passthrough is usable.
//
// Topology:
//   chain  arith -> path -> path -> pkt
//     gw2a_ips_fix_add_sat -> gw2a_ips_delay_tap -> gw2a_ips_fifo_sync_fwft ->
//     gw2a_ips_bit_packer
//   one independent channel per remaining family:
//     cdc (gw2a_ips_cdc_toggle_sync), ctrl (gw2a_ips_gpio_irq_bank),
//     sec (gw2a_ips_trng_vonng_cond), iface (gw2a_ips_i2s_tx_master),
//     nn  (gw2a_ips_softmax_fixed),  arith (gw2a_ips_ewma_moving_avg),
//     path (gw2a_ips_ram_sp_1p)
//
// Stimulus is generated inside the bundle from a Galois-style LFSR plus a free
// running beat counter, both clk_en-gated, so the whole bundle is deterministic
// from the reset state and needs no testbench-driven inputs.  The reference
// bundle geometry is the shipped default of every core: the instances carry no
// #() overrides, so the file set exercised here is exactly the file set a
// licensee would receive.
module ips_series_bundle (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    // chain observations
    output wire signed [15:0] add_y,
    output wire        add_sat_pos,
    output wire        add_sat_neg,
    output wire [1:0]  add_headroom,
    output wire [7:0]  add_clip_count,
    output wire        chain_sample,      // a fresh arithmetic sample left the adder
    output wire [7:0]  tap_data,
    output wire        tap_valid,
    output wire        tap_ready,
    output wire [7:0]  tap_beats,
    output wire [7:0]  tap_drops,
    output wire        tap_drop_sticky,
    output wire [7:0]  fifo_rdata,
    output wire [4:0]  fifo_level,
    output wire        fifo_full,
    output wire        fifo_empty,
    output wire [3:0]  fifo_ov,
    output wire [3:0]  fifo_uf,
    output wire [7:0]  pkt_word,
    output wire        pkt_valid,
    output wire        pkt_last,
    output wire        pkt_ready,
    output wire [4:0]  pkt_resid,
    output wire [7:0]  pkt_fields,
    output wire [7:0]  pkt_words,
    output wire [1:0]  pkt_err,
    output wire [5:0]  pkt_sat,

    // per-family channel observations
    output wire [11:0] cdc_data,
    output wire [11:0] cdc_dst_data,
    output wire        cdc_dst_valid,
    output wire        cdc_pend,
    output wire        cdc_outstanding,
    output wire [3:0]  cdc_tx,
    output wire [3:0]  cdc_rx,
    output wire [3:0]  cdc_err,
    output wire        cdc_err_sticky,
    output wire [31:0] irq_pin_out,
    output wire [15:0] irq_pend,
    output wire [31:0] irq_rdata,
    output wire [3:0]  irq_vec,
    output wire        irq_active,
    output wire        irq_storm,
    output wire        irq_acked,
    output wire        irq_level_any,
    output wire        trng_bit,
    output wire        trng_valid,
    output wire        trng_stuck,
    output wire        trng_pair,
    output wire [11:0] trng_out_cnt,
    output wire [11:0] trng_disc_cnt,
    output wire        i2s_sclk,
    output wire        i2s_lrclk,
    output wire        i2s_sd,
    output wire        i2s_fresh_l,
    output wire        i2s_fresh_r,
    output wire [7:0]  i2s_words,
    output wire [7:0]  i2s_under,
    output wire        i2s_under_sticky,
    output wire [11:0] sm_rmax,
    output wire [12:0] sm_rsum,
    output wire [7:0]  sm_p,
    output wire        sm_pvld,
    output wire        sm_sat,
    output wire [7:0]  sm_clip,
    output wire [31:0] sm_cfg,
    output wire [7:0]  ewma_y,
    output wire [7:0]  ewma_mean,
    output wire        ewma_valid,
    output wire        ewma_busy,
    output wire        ewma_stall,
    output wire [2:0]  ewma_stage,
    output wire [31:0] ram_rdata,
    output wire [7:0]  ram_hits,
    output wire [7:0]  ram_guard,
    output wire        ram_error,

    // bundle-internal bookkeeping exposed for the conservation check
    output wire [15:0] gen_beats,
    output wire [31:0] gen_lfsr,
    output wire [15:0] cnt_produced,
    output wire [15:0] cnt_accepted,
    output wire [15:0] cnt_written,
    output wire [15:0] cnt_pops,
    output wire [15:0] cnt_packed,
    output wire [15:0] cnt_dropped
);

// Chain control wires declared ahead of the stimulus block that observes them.
wire        fifo_wr_req;
wire        fifo_rd_req;
wire        pkt_load;
wire        tap_no_stall;
wire        tap_accept;
wire        fifo_push;
wire        fifo_pop;

// ---------------------------------------------------------------- stimulus
reg [31:0] lfsr;
reg [15:0] bc;
reg [2:0]  burst_cnt;
reg [15:0] produced;
reg [15:0] accepted_in;
reg [15:0] written;
reg [15:0] pops;
reg [15:0] packed_beats;
reg [15:0] dropped;

wire       lfb   = lfsr[31] ^ lfsr[21] ^ lfsr[9] ^ lfsr[7];
wire [1:0] strobe2 = bc[1:0];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lfsr     <= 32'h1AC53B79;
        bc       <= 16'h0000;
        burst_cnt<= 3'd0;
        produced <= 16'h0000;
        accepted_in <= 16'h0000;
        written  <= 16'h0000;
        pops     <= 16'h0000;
        packed_beats <= 16'h0000;
        dropped  <= 16'h0000;
    end else if (clk_en) begin
        lfsr <= {lfsr[30:0], lfb};
        bc   <= bc + 16'h0001;
        if (pkt_load) begin
            burst_cnt <= (burst_cnt == 3'd6) ? 3'd0 : (burst_cnt + 3'd1);
        end
        if (chain_sample) begin
            produced <= produced + 16'h0001;
        end
        if (tap_accept) begin
            accepted_in <= accepted_in + 16'h0001;
        end
        if (fifo_push) begin
            written <= written + 16'h0001;
        end
        if (fifo_pop) begin
            pops <= pops + 16'h0001;
        end
        if (pkt_valid) begin
            packed_beats <= packed_beats + 16'h0001;
        end
        // A tap-output sample is lost only on a beat where the line really
        // advances, so the ledger counts each loss once (a stalled line keeps the
        // same sample presented and must not be charged again).
        if (tap_valid && fifo_full && tap_no_stall) begin
            dropped <= dropped + 16'h0001;
        end
    end
end

// ---------------------------------------------------------------- chain
// Hand-off rules for the chain, each one taken straight from the producing core's
// own contract:
//   * delay_tap accepts only when in_ready is high and stall is low, so a beat
//     presented under stall is lost and must not be presented again as if new;
//   * a sample sits on the tap output for as long as the line is stalled, so the
//     FIFO may take it only on a beat where the line advances -- otherwise the same
//     sample would be pushed twice;
//   * the packer only accepts in its load state, and a FIFO pop is destructive, so
//     the read request is qualified with pkt_ready -- every pop hands its word on.
wire        add_valid = strobe2[0];
wire [7:0]  tap_in_data;
assign tap_in_data = add_y[7:0];
assign tap_no_stall = !lfsr[13];
assign tap_accept   = chain_sample && tap_ready && tap_no_stall;
assign fifo_push    = tap_valid && !fifo_full && tap_no_stall;
assign fifo_pop     = !fifo_empty && bc[2] && pkt_ready;
assign fifo_wr_req  = fifo_push;
assign fifo_rd_req  = fifo_pop;
assign pkt_load     = fifo_pop;

gw2a_ips_fix_add_sat u_add (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (add_valid),
    .a          ({lfsr[15:0]}),
    .b          ({lfsr[31:16]}),
    .k          ({8'h00, lfsr[7:0]}),
    .y          (add_y),
    .sat_pos    (add_sat_pos),
    .sat_neg    (add_sat_neg),
    .headroom   (add_headroom),
    .clip_count (add_clip_count),
    .y_max      (),
    .y_min      ()
);

// A sample is fresh on the beat after the adder accepts it, which is exactly when
// delay_tap may accept it, so the chain handoff is one beat wide.
reg chain_vld_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        chain_vld_q <= 1'b0;
    end else if (clk_en) begin
        chain_vld_q <= add_valid;
    end
end
assign chain_sample = chain_vld_q;

gw2a_ips_delay_tap u_tap (
    .clk         (clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .in_valid    (chain_sample && tap_ready),
    .in_data     (tap_in_data),
    .stall       (lfsr[13]),
    .delay_sel   ({4'h0, lfsr[3:0]}),
    .out_data    (tap_data),
    .out_valid   (tap_valid),
    .in_ready    (tap_ready),
    .tap_index   (),
    .active_lat  (),
    .beat_count  (tap_beats),
    .drop_count  (tap_drops),
    .lat_events  (),
    .drop_sticky (tap_drop_sticky)
);

gw2a_ips_fifo_sync_fwft u_fifo (
    .clk     (clk),
    .clk_en  (clk_en),
    .rst_n   (rst_n),
    .wr_req  (fifo_wr_req),
    .wdata   (tap_data),
    .rd_req  (fifo_rd_req),
    .wm_hi   (5'd12),
    .wm_lo   (5'd3),
    .rdata   (fifo_rdata),
    .full    (fifo_full),
    .empty   (fifo_empty),
    .level   (fifo_level),
    .flag_hi (),
    .flag_lo (),
    .ov_flag (),
    .uf_flag (),
    .ov_count(fifo_ov),
    .uf_count(fifo_uf)
);

// A burst is seven accepted fields long: 7*FIELD_BITS is never a multiple of
// OUT_BITS for any smaller count either, so the burst always ends with a residual
// for the packer to emit, and it stays far below MAX_BURST.  An explicit flush is
// only ever asserted while the reservoir really holds bits, so the core's
// spurious-flush path is a contract the bundle obeys rather than a bug it hides.
wire pkt_want_flush = bc[12] && bc[6];
wire pkt_flush      = pkt_want_flush && pkt_ready && !pkt_load &&
                      (pkt_resid != 5'd0);

gw2a_ips_bit_packer u_pkt (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (pkt_load),
    .in_last    (burst_cnt == 3'd6),
    .in_field   ({3'h0, fifo_rdata}),
    .flush      (pkt_flush),
    .in_ready   (pkt_ready),
    .out_valid  (pkt_valid),
    .out_last   (pkt_last),
    .out_word   (pkt_word),
    .resid_bits (pkt_resid),
    .pad_bits   (),
    .burst_len  (),
    .cnt_fields (pkt_fields),
    .cnt_words  (pkt_words),
    .cnt_flush  (),
    .cnt_spur   (),
    .max_resid  (),
    .bits_in    (),
    .bits_out   (),
    .err_sticky (pkt_err),
    .cnt_sat    (pkt_sat)
);

// ---------------------------------------------------------------- cdc channel
// The core refuses a launch while the previous transfer is still crossing (it is
// an error, not a stall), so the source holds off until outstanding clears; the
// destination only takes when a payload has actually landed.
wire       src_tick = bc[3];
wire       dst_tick = bc[4];
wire       src_start = src_tick && lfsr[5] && !cdc_outstanding;
wire       dst_take  = dst_tick && cdc_dst_valid;

gw2a_ips_cdc_toggle_sync u_cdc (
    .clk         (clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .src_tick    (src_tick),
    .dst_tick    (dst_tick),
    .src_start   (src_start),
    .src_data    (lfsr[11:0]),
    .dst_take    (dst_take),
    .data_hold   (),
    .tog_src     (),
    .pend        (cdc_pend),
    .outstanding (cdc_outstanding),
    .tx_count    (cdc_tx),
    .rx_count    (cdc_rx),
    .err_count   (cdc_err),
    .err_sticky  (cdc_err_sticky),
    .dst_data    (cdc_dst_data),
    .dst_valid   (cdc_dst_valid),
    .ack_tog     (),
    .tog_s1      (),
    .tog_s2      (),
    .ack_s1      (),
    .ack_s2      ()
);
assign cdc_data = lfsr[11:0];

// ---------------------------------------------------------------- ctrl channel
wire       bus_we  = bc[8];
wire       bus_ack = bc[9];

gw2a_ips_gpio_irq_bank u_irq (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .pin_in     ({lfsr[15:0], ~lfsr[15:0]}),
    .bus_addr   (lfsr[3:0]),
    .bus_we     (bus_we),
    .bus_wdata  (lfsr),
    .bus_ack    (bus_ack),
    .bus_rdata  (irq_rdata),
    .pend       (irq_pend),
    .pin_out    (irq_pin_out),
    .irq_active (irq_active),
    .irq_vec    (irq_vec),
    .storm      (irq_storm),
    .acked      (irq_acked),
    .sync_idx   (),
    .set_evts   (),
    .w1c_evts   (),
    .err_count  (),
    .level_any  (irq_level_any)
);

// ---------------------------------------------------------------- sec channel
wire       coin       = lfsr[0] ^ lfsr[17];
wire       cond_start = bc[10];
wire       cond_run   = !bc[11];

gw2a_ips_trng_vonng_cond u_trng (
    .clk           (clk),
    .clk_en        (clk_en),
    .rst_n         (rst_n),
    .cond_start    (cond_start),
    .cond_run      (cond_run),
    .src_bit       (coin),
    .out_bit       (trng_bit),
    .out_valid     (trng_valid),
    .stuck_alarm   (trng_stuck),
    .pair_pending  (trng_pair),
    .out_bit_cnt   (trng_out_cnt),
    .disc_pair_cnt (trng_disc_cnt),
    .bit_cnt       ()
);

// ---------------------------------------------------------------- iface channel
wire       i2s_tick    = bc[1];
wire       i2s_ch_val  = bc[12] && !bc[13];

gw2a_ips_i2s_tx_master u_i2s (
    .clk              (clk),
    .clk_en           (clk_en),
    .rst_n            (rst_n),
    .tick             (i2s_tick),
    .ch_valid         (i2s_ch_val),
    .ch_l             (lfsr[15:0]),
    .ch_r             ({lfsr[31:16]}),
    .sclk             (i2s_sclk),
    .lrclk            (i2s_lrclk),
    .sd               (i2s_sd),
    .fresh_l          (i2s_fresh_l),
    .fresh_r          (i2s_fresh_r),
    .bit_idx          (),
    .div_idx          (),
    .word_count       (i2s_words),
    .under_count      (i2s_under),
    .underflow_sticky (i2s_under_sticky)
);

// ---------------------------------------------------------------- nn channel
wire        sm_valid = bc[6] && bc[3];

gw2a_ips_softmax_fixed u_sm (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (sm_valid),
    .lg         (lfsr[11:0]),
    .rmax       (sm_rmax),
    .rsum       (sm_rsum),
    .exp_last   (),
    .p          (sm_p),
    .p_vld      (sm_pvld),
    .sat_sticky (sm_sat),
    .clip_count (sm_clip),
    .ph_last    (),
    .resid      (),
    .cfg_id     (sm_cfg)
);

// ---------------------------------------------------------------- arith channel
wire       ew_start = bc[7] && bc[1];

gw2a_ips_ewma_moving_avg u_ewma (
    .clk     (clk),
    .clk_en  (clk_en),
    .rst_n   (rst_n),
    .start   (ew_start),
    .x_in    (lfsr[7:0]),
    .ewma    (ewma_y),
    .mean    (ewma_mean),
    .msum    (),
    .rem     (),
    .frac    (),
    .stall   (ewma_stall),
    .valid   (ewma_valid),
    .busy    (ewma_busy),
    .stage   (ewma_stage),
    .wptr    (),
    .cnt     (),
    .it      ()
);

// ---------------------------------------------------------------- path channel
// ram_sp_1p is a single-port memory whose array is not cleared by rst_n, so the
// bundle must obey the core's own contract: never write with the port deselected,
// and write an address before any later beat reads it.  The first 32 enabled beats
// fill the whole array, and after that fill only reads are issued.
wire       ram_init = !bc[5];
wire       ram_ce   = ram_init || bc[3];
wire       ram_we   = ram_init;
wire [31:0] ram_wdata = (bc[1:0] == 2'b00) ? 32'hA5A5_5A5A : lfsr;

gw2a_ips_ram_sp_1p u_ram (
    .clk           (clk),
    .clk_en        (clk_en),
    .rst_n         (rst_n),
    .ce            (ram_ce),
    .we            (ram_we),
    .be            (ram_we ? 4'hF : 4'h0),
    .waddr         (ram_we ? bc[4:0] : lfsr[4:0]),
    .raddr         (lfsr[4:0]),
    .top_sel       (lfsr[10]),
    .wdata         (ram_wdata),
    .rdata         (ram_rdata),
    .raddr_q       (),
    .hit_count     (ram_hits),
    .guard_count   (ram_guard),
    .addr_count    (),
    .error_sticky  (ram_error)
);

assign gen_beats   = bc;
assign gen_lfsr    = lfsr;
assign cnt_produced = produced;
assign cnt_accepted = accepted_in;
assign cnt_written  = written;
assign cnt_pops     = pops;
assign cnt_packed   = packed_beats;
assign cnt_dropped  = dropped;

endmodule
