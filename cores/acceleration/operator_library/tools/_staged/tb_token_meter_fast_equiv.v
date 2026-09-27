// Behavioural equivalence bench for the STAGED pkt_token_meter_color rewrite.
// Instantiates the release module (rtl/acc_pkt_token_meter_color.v) and the
// staged module (tools/_staged/pkt_token_meter_color_fast.v) side by side, drives
// them with the identical enabled-ready-valid-32x3-v1 stimulus stream and
// compares result, aux, fault, out_valid, in_ready and the full 256-bit state
// register after every beat. A third, independent SPEC-derived model written in
// the original long form (wide raw shift + wide compare + clamp compare + red
// compare + subtract) checks both DUTs, so the result is traceable to
// ip/pkt_token_meter_color/SPEC.md and to vectors/pkt_token_meter_color.mem,
// which the release bench already proves against the Python golden model.
//
// Run from the repository root so $readmemh finds the real vector image:
//   iverilog -g2012 -s tb_token_meter_fast_equiv -o /tmp/tmfast/equiv.vvp \
//       rtl/acc_pkt_token_meter_color.v tools/_staged/pkt_token_meter_color_fast.v \
//       tools/_staged/tb_token_meter_fast_equiv.v
//   vvp /tmp/tmfast/equiv.vvp
`timescale 1ns/1ps
module tb_token_meter_fast_equiv;

localparam NVEC = 320;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0, clk_en = 0, in_valid = 0, out_ready = 0;
reg [31:0] a = 0, b = 0, c = 0;
wire rd_ref, rd_fast, ov_ref, ov_fast, f_ref, f_fast;
wire [31:0] r_ref, x_ref, r_fast, x_fast;

acc_pkt_token_meter_color ref_ (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(rd_ref), .a(a), .b(b), .c(c),
    .out_valid(ov_ref), .out_ready(out_ready),
    .result(r_ref), .aux(x_ref), .fault(f_ref));

acc_pkt_token_meter_color_fast fast_ (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(rd_fast), .a(a), .b(b), .c(c),
    .out_valid(ov_fast), .out_ready(out_ready),
    .result(r_fast), .aux(x_fast), .fault(f_fast));

// ---------------------------------------------------------------------------
// bookkeeping
// ---------------------------------------------------------------------------
reg [160:0] vec [0:NVEC-1];
integer errors = 0, beats = 0, accepts = 0, cycles = 0, back2back = 0;
integer stalls = 0, pauses = 0, restarts = 0, satbeats = 0, rsvbeats = 0;
integer backpress = 0;
integer redbeats = 0, greenb = 0, clampbeats = 0, bnd = 0, inj = 0, wrapb = 0;
reg [31:0] seed = 32'h7E57_0A11;

// model wires (original SPEC formulation, 64-bit to avoid width traps)
reg [63:0] m_raw, m_cre, m_sum, m_bal, m_balpre;
reg [15:0] m_delta, m_t16, m_tm, m_plen;
reg [23:0] m_cbs, m_tok;
reg [7:0]  m_rsv;
reg [3:0]  m_scl;
reg [22:0] m_ini;
reg        m_red, m_clm, m_xs;
reg [31:0] m_r, m_x;
reg        m_f;
reg [255:0] m_state_n;

// independent model of one beat, exactly as ip/pkt_token_meter_color/SPEC.md and
// the release kernel state it.
task model_beat;
    input [31:0] av, bv, cv;
    input [255:0] st;
    begin
        m_t16 = av[31:16];
        m_plen = av[15:0];
        m_cbs = bv[23:0];
        m_rsv = bv[31:24];
        m_scl = cv[3:0];
        m_ini = cv[30:8];
        if (cv[31]) begin m_tok = {1'b0, m_ini}; m_tm = 16'd0; end
        else        begin m_tok = st[23:0];      m_tm = st[39:24]; end
        m_delta = m_t16 - m_tm;
        m_raw = {48'd0, m_delta} << m_scl;
        m_xs = (m_raw > 64'hffffff);
        m_cre = m_xs ? 64'hffffff : m_raw;
        m_sum = {40'd0, m_tok} + m_cre;
        m_clm = (m_sum > {40'd0, m_cbs});
        m_bal = m_clm ? {40'd0, m_cbs} : m_sum;
        m_balpre = m_bal;
        m_red = ({48'd0, m_plen} > m_bal);
        if (!m_red) m_bal = m_bal - {48'd0, m_plen};
        m_x = 32'd0;
        m_x[15:0] = m_delta;
        m_x[27:16] = m_cre[11:0];
        m_x[28] = m_xs;
        m_x[29] = !m_red;
        m_x[30] = (m_rsv != 8'd0);
        m_x[31] = cv[31];
        m_r = 32'd0;
        m_r[23:0] = m_bal[23:0];
        m_r[24] = m_red;
        m_r[25] = m_clm;
        m_r[26] = (m_rsv != 8'd0);
        m_f = m_red | (m_rsv != 8'd0);
        m_state_n = {216'd0, m_t16, m_bal[23:0]};
    end
endtask

task fail;
    input [8*24-1:0] what;
    begin
        errors = errors + 1;
        if (errors <= 12)
            $display("MISMATCH(%0d) %0s cyc=%0d a=%h b=%h c=%h stp=%h ref=%h/%h/%b/ov%b stn=%h fast=%h/%h/%b/ov%b stn=%h exp=%h/%h/%b stn=%h",
                errors, what, cycles, a, b, c, m_balpre,
                r_ref, x_ref, f_ref, ov_ref, ref_.state_r,
                r_fast, x_fast, f_fast, ov_fast, fast_.state_r,
                m_r, m_x, m_f, m_state_n);
    end
endtask

// ---------------------------------------------------------------------------
// one clock edge with pre-edge sampling of the combinational handshake and of
// the stimulus/state, so the SPEC model is always evaluated on the exact beat
// that the DUTs saw
// ---------------------------------------------------------------------------
reg        pre_rd_ref, pre_rd_fast;
integer    acc_now;
reg [255:0] pre_state;
reg [31:0] av_s, bv_s, cv_s;
reg        ov_pre;
reg [31:0] r_pre, x_pre;
reg        f_pre;

task tick;
    begin
        #1;                         // let the just-driven controls propagate to in_ready
        pre_rd_ref = rd_ref;
        pre_rd_fast = rd_fast;
        pre_state = ref_.state_r;
        av_s = a; bv_s = b; cv_s = c;
        ov_pre = ov_ref; r_pre = r_ref; x_pre = x_ref; f_pre = f_ref;
        @(posedge clk);
        #1;
        acc_now = clk_en && in_valid && pre_rd_ref;
        cycles = cycles + 1;
        if (ov_ref !== ov_fast)         fail("out_valid");
        if (pre_rd_ref !== pre_rd_fast) fail("in_ready");
        if (ov_ref === 1'b1 && ov_fast === 1'b1) begin
            if (r_ref !== r_fast) fail("result");
            if (x_ref !== x_fast) fail("aux");
            if (f_ref !== f_fast) fail("fault");
        end
        // protocol contract: nothing moves while CE is low, and a presented beat
        // that was not accepted leaves the pending response and state untouched
        if (clk_en === 1'b0) begin
            if (ov_ref !== ov_pre || r_ref !== r_pre || x_ref !== x_pre || f_ref !== f_pre)
                fail("output moved while clk_en low");
            if (ref_.state_r !== pre_state || fast_.state_r !== ref_.state_r)
                fail("state moved while clk_en low");
        end else if (in_valid === 1'b1 && pre_rd_ref === 1'b0) begin
            backpress = backpress + 1;
            if (ov_ref !== ov_pre || r_ref !== r_pre || x_ref !== x_pre || f_ref !== f_pre)
                fail("pending response moved on a stalled beat");
            if (ref_.state_r !== pre_state) fail("state moved on a stalled beat");
        end
        if (acc_now) begin
            accepts = accepts + 1;
            model_beat(av_s, bv_s, cv_s, pre_state);
            if (ref_.state_r !== fast_.state_r) fail("state_r ref vs fast");
            if (ref_.state_r !== m_state_n)     fail("state_r vs SPEC model");
            if (r_ref !== m_r)                  fail("result vs SPEC model");
            if (x_ref !== m_x)                  fail("aux vs SPEC model");
            if (f_ref !== m_f)                  fail("fault vs SPEC model");
            if (m_clm) clampbeats = clampbeats + 1;
            if (m_delta > 16'd32767) wrapb = wrapb + 1;
        end
        if (ov_ref === 1'b1 && out_ready === 1'b0 && clk_en === 1'b1) stalls = stalls + 1;
        if (clk_en === 1'b0) pauses = pauses + 1;
    end
endtask

task count_colour;
    begin
        if (cv_s[31]) restarts = restarts + 1;
        if (bv_s[31:24] != 8'd0) rsvbeats = rsvbeats + 1;
        if (m_xs) satbeats = satbeats + 1;
        if (m_red) redbeats = redbeats + 1; else greenb = greenb + 1;
    end
endtask

reg hold_pending;

// present one beat, hold it until it is accepted, then drain or keep it pending
task drive_beat;
    input [31:0] av, bv, cv;
    input integer allow_pause;
    input integer allow_stall;
    integer guard;
    begin
        @(negedge clk);
        a = av; b = bv; c = cv; in_valid = 1; clk_en = 1;
        // when a response is still pending, start the beat against backpressure
        out_ready = !(allow_stall && hold_pending &&
                      (($random(seed) & 32'h7fffffff) % 10) < 7);
        tick;
        guard = 0;
        while (!acc_now && guard < 100) begin
            @(negedge clk);
            if (allow_pause) clk_en = (($random(seed) & 32'h7fffffff) % 4) != 0;
            if (allow_stall) out_ready = (($random(seed) & 32'h7fffffff) % 4) != 0;
            tick;
            guard = guard + 1;
        end
        if (!acc_now) fail("beat never accepted (hang)");
        count_colour;
        beats = beats + 1;
        // leave the response pending half the time so the next beat sees a full stall
        @(negedge clk);
        in_valid = 0;
        hold_pending = (allow_stall != 0) && (($random(seed) & 32'h7fffffff) % 2) == 1;
        out_ready = hold_pending ? 1'b0 : 1'b1;
        tick;
        if (acc_now) fail("phantom accept with in_valid low");
        if (!hold_pending) begin
            @(negedge clk);
            if (ov_ref !== 1'b0) fail("output not drained after valid drop");
        end
    end
endtask

task do_reset;
    begin
        @(negedge clk);
        rst_n = 0; in_valid = 0; clk_en = 0; out_ready = 0; a = 0; b = 0; c = 0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        if (ref_.state_r !== 256'd0 || fast_.state_r !== 256'd0) fail("reset state");
        if (ov_ref !== 1'b0 || ov_fast !== 1'b0) fail("reset out_valid");
        if (r_ref !== 32'd0 || x_ref !== 32'd0 || f_ref !== 1'b0) fail("reset payload");
        hold_pending = 1'b0;
        rst_n = 1;
        @(negedge clk); clk_en = 1; out_ready = 1;
    end
endtask

// inject a state into both DUTs (only legal while no beat is in flight)
task inject_state;
    input [23:0] tok;
    input [15:0] tm;
    input integer dirty_upper;
    reg [255:0] dst;
    begin
        dst = 256'd0;
        dst[23:0] = tok;
        dst[39:24] = tm;
        if (dirty_upper) dst[255:40] = 216'h5_5555_5555_5555_5555_5555_5555_5555_5555_5555_5;
        @(negedge clk);
        in_valid = 0; clk_en = 1; out_ready = 1;
        ref_.state_r = dst;
        fast_.state_r = dst;
        hold_pending = 1'b0;
        inj = inj + 1;
    end
endtask

function [31:0] plen_for;
    input integer base;
    input integer off;
    integer v;
    begin
        v = base + off;
        if (v < 0) v = 0;
        if (v > 65535) v = 65535;
        plen_for = v;
    end
endfunction

// ---------------------------------------------------------------------------
integer i, n, lane, guard2;
integer cN = 7000, dN = 700, eN = 5000;
integer k, kce;
reg [65:0] hold_word_pre;
reg [255:0] st_pre;
reg [31:0] ra, rb, rc;
reg [23:0] tokv;
reg [15:0] tsv;

initial begin : main
    if ($value$plusargs("seed=%d", seed)) begin
    end
    if ($test$plusargs("quick")) begin
        cN = 900; dN = 90; eN = 600;
    end
    $display("seed=%h beats_per_phase C=%0d D=%0d E=%0d", seed, cN, dN, eN);
    $readmemh("vectors/pkt_token_meter_color.mem", vec);
    if (^vec[0][160:65] === 1'bx) begin
        $display("FATAL: vector image not loaded");
        $fatal(1, "no vectors");
    end

    // --- Phase A: the real release vector stream, protocol-randomised -------
    do_reset;
    for (i = 0; i < NVEC; i = i + 1) begin
        drive_beat(vec[i][160:129], vec[i][128:97], vec[i][96:65], 1, 1);
        // golden traceability: the release image was produced by the Python model
        if ({r_ref, x_ref, f_ref} !== vec[i][64:0]) fail("release vector image A");
        if ({r_fast, x_fast, f_fast} !== vec[i][64:0]) fail("release vector image A (fast)");
    end

    // --- Phase B: same stream back-to-back, II=1, no pause, no stall --------
    do_reset;
    for (i = 0; i < NVEC; i = i + 1) begin
        @(negedge clk);
        a = vec[i][160:129]; b = vec[i][128:97]; c = vec[i][96:65];
        in_valid = 1; clk_en = 1; out_ready = 1;
        hold_pending = 1'b0;
        tick;
        if (!acc_now) fail("II=1 beat not accepted in back-to-back phase");
        count_colour;
        if ({r_ref, x_ref, f_ref} !== vec[i][64:0]) fail("release vector image B");
        if ({r_fast, x_fast, f_fast} !== vec[i][64:0]) fail("release vector image B (fast)");
        back2back = back2back + 1;
        beats = beats + 1;
    end
    @(negedge clk); in_valid = 0;
    @(posedge clk); #1;
    if (ov_ref !== 1'b0 || ov_fast !== 1'b0) fail("duplicate output after phase B");

    // --- Phase C: randomised beats incl. restart / reserved / saturation -----
    for (n = 0; n < cN; n = n + 1) begin
        ra = $random(seed);
        rb = $random(seed) & 32'h00ffffff;
        if ((n % 8) == 0) rb[31:24] = $random(seed) & 32'hff;   // reserved-config fault
        if ((n % 23) == 0) rb[23:0] = 24'd0;                    // CBS = 0
        if ((n % 29) == 0) rb[23:0] = 24'hffffff;               // CBS = max
        rc = $random(seed);
        rc[30:8] = $random(seed) & 32'h007fffff;
        if ((n % 3) == 0) rc[3:0] = 4'hf;                        // maximum credit shift
        else if ((n % 3) == 1) rc[3:0] = 4'd0;
        else if ((n % 3) == 2) rc[3:0] = 4'd8;
        if ((n % 4) == 0) rc[31] = 1'b1;                         // restart echo
        if ((n % 9) == 0) ra[15:0] = 16'd0;                      // zero length
        if ((n % 9) == 1) ra[15:0] = 16'hffff;                   // maximum length
        if ((n % 9) == 2) ra[15:0] = 16'd1;
        drive_beat(ra, rb, rc, 1, 1);
    end

    // --- Phase D: injected state + RED/GREEN boundary walks ------------------
    for (n = 0; n < dN; n = n + 1) begin
        tokv = $random(seed) & 24'hffffff;
        if ((n % 5) == 0) tokv = 24'hffffff;
        if ((n % 7) == 0) tokv = 24'd0;
        if ((n % 3) == 0) tokv = $random(seed) & 16'hffff;    // small: reachable edges
        tsv = $random(seed) & 16'hffff;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            rc = $random(seed);
            rc[30:8] = $random(seed) & 32'h007fffff;
            rc[3:0] = ((lane * 4 + (n % 3)) & 32'hf);          // 0,4,8,12-ish shifts
            rc[31] = (n % 5) == 0 ? 1'b1 : 1'b0;               // restart path
            rb = $random(seed) & 32'h00ffffff;
            if ((n % 2) == 0) rb = rb & 16'hffff;              // CBS below the LEN range
            if ((n % 23) == 0) rb = 24'hffffff;                // CBS = max
            if ((n % 11) == 0) rb[31:24] = 8'hab;              // reserved-config fault
            // T = tm + lane -> delta = lane (small, exact)
            ra = (((tsv + lane) & 16'hffff) << 16);
            for (bnd = 0; bnd < 3; bnd = bnd + 1) begin
                inject_state(tokv, tsv, (n % 6) == 0);
                // balance does not depend on LEN, so one probe gives the edge
                model_beat(ra, rb, rc, ref_.state_r);
                drive_beat(ra | plen_for(m_balpre, bnd - 1), rb, rc, 1, 1);
            end
            // backwards delta: T = tm - 1 -> delta = 65535 (saturating shift)
            inject_state(tokv, tsv, 0);
            drive_beat((((tsv - 16'd1) & 16'hffff) << 16) | 16'd7, rb, rc, 0, 0);
        end
    end

    // --- Phase E: delta corner sweep on injected states ---------------------
    for (n = 0; n < eN; n = n + 1) begin
        tokv = $random(seed) & 24'hffffff;
        if ((n % 4) == 0) tokv = $random(seed) & 16'hffff;
        tsv = $random(seed) & 16'hffff;
        inject_state(tokv, tsv, (n % 9) == 0);
        ra = $random(seed);
        if ((n % 4) == 0) ra[31:16] = tsv;                          // delta == 0
        else if ((n % 4) == 1) ra[31:16] = tsv + 16'd1;              // delta == 1
        else if ((n % 4) == 2) ra[31:16] = tsv - 16'd1;              // delta == 65535
        else if ((n % 4) == 3) ra[31:16] = tsv + 16'h8000;           // half-scale wrap
        rb = $random(seed) & 32'h00ffffff;
        if ((n % 13) == 0) rb[23:0] = 24'd0;
        if ((n % 17) == 0) rb[23:0] = 24'hffffff;
        if ((n % 19) == 0) rb[31:24] = 8'h01;
        rc = $random(seed);
        rc[30:8] = $random(seed) & 32'h007fffff;
        rc[3:0] = $random(seed) & 4'hf;
        rc[31] = (($random(seed) & 32'h7fffffff) % 3) == 0;
        drive_beat(ra, rb, rc, 1, 1);
    end

    // --- Phase F: asynchronous reset while a response is pending -------------
    do_reset;
    @(negedge clk); clk_en = 1; in_valid = 1; out_ready = 0;
    a = vec[0][160:129]; b = vec[0][128:97]; c = vec[0][96:65];
    guard2 = 0;
    tick;                       // the beat is accepted; the response then stalls
    while (ov_ref !== 1'b1 && guard2 < 20) begin @(posedge clk); #1; guard2 = guard2 + 1; end
    if (ov_ref !== 1'b1 || ov_fast !== 1'b1) fail("pending response not established");
    if (r_ref !== r_fast || x_ref !== x_fast || f_ref !== f_fast) fail("pending response differs");
    @(negedge clk); clk_en = 0; rst_n = 0;
    #1;
    if (ov_ref !== 1'b0 || ov_fast !== 1'b0) fail("async reset out_valid mismatch");
    if (ref_.state_r !== fast_.state_r) fail("async reset state mismatch");
    if (r_ref !== 32'd0 || x_ref !== 32'd0 || f_ref !== 1'b0) fail("async reset payload mismatch");
    do_reset;

    // --- Phase G: CE low for several cycles while a response is pending ------
    hold_pending = 1'b0;
    for (n = 0; n < 40; n = n + 1) begin
        ra = $random(seed); rb = $random(seed) & 32'h00ffffff;
        rc = $random(seed); rc[30:8] = $random(seed) & 32'h007fffff;
        drive_beat(ra, rb, rc, 1, 1);
        @(negedge clk); clk_en = 0; out_ready = 0;
        hold_word_pre = {r_ref, x_ref, f_ref, ov_ref};
        st_pre = ref_.state_r;
        kce = 1 + (($random(seed) & 32'h7fffffff) % 3);
        for (k = 0; k < kce; k = k + 1) begin
            @(posedge clk); #1;
            cycles = cycles + 1; pauses = pauses + 1;
            if (ref_.state_r !== st_pre) fail("state moved during CE gap");
            if (fast_.state_r !== ref_.state_r) fail("state split during CE gap");
            if ({r_ref, x_ref, f_ref, ov_ref} !== hold_word_pre) fail("output moved during CE gap");
            if ({r_fast, x_fast, f_fast, ov_fast} !== {r_ref, x_ref, f_ref, ov_ref})
                fail("outputs differ during CE gap");
        end
        @(negedge clk); clk_en = 1; out_ready = 1;
        tick;
        @(negedge clk);
        if (ov_ref !== 1'b0) fail("output not cleared after CE gap drain");
    end

    $display("beats=%0d accepts=%0d cycles=%0d restarts=%0d reserved=%0d saturated=%0d red=%0d green=%0d clamped=%0d back2back=%0d wrapdelta=%0d out_stall_cycles=%0d ce_low_cycles=%0d backpressure_cycles=%0d state_injections=%0d",
             beats, accepts, cycles, restarts, rsvbeats, satbeats, redbeats, greenb,
             clampbeats, back2back, wrapb, stalls, pauses, backpress, inj);
    if (restarts == 0 || rsvbeats == 0 || satbeats == 0 || redbeats == 0 ||
        greenb == 0 || clampbeats == 0 || stalls == 0 || pauses == 0 ||
        wrapb == 0 || inj == 0 || backpress == 0 || back2back != NVEC)
        $display("WARNING: vacuous coverage of a required corner class");
    if (errors == 0)
        $display("EQUIV PASS mismatches=0 beats=%0d accepts=%0d", beats, accepts);
    else begin
        $display("EQUIV FAIL mismatches=%0d", errors);
        $fatal(1, "staged pkt_token_meter_color rewrite is not equivalent");
    end
    $finish;
end
endmodule
