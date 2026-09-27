// Behavioural equivalence bench for the STAGED pkt_trtcm_coloring rewrite.
// Three implementations are compared every beat:
//   ref_  = the release module rtl/acc_pkt_trtcm_coloring.v
//   fast_ = tools/_staged/pkt_trtcm_coloring_fast.v (borrow-flat cone)
//   m_*   = an independent model written straight from the sentences of
//           ip/pkt_trtcm_coloring/SPEC.md in 64-bit integer form
//           (Tcir = min(delta<<kc, 0x1FFFF), CBC = max(0, CBC-Tcir),
//            GREEN iff CBC+B <= CBS, YELLOW iff EBC+B <= EBS, ...)
// Stimulus is vectors/pkt_trtcm_coloring.mem (which the release bench ties to
// the Python golden model) plus several thousand random beats covering restart,
// clk_en=0 holds and out_ready=0 backpressure. result, aux, fault, out_valid,
// in_ready and the full 256-bit state register are compared on every beat.
//
// Run from the repository root so $readmemh finds the real vector image:
//   iverilog -g2012 -s tb_trtcm_fast_equiv -o /tmp/trtf/equiv.vvp \
//       rtl/acc_pkt_trtcm_coloring.v tools/_staged/pkt_trtcm_coloring_fast.v \
//       tools/_staged/tb_trtcm_fast_equiv.v
//   vvp /tmp/trtf/equiv.vvp
`timescale 1ns/1ps
module tb_trtcm_fast_equiv;

localparam NVEC = 320;

reg clk = 0;
always #5 clk = ~clk;

reg rst_n = 0, clk_en = 0, in_valid = 0, out_ready = 0;
reg [31:0] a = 0, b = 0, c = 0;
wire rd_ref, rd_fast, ov_ref, ov_fast, f_ref, f_fast;
wire [31:0] r_ref, x_ref, r_fast, x_fast;

acc_pkt_trtcm_coloring ref_ (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(rd_ref), .a(a), .b(b), .c(c),
    .out_valid(ov_ref), .out_ready(out_ready),
    .result(r_ref), .aux(x_ref), .fault(f_ref));

acc_pkt_trtcm_coloring_fast fast_ (
    .clk(clk), .rst_n(rst_n), .clk_en(clk_en),
    .in_valid(in_valid), .in_ready(rd_fast), .a(a), .b(b), .c(c),
    .out_valid(ov_fast), .out_ready(out_ready),
    .result(r_fast), .aux(x_fast), .fault(f_fast));

// ---------------------------------------------------------------------------
// bookkeeping
// ---------------------------------------------------------------------------
reg [160:0] vec [0:NVEC-1];
integer errors = 0, beats = 0, accepts = 0, cycles = 0, back2back = 0;
integer stalls = 0, pauses = 0, restarts = 0, ebeats = 0, satbeats = 0;
integer backpress = 0, greenb = 0, yellowb = 0, redb = 0, inj = 0, wrapb = 0;
integer overc = 0, overe = 0, drain0 = 0, statefull = 0;
reg [31:0] seed = 32'hC0FFEE_51;

// SPEC model registers (64-bit integer form, deliberately unlike both RTL cones)
reg [63:0] m_rawc, m_rawp, m_tcir, m_tpir, m_cbc0, m_ebc0, m_cbcw, m_ebcw;
reg [63:0] m_sumc, m_sume, m_cbcf, m_ebcf;
reg [15:0] m_t16, m_delta, m_tm, m_cbs, m_ebs;
reg [16:0] m_blen;
reg [3:0] m_kc, m_kp;
reg [2:0] m_col;
reg m_bw, m_cs, m_ps, m_green, m_yellow, m_red, m_gt, m_gt2, m_ev;
reg [31:0] m_r, m_x;
reg m_f;
reg [255:0] m_state_n;
reg [17:0] m_drain_c, m_drain_e;

// one beat exactly as ip/pkt_trtcm_coloring/SPEC.md states it
task model_beat;
    input [31:0] av, bv, cv;
    input [255:0] st;
    begin
        m_t16 = av[31:16];
        m_blen = {1'b0, av[15:0]};
        m_cbs = bv[15:0];
        m_ebs = bv[31:16];
        m_kc = cv[3:0];
        m_kp = cv[7:4];
        m_ev = cv[8];
        if (cv[31]) begin
            // restart: CBC:=CBS, EBC:=EBS, time:=0
            m_cbc0 = {48'd0, m_cbs}; m_ebc0 = {48'd0, m_ebs}; m_tm = 16'd0;
        end else begin
            m_cbc0 = {48'd0, st[15:0]}; m_ebc0 = {48'd0, st[31:16]};
            m_tm = st[47:32];
        end
        // delta = (T - time) mod 65536, backwards when delta >= 32768
        m_delta = m_t16 - m_tm;
        m_bw = m_delta[15];
        m_rawc = {48'd0, m_delta} << m_kc;
        m_rawp = {48'd0, m_delta} << m_kp;
        // Tcir = min(delta<<kc, 0x1FFFF), Tpir likewise: saturate at 17 bits
        m_tcir = (m_rawc > 64'h1ffff) ? 64'h1ffff : m_rawc;
        m_tpir = (m_rawp > 64'h1ffff) ? 64'h1ffff : m_rawp;
        m_cs = (m_rawc > 64'h1ffff);
        m_ps = (m_rawp > 64'h1ffff);
        // CBC = max(0, CBC-Tcir), EBC = max(0, EBC-Tpir)
        m_cbcw = (m_cbc0 > m_tcir) ? (m_cbc0 - m_tcir) : 64'd0;
        m_ebcw = (m_ebc0 > m_tpir) ? (m_ebc0 - m_tpir) : 64'd0;
        m_drain_c = m_cbcw[17:0];
        m_drain_e = m_ebcw[17:0];
        // marking: GREEN if CBC+B<=CBS (and CBC+=B), else YELLOW if EBC+B<=EBS
        // (and EBC+=B), else RED with the counters drained where they overflow
        m_sumc = m_cbcw + {48'd0, m_blen};
        m_sume = m_ebcw + {48'd0, m_blen};
        m_green = (m_sumc <= {48'd0, m_cbs});
        m_yellow = (!m_green) && (m_sume <= {48'd0, m_ebs});
        m_red = (!m_green) && (!m_yellow);
        m_gt = ({48'd0, m_blen} > {48'd0, m_cbs});
        m_gt2 = ({48'd0, m_blen} > {48'd0, m_ebs});
        m_cbcf = m_cbcw;
        m_ebcf = m_ebcw;
        if (m_green) begin
            m_cbcf = m_sumc;
            m_col = 3'd0;
        end else if (m_yellow) begin
            m_ebcf = m_sume;
            m_col = 3'd1;
        end else begin
            m_col = 3'd2;
            if (m_gt) m_cbcf = 64'd0;
            if (m_gt2) m_ebcf = 64'd0;
        end
        m_x = 32'd0;
        m_x[15:0] = m_delta;
        m_x[17:16] = m_col[1:0];
        m_x[20:18] = m_tcir[17:15];
        m_x[23:21] = m_tpir[17:15];
        m_x[24] = m_cs;
        m_x[25] = m_ps;
        m_x[26] = m_bw;
        m_x[27] = cv[31];
        m_x[28] = m_ev;
        m_x[29] = m_gt;
        m_x[30] = m_gt2;
        m_r = 32'd0;
        m_r[15:0] = m_cbcf[15:0];
        m_r[31:16] = m_ebcf[15:0];
        m_f = m_bw | m_ev | (m_red & m_gt2);
        m_state_n = {208'd0, m_t16, m_ebcf[15:0], m_cbcf[15:0]};
    end
endtask

task fail;
    input [8*26-1:0] what;
    begin
        errors = errors + 1;
        if (errors <= 12)
            $display("MISMATCH(%0d) %0s cyc=%0d a=%h b=%h c=%h ref=%h/%h/%b/ov%b stn=%h fast=%h/%h/%b/ov%b stn=%h exp=%h/%h/%b stn=%h",
                errors, what, cycles, a, b, c,
                r_ref, x_ref, f_ref, ov_ref, ref_.state_r,
                r_fast, x_fast, f_fast, ov_fast, fast_.state_r,
                m_r, m_x, m_f, m_state_n);
    end
endtask

// ---------------------------------------------------------------------------
// one clock edge with pre-edge sampling of the combinational handshake and of
// the stimulus/state, so the SPEC model is always evaluated on the exact beat
// the DUTs saw
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
        #1;                         // let the just-driven controls reach in_ready
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
        if (r_ref !== r_fast) fail("result vs staged");
        if (x_ref !== x_fast) fail("aux vs staged");
        if (f_ref !== f_fast) fail("fault vs staged");
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
            if (ref_.state_r !== pre_state || fast_.state_r !== ref_.state_r)
                fail("state moved on a stalled beat");
        end
        if (acc_now) begin
            accepts = accepts + 1;
            model_beat(av_s, bv_s, cv_s, pre_state);
            if (ref_.state_r !== fast_.state_r) fail("state_r ref vs staged");
            if (ref_.state_r !== m_state_n)     fail("state_r vs SPEC model");
            if (r_ref !== m_r)                  fail("result vs SPEC model");
            if (x_ref !== m_x)                  fail("aux vs SPEC model");
            if (f_ref !== m_f)                  fail("fault vs SPEC model");
            if (m_drain_c == 18'd0) drain0 = drain0 + 1;
            if (m_gt) overc = overc + 1;
            if (m_gt2) overe = overe + 1;
            if (m_col == 3'd0) greenb = greenb + 1;
            else if (m_col == 3'd1) yellowb = yellowb + 1;
            else redb = redb + 1;
            if (m_cs || m_ps) satbeats = satbeats + 1;
            if (m_delta[15]) wrapb = wrapb + 1;
            if (cv_s[31]) restarts = restarts + 1;
            if (cv_s[8]) ebeats = ebeats + 1;
            if (pre_state[255:48] !== 208'd0) statefull = 1;
        end
        if (ov_ref === 1'b1 && out_ready === 1'b0 && clk_en === 1'b1) stalls = stalls + 1;
        if (clk_en === 1'b0) pauses = pauses + 1;
    end
endtask

reg hold_pending;

// present one beat, hold it until accepted, then drain or leave it pending
task drive_beat;
    input [31:0] av, bv, cv;
    input integer allow_pause;
    input integer allow_stall;
    integer guard;
    begin
        @(negedge clk);
        a = av; b = bv; c = cv; in_valid = 1; clk_en = 1;
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
        beats = beats + 1;
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

// force an arbitrary legal (or deliberately dirty) state into both DUTs
task inject_state;
    input [15:0] cb;
    input [15:0] eb;
    input [15:0] tm;
    input integer dirty_upper;
    reg [255:0] dst;
    begin
        dst = 256'd0;
        dst[15:0] = cb;
        dst[31:16] = eb;
        dst[47:32] = tm;
        if (dirty_upper) dst[255:48] = 208'hDEAD_BEEF_DEAD_BEEF_5555_5555_A5A5_A5A5_3333_CCCC;
        @(negedge clk);
        in_valid = 0; clk_en = 1; out_ready = 1;
        ref_.state_r = dst;
        fast_.state_r = dst;
        hold_pending = 1'b0;
        inj = inj + 1;
    end
endtask

// B that puts the model exactly on a colour edge: limit - drained + off,
// clamped into the 16-bit LEN field (signed integer maths, no wrap surprises)
function [15:0] edge_len;
    input [15:0] limit;
    input [17:0] drained;
    input integer off;
    integer v;
    begin
        v = limit;
        v = v - drained;
        v = v + off;
        if (v < 0) v = 0;
        if (v > 65535) v = 65535;
        edge_len = v[15:0];
    end
endfunction

// one kc/kp rate pair per lane so both token cones get exercised every way
function [7:0] rate_byte;      // {kp, kc}
    input integer lane;
    input integer n;
    reg [3:0] k_c, k_p;
    begin
        k_c = ((lane * 4 + (n % 3)) & 4'hf);
        k_p = ((15 - ((lane * 3 + n) & 4'hf)) & 4'hf);
        if ((n % 4) == 0) begin k_c = 4'd0;  k_p = 4'd0;  end
        else if ((n % 4) == 1) begin k_c = 4'hf; k_p = 4'd0; end
        else if ((n % 4) == 2) begin k_c = 4'd3; k_p = 4'hf; end
        else begin k_c = 4'hc; k_p = 4'h9; end
        rate_byte = {k_p, k_c};
    end
endfunction

// ---------------------------------------------------------------------------
integer i, n, lane, guard2, off;
integer cN = 3000, dN = 700, eN = 3000;
integer k, kce;
reg [65:0] hold_word_pre;
reg [255:0] st_pre;
reg [31:0] ra, rb, rc;
reg [15:0] cbv, ebv, tsv;

initial begin : main
    if ($value$plusargs("seed=%d", seed)) begin
    end
    if ($test$plusargs("quick")) begin
        cN = 600; dN = 120; eN = 600;
    end
    $display("seed=%h beats_per_phase C=%0d D=%0d E=%0d", seed, cN, dN, eN);
    $readmemh("vectors/pkt_trtcm_coloring.mem", vec);
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
        if ({r_ref, x_ref, f_ref} !== vec[i][64:0]) fail("release vector image B");
        if ({r_fast, x_fast, f_fast} !== vec[i][64:0]) fail("release vector image B (fast)");
        back2back = back2back + 1;
        beats = beats + 1;
    end
    @(negedge clk); in_valid = 0;
    @(posedge clk); #1;
    if (ov_ref !== 1'b0 || ov_fast !== 1'b0) fail("duplicate output after phase B");

    // --- Phase C: randomised beats incl. restart / saturation / E flag ------
    for (n = 0; n < cN; n = n + 1) begin
        ra = $random(seed);
        rb = $random(seed);
        if ((n % 5) == 0) rb = 32'h0000_0010;                 // tiny buckets
        if ((n % 11) == 0) rb = 32'h0000_0000;                // CBS = EBS = 0
        if ((n % 13) == 0) rb = 32'hffff_ffff;                // CBS = EBS = max
        if ((n % 17) == 0) rb = 32'h0001_0001;                // 1-token buckets
        rc = $random(seed);
        if ((n % 3) == 0) rc[7:0] = 8'hff;                    // kc = kp = 15
        else if ((n % 3) == 1) rc[7:0] = 8'h00;               // kc = kp = 0
        else if ((n % 3) == 2) rc[7:0] = 8'h4d;               // mixed rates
        rc[8] = ((n % 7) == 0);                               // declared E overflow
        if ((n % 4) == 0) rc[31] = 1'b1;                      // restart
        else rc[31] = 1'b0;
        if ((n % 9) == 0) ra[15:0] = 16'd0;                   // zero length
        if ((n % 9) == 1) ra[15:0] = 16'hffff;                // maximum length
        if ((n % 9) == 2) ra[15:0] = 16'd1;
        drive_beat(ra, rb, rc, 1, 1);
    end

    // --- Phase D: injected state + colour-boundary walks --------------------
    for (n = 0; n < dN; n = n + 1) begin
        cbv = $random(seed) & 16'hffff;
        ebv = $random(seed) & 16'hffff;
        if ((n % 5) == 0) begin cbv = 16'hffff; ebv = 16'hffff; end
        if ((n % 7) == 0) begin cbv = 16'd0;    ebv = 16'd0;    end
        if ((n % 11) == 0) cbv = $random(seed) & 16'h00ff;
        tsv = $random(seed) & 16'hffff;
        for (lane = 0; lane < 4; lane = lane + 1) begin
            rc = $random(seed);
            rc[7:0] = rate_byte(lane, n);
            rc[8] = ((n % 6) == 3);
            rc[31] = ((n % 5) == 0) ? 1'b1 : 1'b0;
            rb = $random(seed);
            if ((n % 2) == 0) rb = rb & 32'h0000_ffff;        // CBS below the range
            if ((n % 23) == 0) rb = 32'hffff_ffff;
            inject_state(cbv, ebv, tsv, (n % 6) == 0);
            // delta = lane: T = tm + lane
            ra = (((tsv + lane) & 16'hffff) << 16);
            // straddle the GREEN edge: B = CBS - drained CBC + off
            model_beat(ra, rb, rc, ref_.state_r);
            for (off = -1; off <= 1; off = off + 1) begin
                drive_beat(ra | edge_len(m_cbs, m_drain_c, off), rb, rc, 1, 1);
            end
            // straddle the YELLOW edge: B = EBS - drained EBC + off
            inject_state(cbv, ebv, tsv, 0);
            model_beat(ra, rb, rc, ref_.state_r);
            for (off = -1; off <= 1; off = off + 1) begin
                drive_beat(ra | edge_len(m_ebs, m_drain_e, off), rb, rc, 1, 1);
            end
            // saturating Tcir on a small delta: kc = 15 with delta = 8
            inject_state(cbv, ebv, tsv, 0);
            drive_beat((((tsv + 16'd8) & 16'hffff) << 16) | 16'd3, rb,
                       (rc & 32'hffffff00) | 32'h0f, 0, 0);
            // backwards delta with a full bucket: T = tm - 1 -> delta = 65535
            inject_state(cbv, ebv, tsv, 0);
            drive_beat((((tsv - 16'd1) & 16'hffff) << 16) | 16'd7, rb, rc, 0, 0);
        end
    end

    // --- Phase E: delta/rate corner sweep on injected states ----------------
    for (n = 0; n < eN; n = n + 1) begin
        cbv = $random(seed) & 16'hffff;
        ebv = $random(seed) & 16'hffff;
        if ((n % 4) == 0) begin cbv = $random(seed) & 16'h00ff; ebv = 16'hffff; end
        tsv = $random(seed) & 16'hffff;
        inject_state(cbv, ebv, tsv, (n % 9) == 0);
        ra = $random(seed);
        if ((n % 4) == 0) ra[31:16] = tsv;                    // delta == 0
        else if ((n % 4) == 1) ra[31:16] = tsv + 16'd1;       // delta == 1
        else if ((n % 4) == 2) ra[31:16] = tsv - 16'd1;       // delta == 65535
        else if ((n % 4) == 3) ra[31:16] = tsv + 16'h8000;    // half-scale wrap
        rb = $random(seed);
        if ((n % 13) == 0) rb = 32'h0000_0000;
        if ((n % 17) == 0) rb = 32'hffff_ffff;
        if ((n % 19) == 0) rb = 32'h0008_0008;
        rc = $random(seed);
        rc[7:0] = $random(seed) & 8'hff;
        rc[8] = (($random(seed) & 32'h7fffffff) % 5) == 0;
        rc[31] = (($random(seed) & 32'h7fffffff) % 3) == 0;
        drive_beat(ra, rb, rc, 1, 1);
    end

    // --- Phase F: asynchronous reset while a response is pending ------------
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

    // --- Phase G: CE low for several cycles while a response is pending -----
    hold_pending = 1'b0;
    for (n = 0; n < 60; n = n + 1) begin
        ra = $random(seed); rb = $random(seed); rc = $random(seed);
        rc[31] = ((n % 3) == 0);
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

    $display("beats=%0d accepts=%0d cycles=%0d restarts=%0d eflag=%0d saturated=%0d green=%0d yellow=%0d red=%0d drained0=%0d BoverCBS=%0d BoverEBS=%0d backw=%0d back2back=%0d out_stall_cycles=%0d ce_low_cycles=%0d backpressure_cycles=%0d state_injections=%0d dirty_seen=%0d",
             beats, accepts, cycles, restarts, ebeats, satbeats, greenb, yellowb, redb,
             drain0, overc, overe, wrapb, back2back, stalls, pauses, backpress, inj, statefull);
    if (restarts == 0 || ebeats == 0 || satbeats == 0 || greenb == 0 ||
        yellowb == 0 || redb == 0 || drain0 == 0 || overc == 0 || overe == 0 ||
        wrapb == 0 || stalls == 0 || pauses == 0 || backpress == 0 ||
        inj == 0 || back2back != NVEC)
        $display("WARNING: vacuous coverage of a required corner class");
    if (errors == 0)
        $display("EQUIV PASS mismatches=0 beats=%0d accepts=%0d", beats, accepts);
    else begin
        $display("EQUIV FAIL mismatches=%0d", errors);
        $fatal(1, "staged pkt_trtcm_coloring rewrite is not equivalent");
    end
    $finish;
end
endmodule
