`timescale 1ns / 1ps
// tb_ips_bit_packer : production-line testbench for the MSB-first bit packer.
//
// Drives random short bursts closed by in_last, one burst longer than MAX_BURST so
// the over-length flag latches, a mid-burst flush that leaves a non-zero residual,
// a sweep of burst lengths 1..8 that produces every residual value 0..7 (including
// the bit-aligned case where the flush has nothing to emit), twenty spurious flush
// requests that must saturate cnt_spur and report saturation, a field held on the
// input while in_ready is low (it must not be consumed), and one beat with clk_en
// low (the packer must not move).  Exactly one enabled posedge drives the core per
// beat, and the accept decision is taken after the combinational flags settle for
// that time step.  Only DUT outputs are folded; models/ips_bit_packer.py derives the
// expected stream from the written packing contract (trap T1) and every verdict
// uses === (trap T6).
//
// The assertions below are invariants that hold for the core no matter how a datapath
// constant is perturbed: the counters and max_resid never walk back, the sticky words
// never lose a bit, and every designed violation was reported.  Exact accounting
// (bits_in = cnt_fields * FIELD_BITS, bits_out + resid = bits_in, the emitted bit
// stream, every counter value) is proven by the independent golden model digest
// rather than by TB-side shadow arithmetic, so a mutated literal shows up as a
// changed digest instead of as a build failure (station 4 evidence rule).
module tb_ips_bit_packer;

`include "ips_tb_common.vh"

localparam integer FIELD_BITS_TB = 11;
localparam integer OUT_BITS_TB   = 8;
localparam integer MIN_BEATS     = 200;
localparam [31:0]  SEED          = 32'h2B8E1F73;

reg                   rst_n;
reg                   clk_en;
reg                   in_valid;
reg                   in_last;
reg                   flush;
reg  [FIELD_BITS_TB-1:0] in_field;

wire                  in_ready;
wire                  out_valid;
wire                  out_last;
// headroom: the core drives OUT_BITS / 4 / 5 / 6 bit fields, the analysing wires
// are wider so a parameter re-target can never silently truncate the observation.
wire [15:0]           out_word;
wire [7:0]            resid_bits;
wire [7:0]            pad_bits;
wire [7:0]            burst_len;
wire [7:0]            cnt_fields;
wire [7:0]            cnt_words;
wire [7:0]            cnt_flush;
wire [7:0]            cnt_spur;
wire [7:0]            max_resid;
wire [15:0]           bits_in;
wire [15:0]           bits_out;
wire [7:0]            err_sticky;
wire [7:0]            cnt_sat;

ips_bit_packer dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .in_last    (in_last),
    .in_field   (in_field),
    .flush      (flush),
    .in_ready   (in_ready),
    .out_valid  (out_valid),
    .out_last   (out_last),
    .out_word   (out_word),
    .resid_bits (resid_bits),
    .pad_bits   (pad_bits),
    .burst_len  (burst_len),
    .cnt_fields (cnt_fields),
    .cnt_words  (cnt_words),
    .cnt_flush  (cnt_flush),
    .cnt_spur   (cnt_spur),
    .max_resid  (max_resid),
    .bits_in    (bits_in),
    .bits_out   (bits_out),
    .err_sticky (err_sticky),
    .cnt_sat    (cnt_sat)
);

// one count per enabled clock edge, so the verdict line reports real activity
always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer b;
integer q;
integer blen;
integer bi;
integer beats;
reg     bad;
reg     acc;
reg [31:0] state;
reg [7:0]  stick_prev;
reg [7:0]  sat_prev;
reg [7:0]  max_prev;
reg [7:0]  cf_prev;
reg [7:0]  cw_prev;
reg [7:0]  cfl_prev;
reg [7:0]  cs_prev;
reg [15:0] bin_prev;
reg [15:0] bout_prev;

task fold_beat;
    begin
        ips_fnv_word({29'd0, in_ready, out_valid, out_last});
        ips_fnv_word({16'd0, out_word});
        ips_fnv_word({24'd0, resid_bits});
        ips_fnv_word({24'd0, pad_bits});
        ips_fnv_word({24'd0, burst_len});
        ips_fnv_word({24'd0, cnt_fields});
        ips_fnv_word({24'd0, cnt_words});
        ips_fnv_word({24'd0, cnt_flush});
        ips_fnv_word({24'd0, cnt_spur});
        ips_fnv_word({24'd0, max_resid});
        ips_fnv_word({24'd0, err_sticky});
        ips_fnv_word({24'd0, cnt_sat});
        ips_fnv_word({16'd0, bits_in});
        ips_fnv_word({16'd0, bits_out});

        if ((^{in_ready, out_valid, out_last}) === 1'bx) bad = 1'b1;
        if ((^out_word) === 1'bx || (^resid_bits) === 1'bx) bad = 1'b1;
        if ((^pad_bits) === 1'bx || (^burst_len) === 1'bx) bad = 1'b1;
        if ((^{cnt_fields, cnt_words, cnt_flush, cnt_spur}) === 1'bx) bad = 1'b1;
        if ((^{max_resid, err_sticky, cnt_sat}) === 1'bx) bad = 1'b1;
        if ((^bits_in) === 1'bx || (^bits_out) === 1'bx) bad = 1'b1;

        // every observability counter saturates, so none of them may ever walk back
        if (cnt_fields < cf_prev)   bad = 1'b1;
        if (cnt_words  < cw_prev)   bad = 1'b1;
        if (cnt_flush  < cfl_prev)  bad = 1'b1;
        if (cnt_spur   < cs_prev)   bad = 1'b1;
        if (bits_in    < bin_prev)  bad = 1'b1;
        if (bits_out   < bout_prev) bad = 1'b1;
        cf_prev   = cnt_fields;
        cw_prev   = cnt_words;
        cfl_prev  = cnt_flush;
        cs_prev   = cnt_spur;
        bin_prev  = bits_in;
        bout_prev = bits_out;

        // sticky / monotone words must never walk back
        if ((stick_prev & ~err_sticky) !== 8'h00) bad = 1'b1;
        if ((sat_prev & ~cnt_sat) !== 8'h00) bad = 1'b1;
        if (max_resid < max_prev) bad = 1'b1;
        stick_prev = err_sticky;
        sat_prev   = cnt_sat;
        max_prev   = max_resid;

        bi    = bi + 1;
        beats = beats + 1;
    end
endtask

task beat;
    input        v;
    input        l;
    input [FIELD_BITS_TB-1:0] d;
    input        fl;
    input        ce;
    begin
        @(negedge ips_clk);
        clk_en   = ce;
        in_valid = v;
        in_last  = l;
        in_field = d;
        flush    = fl;
        // settle the combinational accept flag: sampling in_ready in the same
        // delta as the input change is a zero-delay race
        #1;
        acc = (ce === 1'b1) && (v === 1'b1) && (in_ready === 1'b1);
        @(negedge ips_clk);
        clk_en   = 1'b0;
        in_valid = 1'b0;
        in_last  = 1'b0;
        flush    = 1'b0;
        in_field = {FIELD_BITS_TB{1'b0}};
        fold_beat();
    end
endtask

task send_field;
    input        l;
    input [FIELD_BITS_TB-1:0] d;
    begin
        acc = 1'b0;
        while (acc !== 1'b1) begin
            beat(1'b1, l, d, 1'b0, 1'b1);
        end
    end
endtask

// idle beats until the packer is back in its load state, then flush the residual
task close_burst_flush;
    begin
        q = 0;
        while ((in_ready !== 1'b1) && (q < 32)) begin
            beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);
            q = q + 1;
        end
        beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b1, 1'b1);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    in_valid   = 1'b0;
    in_last    = 1'b0;
    flush      = 1'b0;
    in_field   = {FIELD_BITS_TB{1'b0}};
    state      = SEED;
    bad        = 1'b0;
    acc        = 1'b0;
    bi         = 0;
    beats      = 0;
    stick_prev = 8'h00;
    sat_prev   = 8'h00;
    max_prev   = 8'h00;
    cf_prev    = 8'h00;
    cw_prev    = 8'h00;
    cfl_prev   = 8'h00;
    cs_prev    = 8'h00;
    bin_prev   = 16'h0000;
    bout_prev  = 16'h0000;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    // ---------------- Phase A: random short bursts closed by in_last ----------
    for (b = 0; b < 7; b = b + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        blen  = 1 + (state % 32'd6);
        for (q = 0; q < blen; q = q + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            send_field((q == blen - 1) ? 1'b1 : 1'b0, state[FIELD_BITS_TB-1:0]);
        end
        beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);
        beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);
    end

    // ---------------- Phase B: burst longer than MAX_BURST, constant pattern ----
    for (q = 0; q < 30; q = q + 1) begin
        send_field((q == 29) ? 1'b1 : 1'b0, 11'h55A);
    end
    beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);

    // ---------------- Phase C: mid-burst flush with a non-zero residual --------
    send_field(1'b0, 11'h003);
    send_field(1'b0, 11'h7FF);
    beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b1, 1'b1);
    beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);

    // ---------------- Phase D: sweep burst lengths 1..8, close with flush ------
    // the residuals cover every value 0..7, including the bit-aligned case where
    // the flush has nothing to emit and must be reported as spurious.
    for (blen = 1; blen <= 8; blen = blen + 1) begin
        for (q = 0; q < blen; q = q + 1) begin
            state = state * 32'd1664525 + 32'd1013904223;
            send_field(1'b0, state[FIELD_BITS_TB-1:0]);
        end
        close_burst_flush();
    end

    // ---------------- Phase E: spurious flushes, saturating cnt_spur -----------
    for (q = 0; q < 20; q = q + 1) begin
        beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b1, 1'b1);
    end

    // ---------------- Phase F: field held while in_ready is low ---------------
    send_field(1'b0, 11'h111);
    beat(1'b1, 1'b0, 11'h3AA, 1'b0, 1'b1);
    beat(1'b1, 1'b0, 11'h3AA, 1'b0, 1'b1);
    beat(1'b1, 1'b0, 11'h3AA, 1'b0, 1'b1);
    send_field(1'b1, 11'h3AA);
    beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);

    // ---------------- Phase G: disabled clock must freeze the packer ----------
    beat(1'b1, 1'b0, 11'h155, 1'b0, 1'b0);
    send_field(1'b0, 11'h155);
    send_field(1'b1, 11'h600);

    // ---------------- Phase H: final burst closed by an explicit flush --------
    for (q = 0; q < 5; q = q + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        send_field(1'b0, state[FIELD_BITS_TB-1:0]);
    end
    close_burst_flush();

    for (q = 0; q < 6; q = q + 1) begin
        beat(1'b0, 1'b0, {FIELD_BITS_TB{1'b0}}, 1'b0, 1'b1);
    end

    repeat (4) @(negedge ips_clk);

    ips_fnv_word({24'd0, cnt_fields});
    ips_fnv_word({24'd0, cnt_words});
    ips_fnv_word({24'd0, cnt_flush});
    ips_fnv_word({24'd0, cnt_spur});
    ips_fnv_word({24'd0, max_resid});
    ips_fnv_word({24'd0, burst_len});
    ips_fnv_word({24'd0, resid_bits});
    ips_fnv_word({24'd0, err_sticky});
    ips_fnv_word({24'd0, cnt_sat});
    ips_fnv_word({16'd0, out_word});
    ips_fnv_word({16'd0, bits_in});
    ips_fnv_word({16'd0, bits_out});

    if (beats < MIN_BEATS) bad = 1'b1;
    // the designed violations must all have been reported
    if (err_sticky[0] !== 1'b1) bad = 1'b1;   // over-length burst seen
    if (err_sticky[1] !== 1'b1) bad = 1'b1;   // flush with nothing buffered
    if (cnt_sat[3] !== 1'b1) bad = 1'b1;      // cnt_spur saturated and reported
    if (resid_bits !== 8'h00) bad = 1'b1;     // nothing may stay buffered at the end
    if (burst_len !== 8'h00) bad = 1'b1;
    if (max_resid === 8'h00) bad = 1'b1;      // at least one real residual flushed
    if ((^{in_ready, out_valid, out_last, out_word, resid_bits, pad_bits}) === 1'bx)
        bad = 1'b1;
    if ((^{burst_len, cnt_fields, cnt_words, cnt_flush, cnt_spur, max_resid}) === 1'bx)
        bad = 1'b1;
    if ((^{bits_in, bits_out, err_sticky, cnt_sat}) === 1'bx) bad = 1'b1;

    ips_verdict(!bad, "ips_bit_packer");
end

endmodule
