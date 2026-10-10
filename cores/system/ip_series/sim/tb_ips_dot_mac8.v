`timescale 1ns / 1ps
// tb_ips_dot_mac8 : production-line testbench for the 8-lane dot product core.
//
// Folding rule (the SAME contract is written into models/ips_dot_mac8.py, both
// sides derive it from the core's documented behaviour, never from simulation):
//   one observation per published vector, taken at the negedge after `valid`
//   pulses, and per observation these words in this order:
//     w0 = prod[31:0]                            lane 7 product, full precision
//     w1 = {26'd0, phase, headroom, sat_pos, sat_neg}
//          phase is the index of the last consumed lane (7); headroom is sampled
//          FIVE bits wide, one bit wider than GUARD = 4, so a GUARD change moves
//          the guard slice inside the folded word
//     w2 = acc                                   the saturating accumulator
//     w3 = {24'd0, sat_count, ovf_sticky, pub_first}
//   then once at the end: {24'd0, vec_count}, {24'd0, sat_count}, VECTORS.
//
// Stimulus contract shared with the model:
//   state = state * 32'd1664525 + 32'd1013904223 (mod 2**32) from 32'hD07A9000,
//   eight draws per vector: w0..w3 form av = {w3,w2,w1,w0}, u0..u3 form
//   bv = {u3,u2,u1,u0}; lane j is the 16-bit slice [j*16 +: 16], signed.
//   Directed vectors by m = i % 64: m==15 all lanes zero, m==31 every lane
//   -32768 * -32768 (largest positive sum), m==47 every lane -32768 * +32767
//   (largest negative sum), m==63 lane j even -> -32768, odd -> +32767 against
//   +32767.  Otherwise the random lanes are used.  first = (i % 32 == 0).
//   av/bv are held stable for the whole vector (the core documents a streaming
//   back-pressure contract: in_ready is low while it works); the directed pokes
//   here only touch in_valid and first, which a busy core must ignore.
//
// The expected stream is NOT computed here; the golden model is independent
// (docs/IP_CORE_SOP.md trap T1) and verdicts use === so X can never pass (T6).
module tb_ips_dot_mac8;

`include "ips_tb_common.vh"

localparam integer VECTORS = 256;
localparam [31:0]  SEED    = 32'hD07A9000;

reg                 rst_n;
reg                 clk_en;
reg                 in_valid;
reg                 first;
reg  [31:0]         state;
reg  [127:0]        av;
reg  [127:0]        bv;

wire                in_ready;
wire                busy;
wire signed [31:0]  acc;
wire signed [31:0]  prod;
wire [4:0]          headroom;
wire                sat_pos;
wire                sat_neg;
wire                ovf_sticky;
wire                pub_first;
wire                valid;
wire [7:0]          vec_count;
wire [7:0]          sat_count;
wire [2:0]          phase;
wire [1:0]          stage;

// No #() override here: the defaults are the shipped configuration, and the
// mutation station must see them.
ips_dot_mac8 dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .in_ready   (in_ready),
    .av         (av),
    .bv         (bv),
    .first      (first),
    .acc        (acc),
    .prod       (prod),
    .headroom   (headroom),
    .sat_pos    (sat_pos),
    .sat_neg    (sat_neg),
    .ovf_sticky (ovf_sticky),
    .pub_first  (pub_first),
    .valid      (valid),
    .vec_count  (vec_count),
    .sat_count  (sat_count),
    .busy       (busy),
    .phase      (phase),
    .stage      (stage)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer g;
integer r;
integer nres;
reg     bad;
reg     missing;

task build_vector;
    input integer idx;
    begin
        state = state * 32'd1664525 + 32'd1013904223;
        av    = {32'd0, 32'd0};
        bv    = {32'd0, 32'd0};
        // eight draws per vector: w0..w3 -> av, u0..u3 -> bv
        av[31:0]   = state;
        state = state * 32'd1664525 + 32'd1013904223;
        av[63:32]  = state;
        state = state * 32'd1664525 + 32'd1013904223;
        av[95:64]  = state;
        state = state * 32'd1664525 + 32'd1013904223;
        av[127:96] = state;
        state = state * 32'd1664525 + 32'd1013904223;
        bv[31:0]   = state;
        state = state * 32'd1664525 + 32'd1013904223;
        bv[63:32]  = state;
        state = state * 32'd1664525 + 32'd1013904223;
        bv[95:64]  = state;
        state = state * 32'd1664525 + 32'd1013904223;
        bv[127:96] = state;
        first      = ((idx % 32) == 0);
        case (idx % 64)
            15: begin
                av = {8{16'h0000}};
                bv = {8{16'h0000}};
            end
            31: begin
                av = {8{16'h8000}};
                bv = {8{16'h8000}};
            end
            47: begin
                av = {8{16'h8000}};
                bv = {8{16'h7fff}};
            end
            63: begin
                av = {4{16'h7fff, 16'h8000}};
                bv = {8{16'h7fff}};
            end
            default: ;
        endcase
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    in_valid  = 1'b0;
    first     = 1'b0;
    av        = 128'd0;
    bv        = 128'd0;
    state     = SEED;
    bad       = 1'b0;
    nres      = 0;
    missing   = 0;

    repeat (4) @(posedge ips_clk);
    @(negedge ips_clk);
    rst_n  = 1'b1;
    repeat (2) @(posedge ips_clk);
    @(negedge ips_clk);
    clk_en = 1'b1;

    // the engine must come out of reset idle and publish nothing yet
    if (in_ready !== 1'b1 || busy !== 1'b0 || valid !== 1'b0) bad = 1'b1;

    for (i = 0; i < VECTORS; i = i + 1) begin
        // ---- present the vector on the falling edge
        @(negedge ips_clk);
        build_vector(i);
        in_valid = 1'b1;

        // ---- hold the request while the engine is busy: this is the
        //      back-pressure / ignored-request case, the DUT must not sample it
        g = 0;
        while (in_ready !== 1'b1 && g < 40) begin
            g = g + 1;
            @(negedge ips_clk);
        end
        if (in_ready !== 1'b1) bad = 1'b1;

        @(posedge ips_clk);          // capture edge (in_valid && in_ready)
        @(negedge ips_clk);
        in_valid = 1'b0;
        if (in_ready === 1'b1) bad = 1'b1;   // engine is busy now

        if ((i % 16) == 7) begin
            // directed: a re-presentation plus a flipped `first` while the
            // multiply runs must be ignored completely
            first    = ~first;
            in_valid = 1'b1;
            @(negedge ips_clk);
            in_valid = 1'b0;
        end
        @(negedge ips_clk);

        if ((i % 16) == 11) begin
            // directed: clock-enable stall inside the multiply; every register
            // must hold (docs/IP_CORE_SOP.md trap T2)
            @(negedge ips_clk);
            clk_en = 1'b0;
            repeat (4) @(negedge ips_clk);
            clk_en = 1'b1;
        end

        // ---- wait for the published result
        r = 0;
        while (valid !== 1'b1 && r < 40) begin
            r = r + 1;
            @(posedge ips_clk);
            @(negedge ips_clk);
        end
        if (valid !== 1'b1) begin
            bad = 1'b1;
            missing = missing + 1;
        end else begin
            nres = nres + 1;
            // ---- structural properties, all with === so X fails (trap T6)
            if (sat_pos === 1'b1 && sat_neg === 1'b1)      bad = 1'b1;
            if (sat_pos === 1'b1 && acc !== 32'h7fffffff)  bad = 1'b1;
            if (sat_neg === 1'b1 && acc !== 32'h80000000)  bad = 1'b1;
            if (sat_pos === 1'b1 && headroom[3] === 1'b1)  bad = 1'b1;
            if (sat_neg === 1'b1 && headroom[3] === 1'b0)  bad = 1'b1;
            if ((sat_pos === 1'b1 || sat_neg === 1'b1) &&
                ovf_sticky !== 1'b1)                       bad = 1'b1;
            if (in_ready !== 1'b1)                         bad = 1'b1;
            if (busy === 1'b1)                             bad = 1'b1;
            if (stage !== 2'd0)                            bad = 1'b1;
            if (phase !== 3'd7)                            bad = 1'b1;
            if (vec_count !== nres[7:0])                   bad = 1'b1;
            if ((^prod === 1'bx) || (^acc === 1'bx))       bad = 1'b1;
            if ((^headroom === 1'bx) || (^phase === 1'bx)) bad = 1'b1;
            if ((^sat_count === 1'bx) || pub_first === 1'bx) bad = 1'b1;
            // ---- fold the observation
            ips_fnv_word(prod);
            ips_fnv_word({26'd0, phase, headroom, sat_pos, sat_neg});
            ips_fnv_word(acc);
            ips_fnv_word({24'd0, sat_count, ovf_sticky, pub_first});
        end
    end

    repeat (4) @(negedge ips_clk);
    if (nres != VECTORS)       bad = 1'b1;
    if (vec_count !== 8'h00)   bad = 1'b1;   // 256 published vectors wrap to zero
    if (ovf_sticky !== 1'b1)   bad = 1'b1;   // the directed beats must saturate
    ips_fnv_word({24'd0, vec_count});
    ips_fnv_word({24'd0, sat_count});
    ips_fnv_word(VECTORS);

    ips_verdict(!bad, "ips_dot_mac8");
end

endmodule
