`timescale 1ns / 1ps
// tb_ips_perf_event_ctr : production-line testbench for the eight-channel programmable
// event counter instrument.
//
// FOLD RULE (stated identically in models/ips_perf_event_ctr.py): for every one of
// BEATS beats fold, in this order, the eight counter bytes LSB-first as
// {24'd0, cnt[8j+7 -: 8]} for j = 0..7, then the eight shadow bytes in the same order,
// then {16'd0, ev, ovf}, then {16'd0, wrap, ov_seq}, then {28'd0, snap_n}.  After the
// beat loop (the inputs are idle by then) fold {24'd0, ov_seq}, {24'd0, snap_n} and
// BEATS.  Every word goes through ips_fnv_word, MSB byte first.  Nothing from the RTL
// expectation is copied into the model: the model re-derives the same words from the
// documented semantics (docs/IP_CORE_SOP.md trap T1).
//
// STIMULUS CONTRACT (deterministic, one LCG step per beat, state[0] = SEED):
//   state = state * 32'd1664525 + 32'd1013904223
//   en      = (i % 150) < 120                       counted windows / hold windows
//   strb    = state[3:0], except the scripted beats below
//   cfg_we  = (i % 64) < 4 with cfg_idx = i % 4      only channels 0..3 are programmed
//   cfg_amask = {4'h0, state[7:4]}, cfg_omask = {4'h0, state[11:8]}
//   cnt_we  = 1 at 96..99 (channels 0..3 := 8'hF0..8'hFC), at 300..303
//             (channels 0..3 := 8'hFF..8'hFC) and at 155 (channel 0 := 8'hFF)
//   snap    = (i % 32) == 7
//   clr     = i == 250 (counting) and i == 430 (during a hold window)
//   ov_clr  = i == 156, 200, 400
//   scripted determinism: at 128 channel 0 is programmed to AM=4'b0001 / OM=4'b0000,
//     at 155 it is preset to 8'hFF, at 156 strb is forced to 4'b0001 and ov_clr is
//     asserted at the same beat, so channel 0 MUST wrap while its flags are being
//     cleared - the sticky set has priority.  strb is forced to 4'b1111 at 200..203
//     (full AND group) and to 4'b0000 at 330..335 (empty strobe bus).
//
// Sampling: one enabled posedge per beat.  The stimulus is applied at a negedge and the
// registered outputs are sampled at the following negedge, before the next stimulus is
// driven, so every folded word is the state produced by the stimulus of that beat.
module tb_ips_perf_event_ctr;

`include "ips_tb_common.vh"

localparam integer BEATS = 480;
localparam [31:0]  SEED  = 32'h5A17C0DE;

// The wrap threshold, stated here from the documented contract and NOT read from the
// DUT: the registered wrap strobe may only appear on a real 8'hFF -> 8'h00 rollover.
// The shipped group masks of channels 4..7 are deliberately NOT restated here: the
// testbench proves the invariants (event select of the channels it programmed itself,
// hold, snapshot atomicity, sticky overflow, strobe purity) while the independent model
// pins the absolute value of every folded word, so a mutated default shows up as a
// digest change rather than only as a failed assertion.
localparam [7:0] T_WRAP = 8'hFF;

reg         rst_n;
reg         clk_en;
reg         en;
reg  [3:0]  strb;
reg         cfg_we;
reg  [2:0]  cfg_idx;
reg  [7:0]  cfg_amask;
reg  [7:0]  cfg_omask;
reg         cnt_we;
reg  [2:0]  cnt_widx;
reg  [7:0]  cnt_wval;
reg         snap;
reg         clr;
reg         ov_clr;
reg  [31:0] state;

wire [63:0] cnt;
wire [63:0] shd;
wire [7:0]  ev;
wire [7:0]  wrap;
wire [7:0]  ovf;
wire [7:0]  ov_seq;
wire [3:0]  snap_n;

// No #() override here: the testbench exercises the core's declared default geometry,
// which is the configuration the shipped manifest records.
ips_perf_event_ctr dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .en        (en),
    .strb      (strb),
    .cfg_we    (cfg_we),
    .cfg_idx   (cfg_idx),
    .cfg_amask (cfg_amask),
    .cfg_omask (cfg_omask),
    .cnt_we    (cnt_we),
    .cnt_widx  (cnt_widx),
    .cnt_wval  (cnt_wval),
    .snap      (snap),
    .clr       (clr),
    .ov_clr    (ov_clr),
    .cnt       (cnt),
    .shd       (shd),
    .ev        (ev),
    .wrap      (wrap),
    .ovf       (ovf),
    .ov_seq    (ov_seq),
    .snap_n    (snap_n)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer w;
reg     bad;
reg     ea;
reg     eo;
reg     inc;
reg     pset;

reg [63:0] pcnt;      // counter vector as folded one beat earlier
reg [63:0] tshd;      // expected shadow bank
reg [15:0] tam4;      // the groups this testbench wrote into channels 0..3
reg [15:0] tom4;
reg [3:0]  pstrb;     // previous beat's strobe bus, for the ev invariance check
reg [7:0]  pev;
reg        pcwe;      // previous beat carried a group-mask write
reg [7:0]  exp_wrap;
reg [7:0]  exp_ovf;
reg [63:0] exp_cnt;
reg [7:0]  tovf;
reg [7:0]  tovs;
reg [3:0]  tsnap;

task drive_beat;
    input integer b;
    begin
        if (b < 0 || b >= BEATS) begin
            en        = 1'b0;
            strb      = 4'h0;
            cfg_we    = 1'b0;
            cfg_idx   = 3'h0;
            cfg_amask = 8'h00;
            cfg_omask = 8'h00;
            cnt_we    = 1'b0;
            cnt_widx  = 3'h0;
            cnt_wval  = 8'h00;
            snap      = 1'b0;
            clr       = 1'b0;
            ov_clr    = 1'b0;
        end else begin
            state     = state * 32'd1664525 + 32'd1013904223;
            en        = (b % 150) < 120;
            strb      = state[3:0];
            cfg_we    = ((b % 64) < 4);
            cfg_idx   = b % 4;
            cfg_amask = {4'h0, state[7:4]};
            cfg_omask = {4'h0, state[11:8]};
            cnt_we    = 1'b0;
            cnt_widx  = 3'h0;
            cnt_wval  = 8'h00;
            if (b >= 96 && b <= 99) begin
                cnt_we   = 1'b1;
                cnt_widx = b - 96;
                cnt_wval = 8'hF0 + (b - 96);
            end
            if (b >= 300 && b <= 303) begin
                cnt_we   = 1'b1;
                cnt_widx = b - 300;
                cnt_wval = 8'hFF - (b - 300);
            end
            if (b == 155) begin
                cnt_we   = 1'b1;
                cnt_widx = 3'h0;
                cnt_wval = 8'hFF;
            end
            snap   = ((b % 32) == 7);
            clr    = (b == 250) || (b == 430);
            ov_clr = (b == 156) || (b == 200) || (b == 400);
            if (b == 128) begin
                cfg_we    = 1'b1;
                cfg_idx   = 3'h0;
                cfg_amask = 8'h01;
                cfg_omask = 8'h00;
            end
            if (b == 156) begin
                strb = 4'b0001;
            end
            if (b >= 200 && b < 204) begin
                strb = 4'b1111;
            end
            if (b >= 330 && b < 336) begin
                strb = 4'b0000;
            end
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    state     = SEED;
    bad       = 1'b0;
    drive_beat(-1);

    pcnt      = 64'h0;
    tshd      = 64'h0;
    tam4      = 16'h0000;
    tom4      = 16'h0000;
    pstrb     = 4'h0;
    pcwe      = 1'b0;
    pev       = 8'h00;
    tovf      = 8'h00;
    tovs      = 8'h00;
    tsnap     = 4'h0;

    repeat (4) @(posedge ips_clk);
    @(negedge ips_clk);
    rst_n = 1'b1;
    @(negedge ips_clk);
    drive_beat(0);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);             // the enabled posedge of this beat is done

        if ((^cnt === 1'bx) || (^shd === 1'bx) || (^ev === 1'bx) || (^wrap === 1'bx)
            || (^ovf === 1'bx) || (^ov_seq === 1'bx) || (^snap_n === 1'bx)) begin
            bad = 1'b1;
        end

        // --- event select of the programmable channels: the AND of group one and the
        //     OR of group two, computed here from the masks this testbench wrote.
        //     Channels 4..7 keep the core's shipped groups, whose absolute behaviour is
        //     pinned by the independent golden model instead of being restated here. ---
        for (w = 0; w < 4; w = w + 1) begin
            ea       = ((strb & tam4[w*4 +: 4]) == tam4[w*4 +: 4]);
            eo       = (tom4[w*4 +: 4] == 4'h0) || ((strb & tom4[w*4 +: 4]) != 4'h0);
            if (ev[w] !== (ea && eo)) begin
                bad = 1'b1;
            end
        end

        // --- counter update consistency, keyed on the core's own event vector:
        //     clr > preset > increment, and with en low every counter HOLDS.  Each byte
        //     is checked on its own, so a busy channel cannot perturb an idle one. ---
        for (w = 0; w < 8; w = w + 1) begin
            inc  = en && ev[w];
            pset = cnt_we && (cnt_widx == w);
            if (clr) begin
                exp_cnt[w*8 +: 8] = 8'h00;
            end else if (pset) begin
                exp_cnt[w*8 +: 8] = cnt_wval;
            end else if (inc) begin
                exp_cnt[w*8 +: 8] = pcnt[w*8 +: 8] + 8'h01;
            end else begin
                exp_cnt[w*8 +: 8] = pcnt[w*8 +: 8];
            end
            // the wrap strobe is the registered 8'hFF -> 8'h00 rollover of this edge
            exp_wrap[w] = inc && !clr && !pset && (pcnt[w*8 +: 8] === T_WRAP);
            // sticky flag: a wrap sets, ov_clr clears, a same-beat wrap still sets
            if (wrap[w]) begin
                exp_ovf[w] = 1'b1;
            end else if (ov_clr) begin
                exp_ovf[w] = 1'b0;
            end else begin
                exp_ovf[w] = tovf[w];
            end
        end
        if (cnt !== exp_cnt) begin
            bad = 1'b1;
        end
        if (wrap !== exp_wrap) begin
            bad = 1'b1;
        end
        if (ovf !== exp_ovf) begin
            bad = 1'b1;
        end
        // the event vector is a pure function of the strobe bus and the groups: the
        // same strobes with no config write must not change it
        if (i > 0 && strb === pstrb && !cfg_we && !pcwe && ev !== pev) begin
            bad = 1'b1;
        end

        // --- snapshot is atomic and never loses a count ---
        if (snap) begin
            if (shd !== pcnt) begin
                bad = 1'b1;
            end
            tshd = pcnt;
        end else if (shd !== tshd) begin
            bad = 1'b1;
        end

        // --- wrap beats advance ov_seq exactly once, snapshots advance snap_n ---
        if (|wrap) begin
            if (ov_seq !== (tovs + 8'h01)) begin
                bad = 1'b1;
            end
        end else if (ov_seq !== tovs) begin
            bad = 1'b1;
        end
        if (snap) begin
            if (snap_n !== (tsnap + 4'h1)) begin
                bad = 1'b1;
            end
        end else if (snap_n !== tsnap) begin
            bad = 1'b1;
        end

        // --- scripted determinism: sticky overflow wins over the same-beat clear ---
        if (i == 155 && cnt[7:0] !== 8'hFF) begin
            bad = 1'b1;
        end
        if (i == 156 && (cnt[7:0] !== 8'h00 || ovf[0] !== 1'b1 || wrap[0] !== 1'b1)) begin
            bad = 1'b1;
        end
        if (i == 157 && ovf[0] !== 1'b1) begin
            bad = 1'b1;
        end
        if (i == 250 && cnt !== 64'h0) begin
            bad = 1'b1;
        end

        // --- fold in the documented order ---
        for (w = 0; w < 8; w = w + 1) begin
            ips_fnv_word({24'd0, cnt[w*8 +: 8]});
        end
        for (w = 0; w < 8; w = w + 1) begin
            ips_fnv_word({24'd0, shd[w*8 +: 8]});
        end
        ips_fnv_word({16'd0, ev, ovf});
        ips_fnv_word({16'd0, wrap, ov_seq});
        ips_fnv_word({28'd0, snap_n});

        // --- carry the expectation one beat forward ---
        pcnt  = cnt;
        tovf  = ovf;
        tovs  = ov_seq;
        tsnap = snap_n;
        pstrb = strb;
        pev   = ev;
        pcwe  = cfg_we;
        if (cfg_we && cfg_idx < 4) begin
            tam4[cfg_idx*4 +: 4] = cfg_amask[3:0];
            tom4[cfg_idx*4 +: 4] = cfg_omask[3:0];
        end

        drive_beat(i + 1);
    end

    repeat (6) @(negedge ips_clk);
    // the idle tail must not move anything: no silent clear, no phantom count
    if (ovf !== tovf || cnt !== pcnt || ov_seq !== tovs || wrap !== 8'h00) begin
        bad = 1'b1;
    end
    ips_fnv_word({24'd0, ov_seq});
    ips_fnv_word({24'd0, snap_n});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_perf_event_ctr");
end

endmodule
