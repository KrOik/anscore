`timescale 1ns / 1ps
// ips_series_nn_front : second series-level integration top for ip_series_20k.
//
// Where ips_series_bundle integrates the streaming / control side of the library,
// this top integrates the inference side: a sensor stream is decimated, quantised,
// convolved, batch-normalised, multiplied-accumulated, ranked, integrity-checked
// and crossed into a second clock domain, and every block in that path is a
// *packaged* gw2a_ips_<name> wrapper instantiated with its shipped defaults.  It is
// the reference subsystem a licensee is shown, not a portfolio core: there is no
// Python golden model for the composition, and sim/tb_ips_series_nn_front.v
// replaces that station with contract invariants plus a stage-to-stage ledger.
//
// Integration rules taken from each core's own header, which the testbench then
// checks were obeyed:
//   * ips_pdm_decim16 advances on pdm_tick and clamps instead of wrapping, so its
//     saturation flags are legitimate output, not errors.  The pin is sampled on
//     every enabled clock, which is the decimator's per-beat oversample contract;
//   * ips_quant_int8_sym consumes one value per in_valid beat and dir selects the
//     quantise / dequantise path; the payload only has to be stable while in_valid
//     is high;
//   * ips_conv1d_depthwise consumes one tap per beat and publishes only on the
//     closing beat tap == tcfg-1, so the bundle replays every quantised sample
//     across the whole four-tap window with a latched channel and a fixed tcfg;
//   * ips_bn_fold_lut refreshes only the addressed path per beat, so yw holds
//     across bias beats and yb across weight beats;
//   * ips_ram_dp_1w2r never has its banks cleared by rst_n, so the bundle fills all
//     sixteen cells before the first read, and it never writes on a beat where a
//     reader is enabled -- that is what keeps collide_count and conflict_sticky
//     clear, which the core reserves for the three-ports-on-one-cell case;
//   * ips_int8_mac_array seeds per-lane bias with load, so the bundle asserts load
//     on the first beat of every sixteen-beat vector and the lane accumulators
//     restart from bias instead of compounding forever;
//   * ips_topk_argmax4 needs no end-of-vector input: it counts NSC scores itself
//     and pulses done;
//   * ips_booth_mult_s16 drops a start that arrives while busy and counts it in
//     err_start, so the bundle only starts an operation when the pipe is free;
//   * ips_ct_compare reports a length violation (len_err) when in_last does not
//     land on exp_len, so the bundle presents exactly eight words per frame;
//   * ips_cdc_bus_gray can only survive pointer changes that move one Gray bit at
//     a time, so src_step is 0 or 1 and a pending publish is held until the source
//     tick consumes it.
//
// clk_en gates every register in every core and rst_n is the active-low
// asynchronous reset (docs/IP_CORE_SOP.md traps T2 and T6).
module ips_series_nn_front (
    input  wire         clk,
    input  wire         clk_en,
    input  wire         rst_n,

    // audio front
    output wire [15:0]  pdm_pcm,
    output wire [3:0]   pdm_pcm_hr,
    output wire         pdm_pcm_valid,
    output wire         pdm_sat_sticky,
    output wire [7:0]   pdm_out_count,
    output wire [4:0]   pdm_phase,

    // weight store
    output wire [31:0]  ram_r0_data,
    output wire [31:0]  ram_r1_data,
    output wire         ram_r0_valid,
    output wire         ram_r1_valid,
    output wire [7:0]   ram_hit_count,
    output wire [7:0]   ram_guard_count,
    output wire [15:0]  ram_read_count,
    output wire [7:0]   ram_write_count,
    output wire [7:0]   ram_collide_count,
    output wire         ram_conflict_sticky,

    // quantise / dequantise
    output wire [7:0]   q_yq,
    output wire [15:0]  q_ydq,
    output wire         q_y_vld,
    output wire         q_clipped_last,
    output wire         q_udf_sticky,
    output wire [7:0]   q_clip_count,
    output wire [31:0]  q_cfg_id,

    // depthwise convolution
    output wire [7:0]   cv_y,
    output wire         cv_out_valid,
    output wire         cv_sat_last,
    output wire [7:0]   cv_clip_count,
    output wire [17:0]  cv_acc,
    output wire [15:0]  cv_cfg_id,

    // batch-norm fold
    output wire [7:0]   bn_yw,
    output wire [15:0]  bn_yb,
    output wire         bn_y_vld,
    output wire         bn_oor,
    output wire [7:0]   bn_clip_count,
    output wire [31:0]  bn_cfg_id,

    // int8 MAC array
    output wire [127:0] mac_acc,
    output wire [7:0]   mac_headroom,
    output wire [3:0]   mac_sat,
    output wire [7:0]   mac_clip_count,
    output wire [31:0]  mac_geom_id,

    // top-k readout
    output wire [11:0]  tk_t0,
    output wire [11:0]  tk_t1,
    output wire [11:0]  tk_t2,
    output wire [11:0]  tk_t3,
    output wire [3:0]   tk_i0,
    output wire [3:0]   tk_i1,
    output wire [3:0]   tk_i2,
    output wire [3:0]   tk_i3,
    output wire         tk_v0,
    output wire         tk_done,
    output wire [7:0]   tk_drop_count,
    output wire [7:0]   tk_rep_count,
    output wire [31:0]  tk_cfg_id,

    // reference scalar multiply
    output wire [31:0]  bt_product,
    output wire         bt_ovf,
    output wire         bt_valid,
    output wire         bt_busy,
    output wire [7:0]   bt_err_start,

    // stream integrity
    output wire [31:0]  ct_diff_acc,
    output wire [11:0]  ct_match_cnt,
    output wire [11:0]  ct_mismatch_cnt,
    output wire         ct_len_err,
    output wire         ct_cmp_done,

    // result-pointer crossing
    output wire [3:0]   cg_bin_ptr,
    output wire [3:0]   cg_bin_dec,
    output wire         cg_err_sticky,
    output wire [3:0]   cg_err_count,
    output wire [3:0]   cg_sync_count,

    // bundle bookkeeping for the stage ledger
    output wire [15:0]  gen_beats,
    output wire [31:0]  gen_lfsr,
    output reg  [15:0]  cnt_audio,
    output reg  [15:0]  cnt_quant,
    output reg  [15:0]  cnt_conv,
    output reg  [15:0]  cnt_bn,
    output reg  [15:0]  cnt_mac,
    output reg  [15:0]  cnt_rank,
    output reg  [15:0]  cnt_cross
);

// ---------------------------------------------------------------- stimulus
reg [31:0] lfsr;
reg [15:0] bc;
reg [3:0]  vec;
reg        cross_pend;

wire       lfb       = lfsr[31] ^ lfsr[21] ^ lfsr[9] ^ lfsr[7];
wire       ram_write_phase = !bc[4];
wire       ram_read_phase  =  bc[4];
wire [5:0] ct_phase  = bc[5:0];

assign gen_beats = bc;
assign gen_lfsr  = lfsr;

// ---------------------------------------------------------------- stage strobes
wire       pdm_tick    = 1'b1;
wire       pdm_in      = lfsr[0] ^ lfsr[9];
wire       q_start     = pdm_pcm_valid;
wire       bn_start    = cv_out_valid;
wire       mac_start   = bn_y_vld;
wire       cg_src_tick = bc[3];
wire       cg_dst_tick = bc[5];
wire [1:0] q_ch        = lfsr[1:0];

// The convolver consumes one tap per beat and closes a window on tap == tcfg-1, so
// each quantised sample is replayed across the full four-tap window on the four
// beats that follow it.  The window reads newest sample first and the channel is
// latched with the sample: a weight row must not change half-way through a window.
reg  [2:0] cv_run;
reg  [1:0] cv_ch;
reg  [7:0] xh0;
reg  [7:0] xh1;
reg  [7:0] xh2;
reg  [7:0] xh3;
wire [2:0] cv_tap   = 3'd4 - cv_run;
wire       cv_start = (cv_run != 3'd0);
wire [7:0] cv_xv    = (cv_tap == 3'd0) ? xh0 :
                      (cv_tap == 3'd1) ? xh1 :
                      (cv_tap == 3'd2) ? xh2 : xh3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        lfsr       <= 32'h2F9C11AC;
        bc         <= 16'h0000;
        vec        <= 4'd0;
        cross_pend <= 1'b0;
        cnt_audio  <= 16'h0000;
        cnt_quant  <= 16'h0000;
        cnt_conv   <= 16'h0000;
        cnt_bn     <= 16'h0000;
        cnt_mac    <= 16'h0000;
        cnt_rank   <= 16'h0000;
        cnt_cross  <= 16'h0000;
    end else if (clk_en) begin
        lfsr <= {lfsr[30:0], lfb};
        bc   <= bc + 16'h0001;
        if (pdm_pcm_valid) begin
            cnt_audio <= cnt_audio + 16'h0001;
        end
        if (q_y_vld) begin
            cnt_quant <= cnt_quant + 16'h0001;
        end
        if (cv_out_valid) begin
            cnt_conv <= cnt_conv + 16'h0001;
        end
        if (bn_y_vld) begin
            cnt_bn <= cnt_bn + 16'h0001;
        end
        if (mac_start) begin
            cnt_mac <= cnt_mac + 16'h0001;
            vec     <= vec + 4'd1;
        end
        if (tk_done) begin
            cnt_rank <= cnt_rank + 16'h0001;
            cross_pend <= 1'b1;
        end
        if (cross_pend && cg_src_tick) begin
            // one Gray step per completed vector, taken by the source tick
            cross_pend <= 1'b0;
            cnt_cross  <= cnt_cross + 16'h0001;
        end
    end
end

// ---------------------------------------------------------------- audio front
gw2a_ips_pdm_decim16 u_pdm (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .pdm_tick   (pdm_tick),
    .pdm_in     (pdm_in),
    .pcm        (pdm_pcm),
    .pcm_hr     (pdm_pcm_hr),
    .pcm_valid  (pdm_pcm_valid),
    .sat_pos    (),
    .sat_neg    (),
    .sat_sticky (pdm_sat_sticky),
    .sat_count  (),
    .out_count  (pdm_out_count),
    .phase      (pdm_phase)
);

// ---------------------------------------------------------------- weight store
// Writes and reads never share a beat, and the first sixteen enabled beats fill
// every cell before the read phase touches one, so no unwritten cell is ever read.
wire       ram_we   = ram_write_phase;
wire [3:0] ram_waddr = bc[3:0];
wire       ram_r0_en = ram_read_phase && bc[1];
wire       ram_r1_en = ram_read_phase && bc[2];

gw2a_ips_ram_dp_1w2r u_ram (
    .clk             (clk),
    .clk_en          (clk_en),
    .rst_n           (rst_n),
    .wr_en           (ram_we),
    .waddr           (ram_waddr),
    .wdata           ((ram_waddr == 4'd5) ? 32'hA5A5_5A5A : lfsr),
    .r0_en           (ram_r0_en),
    .r0_addr         (lfsr[3:0]),
    .r0_top          (1'b1),
    .r1_en           (ram_r1_en),
    .r1_addr         (~lfsr[3:0]),
    .r1_top          (1'b0),
    .r0_data         (ram_r0_data),
    .r0_addr_q       (),
    .r0_valid        (ram_r0_valid),
    .r1_data         (ram_r1_data),
    .r1_addr_q       (),
    .r1_valid        (ram_r1_valid),
    .hit_count       (ram_hit_count),
    .guard_count     (ram_guard_count),
    .read_count      (ram_read_count),
    .write_count     (ram_write_count),
    .collide_count   (ram_collide_count),
    .conflict_sticky (ram_conflict_sticky)
);

// ---------------------------------------------------------------- quantise
gw2a_ips_quant_int8_sym u_q (
    .clk          (clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .in_valid     (q_start),
    .dir          (bc[4]),
    .ch           (q_ch),
    .x            (pdm_pcm[11:0]),
    .yq           (q_yq),
    .ydq          (q_ydq),
    .ymag         (),
    .y_neg        (),
    .y_vld        (q_y_vld),
    .clipped_last (q_clipped_last),
    .sat_q        (),
    .sat_d        (),
    .udf_sticky   (q_udf_sticky),
    .clip_count   (q_clip_count),
    .cfg_id       (q_cfg_id)
);

// ---------------------------------------------------------------- convolution
// The sample-advance branch mirrors the quantiser's publish beat exactly once per
// sample; the walk branch then holds the window steady for four taps.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        cv_run <= 3'd0;
        cv_ch  <= 2'd0;
        xh0    <= 8'h00;
        xh1    <= 8'h00;
        xh2    <= 8'h00;
        xh3    <= 8'h00;
    end else if (clk_en) begin
        if (q_y_vld) begin
            cv_run <= 3'd4;
            cv_ch  <= q_ch;
            xh3    <= xh2;
            xh2    <= xh1;
            xh1    <= xh0;
            xh0    <= q_yq;
        end else if (cv_run != 3'd0) begin
            cv_run <= cv_run - 3'd1;
        end
    end
end

gw2a_ips_conv1d_depthwise u_cv (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (cv_start),
    .ch         (cv_ch),
    .tap        (cv_tap),
    .tcfg       (3'd4),
    .xv         (cv_xv),
    .pad_en     (1'b0),
    .padv       (8'sd0),
    .y          (cv_y),
    .out_valid  (cv_out_valid),
    .sat_last   (cv_sat_last),
    .clip_count (cv_clip_count),
    .acc        (cv_acc),
    .cfg_id     (cv_cfg_id)
);

// ---------------------------------------------------------------- batch-norm fold
gw2a_ips_bn_fold_lut u_bn (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (bn_start),
    .sel        (bc[6]),
    .ch         ({1'b0, cv_ch}),
    .w          ({{4{cv_y[7]}}, cv_y}),
    .yw         (bn_yw),
    .yb         (bn_yb),
    .fs_last    (),
    .y_vld      (bn_y_vld),
    .sel_last   (),
    .ch_last    (),
    .oor        (bn_oor),
    .oor_w      (),
    .oor_b      (),
    .clip_count (bn_clip_count),
    .cfg_id     (bn_cfg_id)
);

// ---------------------------------------------------------------- MAC array
// One sixteen-beat vector per bias load: lane bytes come from four different
// stages of the front end, and the weights come from the store.
wire [31:0] mac_x = {bn_yw, cv_y, q_yq, pdm_pcm[7:0]};

gw2a_ips_int8_mac_array u_mac (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (mac_start),
    .load       (vec == 4'd0),
    .x          (mac_x),
    .w          (ram_r0_data),
    .bias       ({ram_r1_data, ram_r0_data, ram_r1_data, ram_r0_data}),
    .acc        (mac_acc),
    .headroom   (mac_headroom),
    .sat        (mac_sat),
    .clip_count (mac_clip_count),
    .geom_id    (mac_geom_id)
);

// ---------------------------------------------------------------- top-k readout
gw2a_ips_topk_argmax4 u_tk (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (mac_start),
    .s          (mac_acc[31:20]),
    .idx        (vec),
    .t0         (tk_t0),
    .t1         (tk_t1),
    .t2         (tk_t2),
    .t3         (tk_t3),
    .i0         (tk_i0),
    .i1         (tk_i1),
    .i2         (tk_i2),
    .i3         (tk_i3),
    .v0         (tk_v0),
    .v1         (),
    .v2         (),
    .v3         (),
    .pos_last   (),
    .beat_last  (),
    .done       (tk_done),
    .rep_last   (),
    .drop_last  (),
    .in_last    (),
    .drop_count (tk_drop_count),
    .rep_count  (tk_rep_count),
    .cfg_id     (tk_cfg_id)
);

// ---------------------------------------------------------------- scalar path
// A start is only issued when the pipeline is free, so err_start stays clear.
wire bt_start = bc[7] && !bt_busy;

gw2a_ips_booth_mult_s16 u_bt (
    .clk        (clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .start      (bt_start),
    .operand_a  (mac_acc[31:16]),
    .operand_b  ({{4{tk_t0[11]}}, tk_t0}),
    .product    (bt_product),
    .ovf        (bt_ovf),
    .valid      (bt_valid),
    .busy       (bt_busy),
    .stage      (),
    .ppc        (),
    .err_start  (bt_err_start)
);

// ---------------------------------------------------------------- integrity path
// Eight words per frame, the eighth marked last, and exp_len agrees, so len_err
// can only ever be raised by a real integration fault.
gw2a_ips_ct_compare u_ct (
    .clk          (clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .cmp_start    (ct_phase == 6'd0),
    .exp_len      (12'd8),
    .in_valid     ((ct_phase >= 6'd2) && (ct_phase <= 6'd9)),
    .in_last      (ct_phase == 6'd9),
    .cand_word    (mac_acc[31:0]),
    .ref_word     (ram_r1_data),
    .diff_acc     (ct_diff_acc),
    .match_cnt    (ct_match_cnt),
    .mismatch_cnt (ct_mismatch_cnt),
    .beat_cnt     (),
    .exp_cnt      (),
    .len_err      (ct_len_err),
    .cmp_done     (ct_cmp_done)
);

// ---------------------------------------------------------------- crossing
// The publish pointer advances one step per completed vector, and the pending flag
// holds the event until a source tick consumes it, so the Gray word only ever
// changes by a single bit.
gw2a_ips_cdc_bus_gray u_cg (
    .clk         (clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .src_tick    (cg_src_tick),
    .dst_tick    (cg_dst_tick),
    .src_step    (cross_pend ? 4'd1 : 4'd0),
    .bin_ptr     (cg_bin_ptr),
    .gray_q      (),
    .sync1       (),
    .sync2       (),
    .bin_dec     (cg_bin_dec),
    .err_sticky  (cg_err_sticky),
    .err_count   (cg_err_count),
    .sync_count  (cg_sync_count),
    .hold_count  ()
);

endmodule

