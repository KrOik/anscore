`timescale 1ns / 1ps
// tb_ips_sync_marker_stuffer : production-line testbench for the byte sync-marker
// stuffer / destuffer.
//
// The control-byte values and the queue depth are read back from the instance under
// test (sync_v / esc_v / mask_v / fem_v / qmax_v) instead of being hard-coded, so
// every phase keeps its meaning when a production-line mutation station perturbs one
// of the RTL constants: a mutant still runs the whole schedule and shows up as a
// changed digest rather than as a spuriously failing assertion.  The golden model uses
// the declared defaults, exactly as documented in src/ips_sync_marker_stuffer.v.
//
// Schedule (replayed beat for beat by models/ips_sync_marker_stuffer.py; one beat is
// exactly one enabled posedge, clk_en is low on the intervening edge):
//   A  INSERT: a frame marker on a beat of its own every MK_CAD payload bytes,
//      payload bytes that look like the marker or the escape byte plus the two bytes
//      that are their escaped forms, a requester error (sync_req presented together
//      with a data byte), one clk_en-low beat, a held-sink burst that fills the queue
//      until in_ready refuses the presented byte, then a drain.  The emitted wire
//      bytes and their out_sof marks are recorded.
//   B  REMOVE: that recorded wire stream is fed back in the remove direction and
//      recorded again; transparency is checked against the stream presented in phase
//      A (same bytes, same start-of-frame marks, marker-valued payload byte
//      round-trips, escaped stream strictly longer than the presented one).  Then a
//      held-sink burst for the remover and the malformed control cases: a legal
//      escape that must NOT be reported, a truncated escape, two escapes in a row, an
//      escape this stuffer could never have produced, and a requester error.
//   C  INSERT: more escapes in one frame than the frame budget allows, so frame_esc
//      clamps at FRAME_ESC_MAX and latches err_sticky[3]; the next marker re-opens
//      the frame and clears it.
//   D  saturating counters: cnt_in / cnt_out / cnt_sync / cnt_esc / cnt_spur are run
//      past their ceilings, each latching its own cnt_sat bit.
//   E  the asynchronous reset is yanked with the queue full and the counters live,
//      then released: every register comes back at its reset value and the core
//      resumes streaming from there.
//
// Observation groups folded every beat, in this exact order (14 words, the golden
// model folds the same 14 words per beat):
//   {p_in_ready, p_out_valid, p_pop, p_out_sof}, p_out_byte, p_queue_level,
//   {out_valid, out_sof}, out_byte, queue_level, cnt_in, cnt_out, cnt_esc, cnt_sync,
//   frame_esc, cnt_spur, err_sticky, cnt_sat
// where the p_ prefix is the pre-edge view sampled while the beat was presented (p_pop
// only on an enabled, non-reset beat: a disabled beat consumes nothing even though
// out_valid && out_ready reads true) and the rest is the post-edge view with the
// inputs cleared.  At the end the counter
// words, the head byte, queue_level, the three recorded stream lengths and the beat
// count are folded once more.  Only DUT outputs are folded; the expected stream comes
// from the written escape contract, never from simulation output (trap T1), and every
// check uses === / !== so an X can never read as a pass (trap T6).
module tb_ips_sync_marker_stuffer;

`include "ips_tb_common.vh"

localparam integer MAXS      = 1024;
localparam integer NPA       = 48;
localparam integer MK_CAD    = 6;
localparam integer ORDY_SLOT = 7;
localparam integer MIN_BEATS = 200;
localparam integer NSTALL    = 4;
localparam [31:0]  SEED      = 32'h5A5C3D71;
localparam integer REC_NONE  = 0;
localparam integer REC_WIRE  = 1;
localparam integer REC_DEC   = 2;

reg        rst_n;
reg        clk_en;
reg        mode;
reg        in_valid;
reg [7:0]  in_byte;
reg        sync_req;
reg        out_ready;

wire       in_ready;
wire       out_valid;
wire       out_sof;
wire [7:0] out_byte;
wire [7:0] cnt_in;
wire [7:0] cnt_out;
wire [7:0] cnt_esc;
wire [7:0] cnt_sync;
wire [3:0] cnt_spur;
wire [2:0] queue_level;
wire [7:0] frame_esc;
wire [3:0] err_sticky;
wire [4:0] cnt_sat;

// No #() override: the TB exercises the declared default control bytes and depth.
ips_sync_marker_stuffer dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .mode        (mode),
    .in_valid    (in_valid),
    .in_byte     (in_byte),
    .sync_req    (sync_req),
    .in_ready    (in_ready),
    .out_valid   (out_valid),
    .out_sof     (out_sof),
    .out_byte    (out_byte),
    .out_ready   (out_ready),
    .cnt_in      (cnt_in),
    .cnt_out     (cnt_out),
    .cnt_esc     (cnt_esc),
    .cnt_sync    (cnt_sync),
    .cnt_spur    (cnt_spur),
    .queue_level (queue_level),
    .frame_esc   (frame_esc),
    .err_sticky  (err_sticky),
    .cnt_sat     (cnt_sat)
);

// one count per enabled clock edge, so the verdict line reports real activity
always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// control bytes and geometry taken from the instance under test
reg [7:0] sync_v;
reg [7:0] esc_v;
reg [7:0] mask_v;
reg [7:0] fem_v;
reg [7:0] qmax_v;

// recorded streams
reg [7:0] xmem [0:MAXS-1];   // logical stream presented to the stuffer
reg       xsof [0:MAXS-1];
reg [7:0] emem [0:MAXS-1];   // wire stream the stuffer emitted
reg       esof [0:MAXS-1];
reg [7:0] dmem [0:MAXS-1];   // wire stream the destuffer emitted
reg       dsof [0:MAXS-1];
integer   xn;
integer   en;
integer   dn;
integer   rec_mode;

integer   bi;
integer   beats;
integer   i;
integer   j;
integer   k;
integer   gi;      // guard counter, only used inside the beat tasks
integer   go;      // guard counter for the phase loops in the initial block
integer   xsync;
integer   esync;
integer   dsync;
reg       bad;
reg       acc_l;
reg       in_rst;
reg       prev_in_rst;
reg       prev_ov;
reg [7:0] prev_head;
reg       prev_sof;
reg [7:0] p_ob;
reg       p_os;
reg       p_ov;
reg       p_irdy;
reg       p_pop;
reg [2:0] p_ql;
reg [7:0] spur_exp;
reg [3:0] stick_exp;
reg [7:0] ci_prev;
reg [7:0] co_prev;
reg [7:0] ce_prev;
reg [7:0] cs_prev;
reg [3:0] cp_prev;
reg [3:0] stick_prev;
reg [4:0] sat_prev;
reg [7:0] b2;
reg [31:0] state;

function ordy_sched;
    begin
        // a sink that refuses every ORDY_SLOT-th beat: steady back-pressure
        ordy_sched = (((bi % ORDY_SLOT) == 4) ? 1'b0 : 1'b1);
    end
endfunction

task fold_beat;
    begin
        ips_fnv_word({28'd0, p_irdy, p_ov, p_pop, p_os});
        ips_fnv_word({24'd0, p_ob});
        ips_fnv_word({29'd0, p_ql});
        ips_fnv_word({30'd0, out_valid, out_sof});
        ips_fnv_word({24'd0, out_byte});
        ips_fnv_word({29'd0, queue_level});
        ips_fnv_word({24'd0, cnt_in});
        ips_fnv_word({24'd0, cnt_out});
        ips_fnv_word({24'd0, cnt_esc});
        ips_fnv_word({24'd0, cnt_sync});
        ips_fnv_word({24'd0, frame_esc});
        ips_fnv_word({28'd0, cnt_spur});
        ips_fnv_word({28'd0, err_sticky});
        ips_fnv_word({27'd0, cnt_sat});

        if ((^{p_irdy, p_ov, p_pop, p_os, p_ob, p_ql}) === 1'bx) bad = 1'b1;
        if ((^{out_valid, out_sof, out_byte, queue_level}) === 1'bx) bad = 1'b1;
        if ((^{cnt_in, cnt_out, cnt_esc, cnt_sync}) === 1'bx) bad = 1'b1;
        if ((^{frame_esc, cnt_spur, err_sticky, cnt_sat}) === 1'bx) bad = 1'b1;

        // occupancy may never exceed the declared queue depth
        if (queue_level > qmax_v) bad = 1'b1;
        if (p_ql        > qmax_v) bad = 1'b1;

        if (in_rst !== 1'b1 && prev_in_rst !== 1'b1) begin
            // observability counters saturate, so they may never walk back
            if (cnt_in   < ci_prev)   bad = 1'b1;
            if (cnt_out  < co_prev)   bad = 1'b1;
            if (cnt_esc  < ce_prev)   bad = 1'b1;
            if (cnt_sync < cs_prev)   bad = 1'b1;
            if (cnt_spur < cp_prev)   bad = 1'b1;
            // sticky words must never lose a bit
            if ((stick_prev & ~err_sticky) !== 4'h0) bad = 1'b1;
            if ((sat_prev   & ~cnt_sat)    !== 5'h0) bad = 1'b1;
            // FWFT: a head this beat did not take must still be there unchanged
            if (prev_ov === 1'b1 && p_pop === 1'b0 && out_valid === 1'b1) begin
                if (out_byte !== prev_head) bad = 1'b1;
                if (out_sof  !== prev_sof)  bad = 1'b1;
            end
        end
        ci_prev     = cnt_in;
        co_prev     = cnt_out;
        ce_prev     = cnt_esc;
        cs_prev     = cnt_sync;
        cp_prev     = cnt_spur;
        stick_prev  = err_sticky;
        sat_prev    = cnt_sat;
        prev_ov     = out_valid;
        prev_head   = out_byte;
        prev_sof    = out_sof;
        prev_in_rst = in_rst;

        // a byte that left the core is recorded into the active stream
        if (p_pop === 1'b1) begin
            if (rec_mode == REC_WIRE) begin
                if (en >= MAXS) bad = 1'b1;
                else begin
                    emem[en] = p_ob;
                    esof[en] = p_os;
                    en = en + 1;
                end
            end else if (rec_mode == REC_DEC) begin
                if (dn >= MAXS) bad = 1'b1;
                else begin
                    dmem[dn] = p_ob;
                    dsof[dn] = p_os;
                    dn = dn + 1;
                end
            end
        end

        bi    = bi + 1;
        beats = beats + 1;
    end
endtask

// one beat = one clock period; the inputs are presented for exactly that period.
// doret holds rst_n low for the whole period: nothing is consumed and nothing moves.
task beat;
    input        v;
    input [7:0]  d;
    input        srq;
    input        ordy;
    input        ce;
    input        doret;
    begin
        @(negedge ips_clk);
        in_rst    = doret;
        rst_n     = doret ? 1'b0 : 1'b1;
        clk_en    = ce;
        in_valid  = v;
        in_byte   = d;
        sync_req  = srq;
        out_ready = ordy;
        // settle: sampling the combinational flags in the same delta as the input
        // change is a zero-delay race
        #1;
        p_irdy = in_ready;
        p_ov   = out_valid;
        p_ob   = out_byte;
        p_os   = out_sof;
        p_ql   = queue_level;
        // pop: only an enabled, non-reset beat really consumes the head, even though
        // out_valid && out_ready reads true for the whole disabled period
        p_pop  = (ce && !doret) ? (out_valid && ordy) : 1'b0;
        acc_l  = (ce === 1'b1) && (doret === 1'b0) && (v || (srq && (mode === 1'b0)))
                 && (p_irdy === 1'b1);
        @(negedge ips_clk);
        clk_en   = 1'b0;
        in_valid = 1'b0;
        sync_req = 1'b0;
        in_byte  = 8'h00;
        fold_beat();
    end
endtask

// presented-stream bookkeeping: one entry per byte the core actually consumed
task xlog;
    input [7:0] b;
    input       s;
    begin
        if (xn >= MAXS) bad = 1'b1;
        else begin
            xmem[xn] = b;
            xsof[xn] = s;
            xn = xn + 1;
        end
    end
endtask

// present a data byte until the core takes it (srq low models a clean requester)
task send_data;
    input [7:0] d;
    input       srq;
    begin
        acc_l = 1'b0;
        gi = 0;
        while ((acc_l !== 1'b1) && (gi < 200)) begin
            beat(1'b1, d, srq, ordy_sched(), 1'b1, 1'b0);
            gi = gi + 1;
        end
        if (acc_l !== 1'b1) bad = 1'b1;
    end
endtask

// request a marker on a beat of its own, until the core takes it
task send_marker;
    begin
        acc_l = 1'b0;
        gi = 0;
        while ((acc_l !== 1'b1) && (gi < 200)) begin
            beat(1'b0, 8'h00, 1'b1, ordy_sched(), 1'b1, 1'b0);
            gi = gi + 1;
        end
        if (acc_l !== 1'b1) bad = 1'b1;
    end
endtask

// present a byte to the remover until it is taken
task send_in;
    input [7:0] d;
    begin
        send_data(d, 1'b0);
    end
endtask

// hold the sink low and push NSTALL plain bytes: the queue fills to its depth, the
// next byte is refused with in_ready low, and once the sink is free that byte must
// still go through -- no accepted or presented byte may be dropped
task stall_burst;
    input        do_log;
    input        is_dec;
    begin
        for (j = 0; j < NSTALL; j = j + 1) begin
            b2 = (is_dec ? 8'h31 : 8'h11) + j;
            acc_l = 1'b0;
            gi = 0;
            while ((acc_l !== 1'b1) && (gi < 16)) begin
                beat(1'b1, b2, 1'b0, 1'b0, 1'b1, 1'b0);
                gi = gi + 1;
            end
            if (acc_l === 1'b1) begin
                if (do_log) xlog(b2, 1'b0);
            end else begin
                // refused: the queue must be full and in_ready must have said so
                if (p_ql !== qmax_v[2:0]) bad = 1'b1;
                if (p_irdy !== 1'b0) bad = 1'b1;
                acc_l = 1'b0;
                gi = 0;
                while ((acc_l !== 1'b1) && (gi < 64)) begin
                    beat(1'b1, b2, 1'b0, 1'b1, 1'b1, 1'b0);
                    gi = gi + 1;
                end
                if (acc_l !== 1'b1) bad = 1'b1;
                if (do_log) xlog(b2, 1'b0);
            end
        end
    end
endtask

// idle beats with the sink accepting, until the queue has emptied
task drain_out;
    begin
        gi = 0;
        while ((queue_level !== 3'd0) && (gi < 48)) begin
            beat(1'b0, 8'h00, 1'b0, 1'b1, 1'b1, 1'b0);
            gi = gi + 1;
        end
        if (queue_level !== 3'd0) bad = 1'b1;
    end
endtask

task idle_beats;
    input integer n;
    begin
        gi = 0;
        while (gi < n) begin
            beat(1'b0, 8'h00, 1'b0, 1'b1, 1'b1, 1'b0);
            gi = gi + 1;
        end
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    mode        = 1'b0;
    in_valid    = 1'b0;
    in_byte     = 8'h00;
    sync_req    = 1'b0;
    out_ready   = 1'b1;
    in_rst      = 1'b0;
    prev_in_rst = 1'b0;
    prev_ov     = 1'b0;
    prev_head   = 8'h00;
    prev_sof    = 1'b0;
    bad         = 1'b0;
    acc_l       = 1'b0;
    bi          = 0;
    beats       = 0;
    gi          = 0;
    go          = 0;
    xn          = 0;
    en          = 0;
    dn          = 0;
    xsync       = 0;
    esync       = 0;
    dsync       = 0;
    rec_mode    = REC_NONE;
    state       = SEED;
    ci_prev     = 8'h00;
    co_prev     = 8'h00;
    ce_prev     = 8'h00;
    cs_prev     = 8'h00;
    cp_prev     = 4'h0;
    stick_prev  = 4'h0;
    sat_prev    = 5'h00;
    b2          = 8'h00;
    p_ob        = 8'h00;
    p_os        = 1'b0;
    p_ov        = 1'b0;
    p_irdy      = 1'b0;
    p_pop       = 1'b0;
    p_ql        = 3'd0;

    sync_v = dut.SYNC_BYTE;
    esc_v  = dut.ESC_BYTE;
    mask_v = dut.XOR_MASK;
    fem_v  = dut.FRAME_ESC_MAX;
    qmax_v = dut.Q_DEPTH;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    // ------------------------- phase A: INSERT -------------------------------
    mode     = 1'b0;
    rec_mode = REC_WIRE;
    send_marker();
    xlog(sync_v, 1'b1);

    for (i = 0; i < NPA; i = i + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        b2 = state[15:8];
        if ((i % 4) == 1)      b2 = sync_v;              // marker-valued payload
        else if ((i % 4) == 2) b2 = esc_v;               // escape-valued payload
        else if ((i % 4) == 3) b2 = (((i % 2) == 0) ? (sync_v ^ mask_v)
                                                    : (esc_v ^ mask_v));
        if (i == 7 || i == 23) begin
            // requester error: sync_req presented together with a data byte.  The
            // byte is still forwarded, so only it enters the presented stream.
            send_data(b2, 1'b1);
            xlog(b2, 1'b0);
        end else if (i == 11) begin
            // a whole period with clk_en low must freeze the stuffer completely
            beat(1'b1, b2, 1'b0, ordy_sched(), 1'b0, 1'b0);
            send_data(b2, 1'b0);
            xlog(b2, 1'b0);
        end else if (i == 31) begin
            drain_out();
            stall_burst(1'b1, 1'b0);
        end else begin
            send_data(b2, 1'b0);
            xlog(b2, 1'b0);
        end
        if ((i % MK_CAD) == (MK_CAD - 1)) begin
            send_marker();
            xlog(sync_v, 1'b1);
        end
    end
    // drain while still recording: every wire byte of phase A belongs to the captured
    // stream, including the ones still queued when the stimulus ends
    drain_out();
    rec_mode = REC_NONE;
    if (en <= xn) bad = 1'b1;              // escapes lengthened the wire stream

    // ------------------------- phase B: REMOVE -------------------------------
    mode     = 1'b1;
    rec_mode = REC_DEC;
    for (k = 0; k < en; k = k + 1) begin
        if (k == 25) begin
            beat(1'b1, emem[k], 1'b0, ordy_sched(), 1'b0, 1'b0);   // clk_en low
            send_in(emem[k]);
        end else begin
            send_in(emem[k]);
        end
    end
    drain_out();                 // destuffed tail belongs to the transparency stream
    rec_mode = REC_NONE;

    // transparency: the destuffed stream is the presented stream, byte for byte,
    // with the start-of-frame marks in the same places
    if (dn != xn) bad = 1'b1;
    for (i = 0; i < xn; i = i + 1) begin
        if (i < dn) begin
            if (dmem[i] !== xmem[i]) bad = 1'b1;
            if (dsof[i] !== xsof[i]) bad = 1'b1;
        end
        if (xsof[i] === 1'b1) xsync = xsync + 1;
    end
    for (i = 0; i < en; i = i + 1) begin
        if (esof[i] === 1'b1) esync = esync + 1;
    end
    for (i = 0; i < dn; i = i + 1) begin
        if (dsof[i] === 1'b1) dsync = dsync + 1;
    end
    if (esync != xsync) bad = 1'b1;
    if (dsync != xsync) bad = 1'b1;
    if (xsync == 0)     bad = 1'b1;

    // the remover must survive a held sink just the same way
    stall_burst(1'b0, 1'b1);
    drain_out();

    // a legal escape of the marker byte is transparent and must NOT be reported
    spur_exp  = {4'h0, cnt_spur};
    stick_exp = err_sticky;
    send_in(esc_v);
    send_in(sync_v ^ mask_v);
    if (cnt_spur !== spur_exp[3:0]) bad = 1'b1;
    if (err_sticky !== stick_exp)   bad = 1'b1;

    // truncated escape: a marker lands while an escape is still pending
    send_in(esc_v);
    send_in(sync_v);
    if (err_sticky[0] !== 1'b1) bad = 1'b1;
    // two escapes in a row, then an escaped byte this stuffer could never have
    // produced (its unescaped value is not a control byte)
    send_in(esc_v);
    send_in(esc_v);
    send_in(8'h41);
    if (err_sticky[1] !== 1'b1) bad = 1'b1;
    // a requester error is reported in the remove direction as well
    send_data(8'h31, 1'b1);
    if (err_sticky[2] !== 1'b1) bad = 1'b1;
    drain_out();

    // ---------------------- phase C: frame escape budget ---------------------
    mode = 1'b0;
    send_marker();
    if (frame_esc !== 8'h00) bad = 1'b1;
    go = 0;
    while (((frame_esc !== fem_v) || (err_sticky[3] !== 1'b1)) && (go < 200)) begin
        send_data(((go & 1) == 0) ? sync_v : esc_v, 1'b0);
        go = go + 1;
    end
    if (frame_esc !== fem_v)    bad = 1'b1;   // clamped, never wrapped
    if (err_sticky[3] !== 1'b1) bad = 1'b1;
    send_marker();
    if (frame_esc !== 8'h00) bad = 1'b1;      // the marker re-opens the frame
    drain_out();

    // ---------------------- phase D: saturating counters ---------------------
    mode = 1'b1;
    go = 0;
    while (((cnt_in !== 8'hFF) || (cnt_out !== 8'hFF) ||
            (cnt_sat[0] !== 1'b1) || (cnt_sat[1] !== 1'b1)) && (go < 600)) begin
        send_in(((go & 1) == 0) ? 8'h31 : 8'h52);
        go = go + 1;
    end
    if (cnt_sat[0] !== 1'b1 || cnt_sat[1] !== 1'b1) bad = 1'b1;

    mode = 1'b0;
    go = 0;
    while (((cnt_sync !== 8'hFF) || (cnt_sat[3] !== 1'b1)) && (go < 600)) begin
        send_marker();
        go = go + 1;
    end
    if (cnt_sat[3] !== 1'b1) bad = 1'b1;

    go = 0;
    while (((cnt_esc !== 8'hFF) || (cnt_sat[2] !== 1'b1)) && (go < 1400)) begin
        send_data(((go & 1) == 0) ? esc_v : sync_v, 1'b0);
        go = go + 1;
    end
    if (cnt_sat[2] !== 1'b1) bad = 1'b1;

    go = 0;
    while (((cnt_spur !== 4'hF) || (cnt_sat[4] !== 1'b1)) && (go < 80)) begin
        send_data(8'h61, 1'b1);
        go = go + 1;
    end
    if (cnt_sat !== 5'b11111) bad = 1'b1;
    drain_out();

    // ---------------------- phase E: asynchronous reset ----------------------
    mode = 1'b0;
    // leave bytes pending in the queue with the sink held low
    for (i = 0; i < 3; i = i + 1) begin
        acc_l = 1'b0;
        gi = 0;
        while ((acc_l !== 1'b1) && (gi < 16)) begin
            beat(1'b1, (8'h70 + i), 1'b0, 1'b0, 1'b1, 1'b0);
            gi = gi + 1;
        end
    end
    if (queue_level === 3'd0) bad = 1'b1;     // bytes must really be in flight
    // yank rst_n low for two whole periods, still presenting a byte
    beat(1'b1, 8'h11, 1'b0, 1'b1, 1'b1, 1'b1);
    beat(1'b0, 8'h00, 1'b0, 1'b1, 1'b1, 1'b1);
    // released: the core must not resurrect anything, it starts from the reset state
    beat(1'b0, 8'h00, 1'b0, 1'b1, 1'b1, 1'b0);
    if (cnt_in !== 8'h00 || cnt_out !== 8'h00 || cnt_esc !== 8'h00 ||
        cnt_sync !== 8'h00 || cnt_spur !== 4'h0 || frame_esc !== 8'h00 ||
        err_sticky !== 4'h0 || cnt_sat !== 5'b00000) bad = 1'b1;
    if (queue_level !== 3'd0 || out_valid !== 1'b0) bad = 1'b1;
    // and it streams again from that state
    send_marker();
    send_data(sync_v, 1'b0);
    send_data(8'h23, 1'b0);
    drain_out();
    // a closing marker re-opens the frame, so its escape budget is back at zero
    send_marker();
    drain_out();
    if (frame_esc !== 8'h00) bad = 1'b1;
    idle_beats(2);

    repeat (4) @(negedge ips_clk);

    ips_fnv_word({24'd0, cnt_in});
    ips_fnv_word({24'd0, cnt_out});
    ips_fnv_word({24'd0, cnt_esc});
    ips_fnv_word({24'd0, cnt_sync});
    ips_fnv_word({28'd0, cnt_spur});
    ips_fnv_word({24'd0, frame_esc});
    ips_fnv_word({28'd0, err_sticky});
    ips_fnv_word({27'd0, cnt_sat});
    ips_fnv_word({24'd0, out_byte});
    ips_fnv_word({29'd0, queue_level});
    ips_fnv_word(xn);
    ips_fnv_word(en);
    ips_fnv_word(dn);
    ips_fnv_word(beats);

    if (beats < MIN_BEATS)      bad = 1'b1;
    if (queue_level !== 3'd0)   bad = 1'b1;
    if (frame_esc !== 8'h00)    bad = 1'b1;
    if (err_sticky !== 4'h0)    bad = 1'b1;   // the async reset cleared the causes
    if (cnt_sat !== 5'b00000)   bad = 1'b1;
    if ((^{in_ready, out_valid, out_sof, out_byte}) === 1'bx) bad = 1'b1;
    if ((^{cnt_in, cnt_out, cnt_esc, cnt_sync, cnt_spur}) === 1'bx) bad = 1'b1;
    if ((^{queue_level, frame_esc, err_sticky, cnt_sat}) === 1'bx) bad = 1'b1;

    ips_verdict(!bad, "ips_sync_marker_stuffer");
end

endmodule
