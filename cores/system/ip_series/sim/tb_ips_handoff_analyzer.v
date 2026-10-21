`timescale 1ns / 1ps
// tb_ips_handoff_analyzer : production-line testbench for the valid/ready burst analyser.
//
// FOLDING RULE (mirrored independently by models/ips_handoff_analyzer.py -- trap T1):
// one FNV-1a word stream, MSB byte first.  Every beat folds, in this order,
//   0 hnd, 1 dead, 2 stall, 3 mxstall, 4 undr, 5 ovr, 6 flags,
//   7 lhnd, 8 ldead, 9 lmxstall, 10 lundr, 11 lovr, 12 lflags,
//   13 burst_n, 14 top_hnd, 15 {30'd0, busy, done}.
// After the beat loop (the inputs are idle by then) fold burst_n, top_hnd, lhnd,
// lmxstall and BEATS.  Nothing from the RTL is copied into the model: the model
// re-derives every word from the written burst/handoff/dead/overrun/underrun contract.
//
// BEAT CONTRACT.  One iteration is one clock period: the plan for beat n is driven at a
// falling edge, the rising edge in the middle applies it, and the next falling edge
// observes the registered result.  clk_en is low for two windows (116..123, inside a
// long stall, and 295..298, in the idle tail), so a register that missed its clk_en
// gate cannot survive.  Stimulus is the scripted burst plan below plus the shared LCG,
// state = state*32'd1664525 + 32'd1013904223, advanced exactly once per beat index, so
// the golden model can reproduce the stream without this file.
//
// COVERAGE.  Ten bursts, deliberately: a clean burst with ZERO dead cycles (observed
// 7..27, eighteen handoffs), a burst whose longest stall run is eight beats and is
// therefore the recorded maximum (36..43), an overrun (the producer withdraws valid at
// beat 49 after beat 48 was presented and not accepted), underruns (ready with no valid
// inside the open window at 65..67, 90..95, 246, 249..256), a burst that books no
// handoff at all (90..95), back-to-back bursts separated by a single idle beat (75..80
// then 81..88, and 228/230) so per-burst counters must reset and never leak across, a
// burst long enough to saturate the dead/stall accounting (100..197), a burst mixing a
// four-beat stall, three-beat stalls and an underrun (212..246), and one burst of random
// traffic from the LCG (277..291).  Beats 28, 70, 96, 198 and 229 additionally pin the
// ledger against counts read off the stimulus table itself (not out of the RTL).
//
// CHECKS are invariants and stimulus-derived absolutes: the window level and its
// opening/closing strobes, burst_n stepping exactly on a closing beat, same-beat booking
// and re-zero of the ledger, per-burst counters that step by at most one and hold when
// their event is absent, the ledger frozen off a closing beat, flags sticky inside a
// burst and raisable only by an observed beat, the stall run versus the dead total, the
// handoff high-water mark, and the freeze of every folded word on a disabled beat.  All
// use === / !== so an unknown can never look like a pass (trap T6).
module tb_ips_handoff_analyzer;

`include "ips_tb_common.vh"

localparam integer BEATS = 300;
localparam [31:0]  SEED  = 32'h1A2B_3C4D;

reg         rst_n_tb;
reg         clk_en;
reg         win;
reg         valid;
reg         ready;
reg  [31:0] state;

wire [7:0]  hnd;
wire [7:0]  dead;
wire [7:0]  stall;
wire [7:0]  mxstall;
wire [7:0]  undr;
wire [7:0]  ovr;
wire [7:0]  flags;
wire [7:0]  lhnd;
wire [7:0]  ldead;
wire [7:0]  lmxstall;
wire [7:0]  lundr;
wire [7:0]  lovr;
wire [7:0]  lflags;
wire [7:0]  burst_n;
wire [7:0]  top_hnd;
wire        busy;
wire        done;
wire        opening_r;

// No #() override: the core's declared constants are the shipped configuration and the
// mutation station mutates them, so overriding here would hide them.
ips_handoff_analyzer dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n_tb),
    .win       (win),
    .valid     (valid),
    .ready     (ready),
    .hnd       (hnd),
    .dead      (dead),
    .stall     (stall),
    .mxstall   (mxstall),
    .undr      (undr),
    .ovr       (ovr),
    .flags     (flags),
    .lhnd      (lhnd),
    .ldead     (ldead),
    .lmxstall  (lmxstall),
    .lundr     (lundr),
    .lovr      (lovr),
    .lflags    (lflags),
    .burst_n   (burst_n),
    .top_hnd   (top_hnd),
    .busy      (busy),
    .done      (done),
    .opening_r (opening_r)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// ---------------------------------------------------------------------------
// planned inputs for beat n -- the same burst plan is written out independently in
// models/ips_handoff_analyzer.py
// ---------------------------------------------------------------------------
task plan;
    input integer n;
    begin
        state = state * 32'd1664525 + 32'd1013904223;
        win   = 1'b0;
        valid = 1'b0;
        ready = 1'b0;
        clk_en = 1'b1;
        if ((n >= 116 && n <= 123) || (n >= 295 && n <= 298)) clk_en = 1'b0;

        if (n >= 6 && n <= 8) begin
            win = 1'b1;
        end else if (n >= 9 && n <= 26) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 27) begin
            win = 1'b1;
        end else if (n >= 31 && n <= 34) begin
            win = 1'b1; valid = 1'b1;
        end else if (n == 35) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n >= 36 && n <= 43) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 44 && n <= 47) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 48) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 49 && n <= 64) begin
            win = 1'b1;
        end else if (n >= 65 && n <= 67) begin
            win = 1'b1; ready = 1'b1;
        end else if (n >= 68 && n <= 69) begin
            win = 1'b1;
        end else if (n >= 75 && n <= 79) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 80) begin
            valid = 1'b1; ready = 1'b1;
        end else if (n >= 81 && n <= 87) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n >= 89 && n <= 95) begin
            win = 1'b1; ready = 1'b1;
        end else if (n == 99) begin
            win = 1'b1;
        end else if (n >= 100 && n <= 190) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 191 && n <= 196) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 197) begin
            win = 1'b1;
        end else if (n >= 211 && n <= 214) begin
            win = 1'b1; valid = 1'b1;
        end else if (n == 215) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n >= 216 && n <= 218) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 219 && n <= 222) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n >= 223 && n <= 226) begin
            win = 1'b1; valid = 1'b1;
        end else if (n == 227) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 228) begin
            win = 1'b1; valid = 1'b1;
        end else if (n == 230) begin
            win = 1'b1;
        end else if (n >= 231 && n <= 238) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 239 && n <= 245) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 246) begin
            win = 1'b1; ready = 1'b1;
        end else if (n == 248) begin
            win = 1'b1;
        end else if (n >= 249 && n <= 256) begin
            win = 1'b1; ready = 1'b1;
        end else if (n >= 257 && n <= 264) begin
            win = 1'b1; valid = 1'b1;
        end else if (n >= 265 && n <= 273) begin
            win = 1'b1; valid = 1'b1; ready = 1'b1;
        end else if (n == 274) begin
            win = 1'b1;
        end else if (n >= 276 && n <= 291) begin
            win   = 1'b1;
            valid = state[0];
            ready = state[5];
        end
    end
endtask

// ---------------------------------------------------------------------------
// previous-beat copies for the freeze / monotone / booking checks
// ---------------------------------------------------------------------------
integer i;
reg        bad;
reg        p_busy, p_obs, p_valid, p_ready, p_done, p_openr;
reg [7:0]  p_hnd, p_dead, p_stall, p_mx, p_undr, p_ovr, p_flags;
reg [7:0]  p_lhnd, p_ldead, p_lmx, p_lundr, p_lovr, p_lflags;
reg [7:0]  p_bn, p_top;
reg        obs, hnd_e, stl_e, und_e, ovr_e, cl_b;

initial begin
    ips_fnv_reset();
    rst_n_tb = 1'b0;
    clk_en   = 1'b0;
    win      = 1'b0;
    valid    = 1'b0;
    ready    = 1'b0;
    state    = SEED;
    bad      = 1'b0;
    p_busy   = 1'b0;
    p_obs    = 1'b0;
    p_valid  = 1'b0;
    p_ready  = 1'b0;
    p_done   = 1'b0;
    p_openr  = 1'b0;
    p_hnd    = 8'h00;
    p_dead   = 8'h00;
    p_stall  = 8'h00;
    p_mx     = 8'h00;
    p_undr   = 8'h00;
    p_ovr    = 8'h00;
    p_flags  = 8'h00;
    p_lhnd   = 8'h00;
    p_ldead  = 8'h00;
    p_lmx    = 8'h00;
    p_lundr  = 8'h00;
    p_lovr   = 8'h00;
    p_lflags = 8'h00;
    p_bn     = 8'h00;
    p_top    = 8'h00;
    obs      = 1'b0;
    hnd_e    = 1'b0;
    stl_e    = 1'b0;
    und_e    = 1'b0;
    ovr_e    = 1'b0;
    cl_b     = 1'b0;

    repeat (4) @(negedge ips_clk);
    rst_n_tb = 1'b1;
    repeat (2) @(negedge ips_clk);

    plan(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        // ---- purity: nothing folded may be unknown ----------------------
        if (^{hnd, dead, stall, mxstall, undr, ovr, flags, lhnd, ldead, lmxstall,
              lundr, lovr, lflags, burst_n, top_hnd, busy, done, opening_r} === 1'bx) begin
            bad = 1'b1;
        end

        // ---- decode the beat that just ran, from the driven inputs ------
        obs       = p_busy & win;
        hnd_e     = obs & valid & ready;
        stl_e     = obs & valid & ~ready;
        und_e     = obs & ~valid & ready;
        ovr_e     = obs & ~valid & p_obs & p_valid & ~p_ready;
        cl_b      = p_busy & ~win;

        if (clk_en !== 1'b1) begin
            // ---- disabled beat: nothing counted may move ----------------
            if ({hnd, dead, stall, mxstall, undr, ovr, flags, lhnd, ldead, lmxstall,
                 lundr, lovr, lflags, burst_n, top_hnd, busy, done, opening_r}
                !== {p_hnd, p_dead, p_stall, p_mx, p_undr, p_ovr, p_flags, p_lhnd,
                     p_ldead, p_lmx, p_lundr, p_lovr, p_lflags, p_bn, p_top, p_busy,
                     p_done, p_openr}) begin
                bad = 1'b1;
            end
        end else begin
            // ---- window state machine -----------------------------------
            if (busy !== win) begin
                bad = 1'b1;
            end
            if (done !== cl_b) begin
                bad = 1'b1;
            end
            if (opening_r !== (win & ~p_busy)) begin
                bad = 1'b1;
            end
            if (burst_n !== (p_bn + (cl_b ? 8'h01 : 8'h00))) begin
                bad = 1'b1;
            end

            // ---- cross-word invariants ----------------------------------
            if (!(lhnd <= top_hnd)) begin
                bad = 1'b1;
            end
            if (!(lmxstall <= ldead)) begin
                bad = 1'b1;
            end
            if (!(stall <= dead)) begin
                bad = 1'b1;
            end
            if (!(mxstall <= dead)) begin
                bad = 1'b1;
            end

            if (cl_b) begin
                // the ledger books the burst on the SAME beat the live bank clears
                if (lhnd !== p_hnd) begin
                    bad = 1'b1;
                end
                if (ldead !== p_dead) begin
                    bad = 1'b1;
                end
                if (lundr !== p_undr) begin
                    bad = 1'b1;
                end
                if (lovr !== p_ovr) begin
                    bad = 1'b1;
                end
                if (lmxstall !== ((p_stall > p_mx) ? p_stall : p_mx)) begin
                    bad = 1'b1;
                end
                if ({hnd, dead, stall, mxstall, undr, ovr, flags} !== 56'd0) begin
                    bad = 1'b1;
                end
                // booked flags carry every live flag, and the verdict bits appear
                // exactly when the burst had no dead cycle or no handoff
                if ((lflags & p_flags) !== p_flags) begin
                    bad = 1'b1;
                end
                if ((lflags !== p_flags)
                        !== ((p_dead === 8'h00) || (p_hnd === 8'h00))) begin
                    bad = 1'b1;
                end
                if (top_hnd !== ((p_hnd > p_top) ? p_hnd : p_top)) begin
                    bad = 1'b1;
                end
            end else begin
                // ---- inside a burst: one step per event, hold otherwise --
                if (hnd !== (p_hnd + (hnd_e ? 8'h01 : 8'h00))) begin
                    bad = 1'b1;
                end
                if (undr !== (p_undr + (und_e ? 8'h01 : 8'h00))) begin
                    bad = 1'b1;
                end
                if (ovr !== (p_ovr + (ovr_e ? 8'h01 : 8'h00))) begin
                    bad = 1'b1;
                end
                if (dead !== p_dead && dead !== (p_dead + 8'h01)) begin
                    bad = 1'b1;
                end
                if (stl_e) begin
                    if (stall !== p_stall && stall !== (p_stall + 8'h01)) begin
                        bad = 1'b1;
                    end
                end else if (stall !== 8'h00) begin
                    bad = 1'b1;
                end
                if (mxstall !== p_mx) begin
                    if (mxstall !== p_stall || !(p_stall > p_mx)) begin
                        bad = 1'b1;
                    end
                end
                if ((flags & p_flags) !== p_flags) begin
                    bad = 1'b1;
                end
                if (flags !== p_flags && !obs) begin
                    bad = 1'b1;
                end
                if (top_hnd !== p_top) begin
                    bad = 1'b1;
                end
                if (lhnd !== p_lhnd || ldead !== p_ldead || lmxstall !== p_lmx
                        || lundr !== p_lundr || lovr !== p_lovr
                        || lflags !== p_lflags) begin
                    bad = 1'b1;
                end
            end

            // ---- ledger pinned against the stimulus table itself --------
            if (i == 28) begin
                // burst 1: observed 7..27, eighteen handoffs, zero dead cycles
                if (lhnd !== 8'd18 || ldead !== 8'd00 || lundr !== 8'd00
                        || lovr !== 8'd00 || lmxstall !== 8'd00 || lflags === 8'h00) begin
                    bad = 1'b1;
                end
            end
            if (i == 70) begin
                // burst 2: 5 handoffs, 12 dead, runs 3/8/1, 3 underruns, 1 overrun
                if (lhnd !== 8'd5 || ldead !== 8'd12 || lmxstall !== 8'd8
                        || lundr !== 8'd3 || lovr !== 8'd1) begin
                    bad = 1'b1;
                end
            end
            if (i == 96) begin
                // burst 5: ready with nothing to take, and not one accepted beat
                if (lhnd !== 8'd00 || ldead !== 8'd00 || lundr !== 8'd6
                        || lmxstall !== 8'd00) begin
                    bad = 1'b1;
                end
            end
            if (i == 198) begin
                // burst 6: one endless run, so the dead total IS the recorded maximum
                if (ldead !== lmxstall || lhnd !== 8'd6 || lovr !== 8'd00
                        || lundr !== 8'd00) begin
                    bad = 1'b1;
                end
            end
            if (i == 229) begin
                // burst 7: dead runs 3/3/4/1 -> max 4, 11 dead, 6 handoffs
                if (lhnd !== 8'd6 || ldead !== 8'd11 || lmxstall !== 8'd4
                        || lundr !== 8'd00 || lovr !== 8'd00) begin
                    bad = 1'b1;
                end
            end
        end

        // ---- fold the beat ----------------------------------------------
        ips_fnv_word({24'd0, hnd});
        ips_fnv_word({24'd0, dead});
        ips_fnv_word({24'd0, stall});
        ips_fnv_word({24'd0, mxstall});
        ips_fnv_word({24'd0, undr});
        ips_fnv_word({24'd0, ovr});
        ips_fnv_word({24'd0, flags});
        ips_fnv_word({24'd0, lhnd});
        ips_fnv_word({24'd0, ldead});
        ips_fnv_word({24'd0, lmxstall});
        ips_fnv_word({24'd0, lundr});
        ips_fnv_word({24'd0, lovr});
        ips_fnv_word({24'd0, lflags});
        ips_fnv_word({24'd0, burst_n});
        ips_fnv_word({24'd0, top_hnd});
        ips_fnv_word({30'd0, busy, done});

        // ---- keep the previous-beat copies for the next iteration -------
        if (clk_en === 1'b1) begin
            p_hnd    = hnd;
            p_dead   = dead;
            p_stall  = stall;
            p_mx     = mxstall;
            p_undr   = undr;
            p_ovr    = ovr;
            p_flags  = flags;
            p_lhnd   = lhnd;
            p_ldead  = ldead;
            p_lmx    = lmxstall;
            p_lundr  = lundr;
            p_lovr   = lovr;
            p_lflags = lflags;
            p_bn     = burst_n;
            p_top    = top_hnd;
            p_busy   = busy;
            p_done   = done;
            p_openr  = opening_r;
            p_obs    = obs;
            p_valid  = valid;
            p_ready  = ready;
        end

        plan(i + 1);
    end

    repeat (4) @(negedge ips_clk);
    // the idle tail must be frozen: burst_n only moves on a closing beat
    if (burst_n !== p_bn || done !== 1'b0 || busy !== 1'b0) begin
        bad = 1'b1;
    end
    ips_fnv_word({24'd0, burst_n});
    ips_fnv_word({24'd0, top_hnd});
    ips_fnv_word({24'd0, lhnd});
    ips_fnv_word({24'd0, lmxstall});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_handoff_analyzer");
end

endmodule
