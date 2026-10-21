`timescale 1ns / 1ps
// tb_ips_series_nn_front : series-level integration bench for the inference-side
// composition of ip_series_20k (src/ips_series_nn_front.v).
//
// Like tb_ips_series_bundle.v this is a coherence harness, not a portfolio core, so
// there is no Python golden model: the equivalence station is replaced by (a) the
// per-core contract invariants that only a correct integration can satisfy, (b) a
// stage-to-stage sample ledger that would break if any hand-off in the chain
// dropped, duplicated or invented a sample, and (c) the geometry readback words the
// packaged wrappers export.  The fold order below is the bundle observation contract
// and is shared with nothing but the run log; every group is padded to exactly 32
// bits so no fold can silently truncate.
module tb_ips_series_nn_front;

`include "ips_tb_common.vh"

localparam integer BEATS = 2000;

reg        rst_n;
reg        clk_en;
reg [7:0]  gate_hold;
reg [15:0] hold_audio;
reg [15:0] hold_mac;

wire signed [15:0] pdm_pcm;
wire [3:0]  pdm_pcm_hr;
wire        pdm_pcm_valid;
wire        pdm_sat_sticky;
wire [7:0]  pdm_out_count;
wire [4:0]  pdm_phase;
wire [31:0] ram_r0_data;
wire [31:0] ram_r1_data;
wire        ram_r0_valid;
wire        ram_r1_valid;
wire [7:0]  ram_hit_count;
wire [7:0]  ram_guard_count;
wire [15:0] ram_read_count;
wire [7:0]  ram_write_count;
wire [7:0]  ram_collide_count;
wire        ram_conflict_sticky;
wire signed [7:0]   q_yq;
wire signed [15:0]  q_ydq;
wire        q_y_vld;
wire        q_clipped_last;
wire        q_udf_sticky;
wire [7:0]  q_clip_count;
wire [31:0] q_cfg_id;
wire signed [7:0]   cv_y;
wire        cv_out_valid;
wire        cv_sat_last;
wire [7:0]  cv_clip_count;
wire signed [17:0]  cv_acc;
wire [15:0] cv_cfg_id;
wire signed [7:0]   bn_yw;
wire signed [15:0]  bn_yb;
wire        bn_y_vld;
wire        bn_oor;
wire [7:0]  bn_clip_count;
wire [31:0] bn_cfg_id;
wire [127:0] mac_acc;
wire [7:0]  mac_headroom;
wire [3:0]  mac_sat;
wire [7:0]  mac_clip_count;
wire [31:0] mac_geom_id;
wire signed [11:0] tk_t0;
wire signed [11:0] tk_t1;
wire signed [11:0] tk_t2;
wire signed [11:0] tk_t3;
wire [3:0]  tk_i0;
wire [3:0]  tk_i1;
wire [3:0]  tk_i2;
wire [3:0]  tk_i3;
wire        tk_v0;
wire        tk_done;
wire [7:0]  tk_drop_count;
wire [7:0]  tk_rep_count;
wire [31:0] tk_cfg_id;
wire [31:0] bt_product;
wire        bt_ovf;
wire        bt_valid;
wire        bt_busy;
wire [7:0]  bt_err_start;
wire [31:0] ct_diff_acc;
wire [11:0] ct_match_cnt;
wire [11:0] ct_mismatch_cnt;
wire        ct_len_err;
wire        ct_cmp_done;
wire [3:0]  cg_bin_ptr;
wire [3:0]  cg_bin_dec;
wire        cg_err_sticky;
wire [3:0]  cg_err_count;
wire [3:0]  cg_sync_count;
wire [15:0] gen_beats;
wire [31:0] gen_lfsr;
wire [15:0] cnt_audio;
wire [15:0] cnt_quant;
wire [15:0] cnt_conv;
wire [15:0] cnt_bn;
wire [15:0] cnt_mac;
wire [15:0] cnt_rank;
wire [15:0] cnt_cross;

// Geometry readbacks, taken from each core's own cfg/geom encoding, not from the
// bundle: they are what a licensee reads back over the integration.
localparam [31:0] Q_CFG_ID  = 32'h0C0C_089A;
localparam [15:0] CV_CFG_ID = 16'h0408;
localparam [31:0] BN_CFG_ID = 32'h0908_102C;
localparam [31:0] TK_CFG_ID = 32'h0C10_047D;
localparam [31:0] MAC_GEOM  = 32'h0420_02B7;

// Distance the destination view of the crossing pointer may lag the source view.
// bin_ptr moves on an enabled beat inside a bc[3] window; gray_q moves with it.
// cg_dst_tick = bc[5] is a level that is high for 16 of every 32 beats, and the
// destination needs two of those observations (sync1 then sync2), so the closed
// bound is 16 + 16 + the sampling beat itself.
localparam integer LAG_MAX = 40;

ips_series_nn_front dut (
    .clk                (ips_clk),
    .clk_en             (clk_en),
    .rst_n              (rst_n),
    .pdm_pcm            (pdm_pcm),
    .pdm_pcm_hr         (pdm_pcm_hr),
    .pdm_pcm_valid      (pdm_pcm_valid),
    .pdm_sat_sticky     (pdm_sat_sticky),
    .pdm_out_count      (pdm_out_count),
    .pdm_phase          (pdm_phase),
    .ram_r0_data        (ram_r0_data),
    .ram_r1_data        (ram_r1_data),
    .ram_r0_valid       (ram_r0_valid),
    .ram_r1_valid       (ram_r1_valid),
    .ram_hit_count      (ram_hit_count),
    .ram_guard_count    (ram_guard_count),
    .ram_read_count     (ram_read_count),
    .ram_write_count    (ram_write_count),
    .ram_collide_count  (ram_collide_count),
    .ram_conflict_sticky(ram_conflict_sticky),
    .q_yq               (q_yq),
    .q_ydq              (q_ydq),
    .q_y_vld            (q_y_vld),
    .q_clipped_last     (q_clipped_last),
    .q_udf_sticky       (q_udf_sticky),
    .q_clip_count       (q_clip_count),
    .q_cfg_id           (q_cfg_id),
    .cv_y               (cv_y),
    .cv_out_valid       (cv_out_valid),
    .cv_sat_last        (cv_sat_last),
    .cv_clip_count      (cv_clip_count),
    .cv_acc             (cv_acc),
    .cv_cfg_id          (cv_cfg_id),
    .bn_yw              (bn_yw),
    .bn_yb              (bn_yb),
    .bn_y_vld           (bn_y_vld),
    .bn_oor             (bn_oor),
    .bn_clip_count      (bn_clip_count),
    .bn_cfg_id          (bn_cfg_id),
    .mac_acc            (mac_acc),
    .mac_headroom       (mac_headroom),
    .mac_sat            (mac_sat),
    .mac_clip_count     (mac_clip_count),
    .mac_geom_id        (mac_geom_id),
    .tk_t0              (tk_t0),
    .tk_t1              (tk_t1),
    .tk_t2              (tk_t2),
    .tk_t3              (tk_t3),
    .tk_i0              (tk_i0),
    .tk_i1              (tk_i1),
    .tk_i2              (tk_i2),
    .tk_i3              (tk_i3),
    .tk_v0              (tk_v0),
    .tk_done            (tk_done),
    .tk_drop_count      (tk_drop_count),
    .tk_rep_count       (tk_rep_count),
    .tk_cfg_id          (tk_cfg_id),
    .bt_product         (bt_product),
    .bt_ovf             (bt_ovf),
    .bt_valid           (bt_valid),
    .bt_busy            (bt_busy),
    .bt_err_start       (bt_err_start),
    .ct_diff_acc        (ct_diff_acc),
    .ct_match_cnt       (ct_match_cnt),
    .ct_mismatch_cnt    (ct_mismatch_cnt),
    .ct_len_err         (ct_len_err),
    .ct_cmp_done        (ct_cmp_done),
    .cg_bin_ptr         (cg_bin_ptr),
    .cg_bin_dec         (cg_bin_dec),
    .cg_err_sticky      (cg_err_sticky),
    .cg_err_count       (cg_err_count),
    .cg_sync_count      (cg_sync_count),
    .gen_beats          (gen_beats),
    .gen_lfsr           (gen_lfsr),
    .cnt_audio          (cnt_audio),
    .cnt_quant          (cnt_quant),
    .cnt_conv           (cnt_conv),
    .cnt_bn             (cnt_bn),
    .cnt_mac            (cnt_mac),
    .cnt_rank           (cnt_rank),
    .cnt_cross          (cnt_cross)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer ln;
integer lag;
integer tb_trace_mac;
integer tb_trace_at;
reg       bad;
reg       any_valid;

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b1;
    gate_hold   = 8'd0;
    hold_audio  = 16'd0;
    hold_mac    = 16'd0;
    bad         = 1'b0;
    any_valid   = 1'b0;
    lag         = 0;
    tb_trace_mac = 0;
    tb_trace_at  = 0;

    repeat (6) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(negedge ips_clk);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        // Series-level clk_en discipline: park the whole subsystem for three clocks
        // every 251st beat and require the enabled-beat state to survive it.
        if ((i % 251) == 100) begin
            hold_audio = cnt_audio;
            hold_mac   = cnt_mac;
            clk_en     = 1'b0;
            gate_hold  = 8'd3;
        end
        if (gate_hold != 8'd0) begin
            gate_hold = gate_hold - 8'd1;
            if ((gate_hold == 8'd0) && clk_en !== 1'b1) begin
                if (cnt_audio !== hold_audio || cnt_mac !== hold_mac) begin
                    bad = 1'b1;
                end
                clk_en = 1'b1;
            end
        end

        // X freedom over every observation group (docs/IP_CORE_SOP.md trap T6).
        if ((^{pdm_pcm, pdm_pcm_hr, pdm_pcm_valid, pdm_sat_sticky, pdm_out_count,
              pdm_phase}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{ram_r0_data, ram_r1_data, ram_r0_valid, ram_r1_valid, ram_hit_count,
              ram_guard_count, ram_read_count, ram_write_count, ram_collide_count,
              ram_conflict_sticky}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{q_yq, q_ydq, q_y_vld, q_clipped_last, q_udf_sticky, q_clip_count,
              q_cfg_id, cv_y, cv_out_valid, cv_sat_last, cv_clip_count, cv_acc,
              cv_cfg_id}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{bn_yw, bn_yb, bn_y_vld, bn_oor, bn_clip_count, bn_cfg_id}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{mac_acc, mac_headroom, mac_sat, mac_clip_count, mac_geom_id}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{tk_t0, tk_t1, tk_t2, tk_t3, tk_i0, tk_i1, tk_i2, tk_i3, tk_v0,
              tk_done, tk_drop_count, tk_rep_count, tk_cfg_id}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{bt_product, bt_ovf, bt_valid, bt_busy, bt_err_start, ct_diff_acc,
              ct_match_cnt, ct_mismatch_cnt, ct_len_err, ct_cmp_done}) === 1'bx) begin
            bad = 1'b1;
        end
        if ((^{cg_bin_ptr, cg_bin_dec, cg_err_sticky, cg_err_count, cg_sync_count,
              gen_beats, gen_lfsr, cnt_audio, cnt_quant, cnt_conv, cnt_bn, cnt_mac,
              cnt_rank, cnt_cross}) === 1'bx) begin
            bad = 1'b1;
        end

        // Geometry readback: the wrappers must report the geometry the library was
        // packaged with, otherwise the lane and window checks below are statements
        // about a different core.
        if (q_cfg_id !== Q_CFG_ID) begin
            bad = 1'b1;
        end
        if (cv_cfg_id !== CV_CFG_ID) begin
            bad = 1'b1;
        end
        if (bn_cfg_id !== BN_CFG_ID) begin
            bad = 1'b1;
        end
        if (tk_cfg_id !== TK_CFG_ID) begin
            bad = 1'b1;
        end
        if (mac_geom_id !== MAC_GEOM) begin
            bad = 1'b1;
        end

        // Contract invariants: each of these is a flag a core raises only when the
        // integrator broke its documented rule, never from legitimate data.
        if (ram_collide_count !== 8'h00 || ram_conflict_sticky !== 1'b0) begin
            bad = 1'b1;
        end
        if (cg_err_sticky !== 1'b0 || cg_err_count !== 4'h0) begin
            bad = 1'b1;
        end
        if (ct_len_err !== 1'b0) begin
            bad = 1'b1;
        end
        if (bt_err_start !== 8'h00) begin
            bad = 1'b1;
        end

        // MAC array lane contract: a saturated lane sits exactly on the rail named
        // by its own guard bit, and a lane that did not saturate reports its
        // headroom as the sign extension of its accumulator.
        for (ln = 0; ln < 4; ln = ln + 1) begin
            if (mac_sat[ln]) begin
                if (mac_acc[ln * 32 +: 32] !==
                    (mac_headroom[ln * 2 + 1] ? 32'h8000_0000 : 32'h7FFF_FFFF)) begin
                    bad = 1'b1;
                end
            end else if (mac_headroom[ln * 2 +: 2] !==
                         {2{mac_acc[ln * 32 + 31]}}) begin
                bad = 1'b1;
            end
        end

        // Ranking contract: the four stored candidates stay in descending order at
        // all times, including while the tree is still filling with MIN_SCORE slots.
        if (!(tk_t0 >= tk_t1 && tk_t1 >= tk_t2 && tk_t2 >= tk_t3)) begin
            bad = 1'b1;
        end

        // Stage ledger.  The decimator publishes one sample every R_RATE enabled
        // clocks, the quantiser and the BN fold echo in_valid one beat later, and
        // the convolver closes one window per sample, so every stage count equals
        // its producer's count minus at most the single sample in flight.
        if (cnt_quant > cnt_audio || (cnt_audio - cnt_quant) > 16'd1) begin
            bad = 1'b1;
        end
        if (cnt_conv > cnt_quant || (cnt_quant - cnt_conv) > 16'd1) begin
            bad = 1'b1;
        end
        if (cnt_bn > cnt_conv || (cnt_conv - cnt_bn) > 16'd1) begin
            bad = 1'b1;
        end
        // The array must not lose a BN publish on the way in.
        if (cnt_mac !== cnt_bn) begin
            bad = 1'b1;
        end
        // The decimator counts its own publishes, so its counter and the bundle's
        // ledger are two independent views of the same event stream.  The core's
        // counter is updated with the publish itself while the ledger sees the
        // published beat, so the core may lead by exactly one; it may never trail,
        // and the run stays under 256 samples where its 8-bit counter has not
        // clamped.
        if (pdm_out_count < cnt_audio[7:0] ||
            (pdm_out_count - cnt_audio[7:0]) > 8'd1) begin
            bad = 1'b1;
        end
        // Sixteen scored beats make one ranked vector and done is registered, so
        // the array may be ahead of the ranker by less than a vector.
        if (cnt_mac < (cnt_rank * 16'd16) ||
            (cnt_mac - (cnt_rank * 16'd16)) > 16'd17) begin
            bad = 1'b1;
        end
        // One crossing step per consumed publish, so the source pointer must equal
        // the number of steps the bundle issued, modulo the wrap.
        if (cg_bin_ptr !== cnt_cross[3:0]) begin
            bad = 1'b1;
        end

        // The destination view may lag by the two synchroniser observations plus the
        // tick alignment, and must close the gap without a new publish.
        if (cg_bin_dec !== cg_bin_ptr) begin
            lag = lag + 1;
            if (lag > LAG_MAX) begin
                bad = 1'b1;
            end
        end else begin
            lag = 0;
        end

        // Liveness on the last beat that actually moved the pipeline: the chain runs
        // at one sample per R_RATE clocks, so a stall of this many beats is a break.
        if (cnt_mac != tb_trace_mac) begin
            tb_trace_mac = cnt_mac;
            tb_trace_at  = i;
        end else if ((i - tb_trace_at) > 300) begin
            bad = 1'b1;
        end

        if (pdm_pcm_valid === 1'b1 || cv_out_valid === 1'b1) begin
            any_valid = 1'b1;
        end

        // Bundle observation contract, one documented group per fold, each 32 bits.
        ips_fnv_word({13'd0, pdm_pcm_hr, pdm_pcm_valid, pdm_sat_sticky,
                      pdm_phase, pdm_out_count});
        ips_fnv_word({16'd0, pdm_pcm});
        ips_fnv_word(ram_r0_data);
        ips_fnv_word(ram_r1_data);
        ips_fnv_word({16'd0, ram_collide_count, ram_write_count});
        ips_fnv_word({13'd0, ram_conflict_sticky, ram_r0_valid, ram_r1_valid,
                      ram_guard_count, ram_hit_count});
        ips_fnv_word(ram_read_count);
        ips_fnv_word({13'd0, q_yq, q_clipped_last, q_udf_sticky, q_y_vld,
                      q_clip_count});
        ips_fnv_word({16'd0, q_ydq});
        ips_fnv_word(q_cfg_id);
        ips_fnv_word({14'd0, cv_y, cv_sat_last, cv_out_valid, cv_clip_count});
        ips_fnv_word({14'd0, cv_acc});
        ips_fnv_word({16'd0, cv_cfg_id});
        ips_fnv_word({16'd0, bn_yb});
        ips_fnv_word({14'd0, bn_yw, bn_oor, bn_y_vld, bn_clip_count});
        ips_fnv_word(bn_cfg_id);
        ips_fnv_word(mac_acc[31:0]);
        ips_fnv_word(mac_acc[63:32]);
        ips_fnv_word(mac_acc[95:64]);
        ips_fnv_word(mac_acc[127:96]);
        ips_fnv_word({24'd0, mac_headroom});
        ips_fnv_word({20'd0, mac_sat, mac_clip_count});
        ips_fnv_word(mac_geom_id);
        ips_fnv_word({8'd0, tk_t1, tk_t0});
        ips_fnv_word({8'd0, tk_t3, tk_t2});
        ips_fnv_word({16'd0, tk_i3, tk_i2, tk_i1, tk_i0});
        ips_fnv_word({14'd0, tk_v0, tk_done, tk_drop_count, tk_rep_count});
        ips_fnv_word(tk_cfg_id);
        ips_fnv_word(bt_product);
        ips_fnv_word({21'd0, bt_ovf, bt_valid, bt_busy, bt_err_start});
        ips_fnv_word(ct_diff_acc);
        ips_fnv_word({8'd0, ct_match_cnt, ct_mismatch_cnt});
        ips_fnv_word({30'd0, ct_len_err, ct_cmp_done});
        ips_fnv_word({15'd0, cg_sync_count, cg_err_count, cg_err_sticky,
                      cg_bin_dec, cg_bin_ptr});
        ips_fnv_word(gen_lfsr);
        ips_fnv_word({gen_beats, 16'd0});
        ips_fnv_word({cnt_audio, cnt_quant});
        ips_fnv_word({cnt_conv, cnt_bn});
        ips_fnv_word({cnt_mac, cnt_rank});
        ips_fnv_word({cnt_cross, 8'd0, pdm_out_count});
    end

    repeat (4) @(negedge ips_clk);

    // Every stage of the chain must have carried samples, and the run must have been
    // long enough to complete and cross more than one ranked vector.
    if (cnt_audio === 16'd0 || cnt_quant === 16'd0 || cnt_conv === 16'd0 ||
        cnt_bn === 16'd0 || cnt_mac === 16'd0 || cnt_rank < 16'd3 ||
        cnt_cross < 16'd3 || ram_read_count === 16'd0 || !any_valid) begin
        bad = 1'b1;
    end
    if (ram_write_count < 8'd16) begin
        bad = 1'b1;
    end
    // The chain must still be coherent at the end: the source pointer is exactly the
    // number of crossings, and the destination view has caught up.
    if (cg_bin_ptr !== cnt_cross[3:0] || cg_bin_dec !== cg_bin_ptr) begin
        bad = 1'b1;
    end

    ips_fnv_word({cnt_audio, cnt_mac});
    ips_fnv_word({cnt_rank, cnt_cross});
    ips_fnv_word(gen_lfsr);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_series_nn_front");
end

endmodule
