`timescale 1ns / 1ps
// tb_ips_reciprocal_lut : production-line testbench for the reciprocal ROM core.
//
// Folding rule (the SAME contract is written into models/ips_reciprocal_lut.py,
// both sides derive it from the core's documented behaviour, never from
// simulation):
//   one observation per published operation, taken at the negedge after `valid`
//   pulses, and per observation these words in this order:
//     w0 = {17'd0, recip}                          refined reciprocal
//     w1 = {17'd0, r0}                             seed estimate after NR scaling
//     w2 = {17'd0, resid}                          Newton-Raphson factor
//     w3 = {24'd0, rnshift, nflag, exact, err, sticky}
//     w4 = {19'd0, ridx, rwt}
//     w5 = {24'd0, done}
//   then once at the end: {24'd0, done}, {24'd0, sticky}, OPS.
//   recip/r0/resid are sampled one bit wider than the shipped [FRAC+1:0] ports
//   and ridx/rwt one bit wider than [IDXB-1:0] / [WBITS-1:0], so a width change
//   of those parameters moves real bits into the digest instead of being
//   swallowed by the fixed fold layout.
//
// Stimulus contract shared with the model:
//   state = state * 32'd1664525 + 32'd1013904223 (mod 2**32) from 32'h2EC1F00D,
//   one draw per operation with den = state[11:0], overridden by directed cases
//   on m = i % 64:
//     m==0  den = 12'h000  divide by zero (undefined reciprocal)
//     m==1  den = 12'h001  largest normalisation shift
//     m==2  den = 12'h800  already normalized, exact
//     m==3  den = 12'hFFF  largest denominator
//     m==7  den = 12'h7FF  one below the normalization boundary
//     m==11 den = 12'h400  power of two, exact
//     m==15 den = 12'h008  power of two, exact
//     m==19 den = 12'hAAA  alternating bits
//     m==23 den = 12'hFFE  one below the maximum
//     m==27 den = 12'h002  power of two, exact
//     m==31 den = 12'hC00  3/4 of full scale
//     m==35 den = 12'h801  normalized with the smallest interpolation weight
//     m==39 den = 12'h401  power-of-two plus one
//     m==43 den = 12'h7FE  just under the boundary
//     m==47 den = 12'h155  small odd denominator
//     m==51 den = 12'h2AA  mid scale
//     m==55 den = 12'h5FF  upper mid scale
//     m==59 den = 12'h040  small power of two
//     m==63 den = 12'h100  quarter scale
//   Denominators arriving from the LCG are used for every other m.
//
// The expected stream is NOT computed here; the golden model is independent
// (docs/IP_CORE_SOP.md trap T1) and verdicts use === so X can never pass (T6).
module tb_ips_reciprocal_lut;

`include "ips_tb_common.vh"

localparam integer OPS = 256;
localparam [31:0]  SEED = 32'h2EC1F00D;

reg         rst_n;
reg         clk_en;
reg         start;
reg  [31:0] state;
reg  [11:0] den;

wire        busy;
wire        valid;
wire        exact;
wire        err;
wire        sticky;
wire        nflag;
wire [14:0] recip;
wire [14:0] r0;
wire [14:0] resid;
wire [3:0]  ridx;
wire [8:0]  rwt;
wire [3:0]  rnshift;
wire [7:0]  done;
wire [3:0]  iter;
wire [3:0]  stage;

// No #() override here: the defaults are the shipped configuration, and the
// mutation station must see them.
ips_reciprocal_lut dut (
    .clk      (ips_clk),
    .clk_en   (clk_en),
    .rst_n    (rst_n),
    .start    (start),
    .den      (den),
    .busy     (busy),
    .recip    (recip),
    .r0       (r0),
    .resid    (resid),
    .ridx     (ridx),
    .rwt      (rwt),
    .rnshift  (rnshift),
    .nflag    (nflag),
    .exact    (exact),
    .err      (err),
    .sticky   (sticky),
    .valid    (valid),
    .done     (done),
    .iter     (iter),
    .stage    (stage)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer m;
integer g;
integer r;
integer nres;
reg     bad;

task build_den;
    input integer idx;
    begin
        state = state * 32'd1664525 + 32'd1013904223;
        den   = state[11:0];
        case (idx % 64)
            0:  den = 12'h000;
            1:  den = 12'h001;
            2:  den = 12'h800;
            3:  den = 12'hFFF;
            7:  den = 12'h7FF;
            11: den = 12'h400;
            15: den = 12'h008;
            19: den = 12'hAAA;
            23: den = 12'hFFE;
            27: den = 12'h002;
            31: den = 12'hC00;
            35: den = 12'h801;
            39: den = 12'h401;
            43: den = 12'h7FE;
            47: den = 12'h155;
            51: den = 12'h2AA;
            55: den = 12'h5FF;
            59: den = 12'h040;
            63: den = 12'h100;
            default: ;
        endcase
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    start    = 1'b0;
    den      = 12'h000;
    state    = SEED;
    bad      = 1'b0;
    nres     = 0;

    repeat (4) @(posedge ips_clk);
    @(negedge ips_clk);
    rst_n  = 1'b1;
    repeat (2) @(posedge ips_clk);
    @(negedge ips_clk);
    clk_en = 1'b1;

    // the engine must come out of reset idle, published results all zero
    if (busy !== 1'b0 || valid !== 1'b0 || stage !== 4'd0) bad = 1'b1;
    if (recip !== 14'd0 || r0 !== 14'd0 || resid !== 14'd0) bad = 1'b1;
    if (sticky !== 1'b0 || err !== 1'b0 || exact !== 1'b0) bad = 1'b1;

    for (i = 0; i < OPS; i = i + 1) begin
        // ---- present the denominator on the falling edge
        @(negedge ips_clk);
        build_den(i);
        start = 1'b1;

        // ---- wait for the engine to be idle: this is the back-pressure case
        g = 0;
        while (busy === 1'b1 && g < 40) begin
            g = g + 1;
            @(negedge ips_clk);
        end
        if (busy !== 1'b0) bad = 1'b1;

        @(posedge ips_clk);          // accept edge (start && !busy)
        @(negedge ips_clk);
        if (busy !== 1'b1) bad = 1'b1;

        if ((i % 16) == 7) begin
            // directed: start held high through the pass sequence must be
            // ignored, and the engine must still publish the accepted operand
            @(negedge ips_clk);
            @(negedge ips_clk);
        end else begin
            start = 1'b0;
            @(negedge ips_clk);
        end

        if ((i % 16) == 9) begin
            // directed: the bus changes under the core after acceptance; the
            // captured denominator must not be disturbed
            den   = 12'h000;
            start = 1'b0;
            @(negedge ips_clk);
            den = state[11:0] ^ 12'h3FF;
        end
        @(negedge ips_clk);

        if ((i % 16) == 11) begin
            // directed: clock-enable stall inside the pass sequence; every
            // register must hold (docs/IP_CORE_SOP.md trap T2)
            @(negedge ips_clk);
            clk_en = 1'b0;
            repeat (4) @(negedge ips_clk);
            clk_en = 1'b1;
        end

        start = 1'b0;

        // ---- wait for the published result
        r = 0;
        while (valid !== 1'b1 && r < 40) begin
            r = r + 1;
            @(posedge ips_clk);
            @(negedge ips_clk);
        end
        if (valid !== 1'b1) begin
            bad = 1'b1;
        end else begin
            nres = nres + 1;
            // ---- structural properties, all with === so X fails (trap T6)
            if (busy !== 1'b0 || stage !== 4'd0)             bad = 1'b1;
            if (iter !== 4'd7)                               bad = 1'b1;
            if (done !== nres[7:0])                          bad = 1'b1;
            if (err === 1'b1 && sticky !== 1'b1)             bad = 1'b1;
            if (exact === 1'b1 && recip !== r0)              bad = 1'b1;
            if (exact === 1'b1 && err === 1'b1)              bad = 1'b1;
            if (err === 1'b1 && recip !== 14'd0)             bad = 1'b1;
            if (err !== 1'b1 && recip === 14'd0)             bad = 1'b1;
            if ((nflag === 1'b1) !== (rnshift !== 4'd0))     bad = 1'b1;
            if ((^recip === 1'bx) || (^r0 === 1'bx))         bad = 1'b1;
            if ((^resid === 1'bx) || (^ridx === 1'bx))       bad = 1'b1;
            if ((^rwt === 1'bx) || (^rnshift === 1'bx))      bad = 1'b1;
            if ((^done === 1'bx) || (^iter === 1'bx))        bad = 1'b1;
            if (valid === 1'bx || err === 1'bx)              bad = 1'b1;
            if (sticky === 1'bx || exact === 1'bx)           bad = 1'b1;
            if (nflag === 1'bx || busy === 1'bx)             bad = 1'b1;
            // ---- fold the observation
            ips_fnv_word({17'd0, recip});
            ips_fnv_word({17'd0, r0});
            ips_fnv_word({17'd0, resid});
            ips_fnv_word({24'd0, rnshift, nflag, exact, err, sticky});
            ips_fnv_word({19'd0, ridx, rwt});
            ips_fnv_word({24'd0, done});
        end
    end

    repeat (4) @(negedge ips_clk);
    if (nres != OPS)             bad = 1'b1;
    if (done !== 8'h00)          bad = 1'b1;   // 256 published operations wrap
    if (sticky !== 1'b1)         bad = 1'b1;   // the divide-by-zero case must latch
    if (valid !== 1'b0)          bad = 1'b1;
    if (busy !== 1'b0)           bad = 1'b1;
    ips_fnv_word({24'd0, done});
    ips_fnv_word({24'd0, sticky});
    ips_fnv_word(OPS);

    ips_verdict(!bad, "ips_reciprocal_lut");
end

endmodule
