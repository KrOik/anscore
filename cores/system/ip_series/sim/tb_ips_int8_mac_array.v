`timescale 1ns / 1ps
// tb_ips_int8_mac_array : production-line testbench for the int8 MAC array.
//
// BEATS deterministic beats follow the shared LCG contract documented in
// models/ips_int8_mac_array.py.  Corner cases are folded in explicitly: all-zero
// operands, the -128 x -128 and -128 x 127 product extremes, an odd product that
// exercises the rounding tie, and load beats that put the accumulator within one
// term of both int32 rails so saturation is observed in each direction.
// Only DUT output state is folded; properties use === so an X can never look like
// a pass (docs/IP_CORE_SOP.md trap T6).  The run ends after a fixed number of
// edges, never on a DUT-conditional state.
module tb_ips_int8_mac_array;

`include "ips_tb_common.vh"

localparam integer BEATS = 320;
localparam [31:0] SEED = 32'h1AC53B79;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg                load;
reg  [31:0]        state;
reg  [7:0]         x0, x1, x2, x3;
reg  [7:0]         w0, w1, w2, w3;
reg  [31:0]        b0, b1, b2, b3;
reg  [31:0]        xv, wv;
reg  [127:0]       biv;

wire [127:0]       acc;
wire [7:0]         headroom;
wire [3:0]         sat;
wire [7:0]         clip_count;
wire [31:0]        geom_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_int8_mac_array dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .load       (load),
    .x          (xv),
    .w          (wv),
    .bias       (biv),
    .acc        (acc),
    .headroom   (headroom),
    .sat        (sat),
    .clip_count (clip_count),
    .geom_id    (geom_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer g;
reg       bad;
reg       xbad;
reg       hr_exp;

// The two lane-level invariants below are stated for the shipped geometry, so
// they are only asserted when the core reports that geometry through geom_id.
// A mutated geometry then shows up in the folded digest instead of tripping a
// check that is no longer meaningful for it (the mutation station needs a
// complete run to compare digests).
wire [7:0] g_lanes = geom_id[31:24];
wire [7:0] g_accw  = geom_id[23:16];
wire [7:0] g_guard = geom_id[15:8];
wire       shipped_geom = (g_lanes === 8'd4) && (g_accw === 8'd32) &&
                          (g_guard === 8'd2) && (geom_id[7:0] === 8'hB7);

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    in_valid = 1'b0;
    load     = 1'b0;
    state    = SEED;
    xv       = 32'd0;
    wv       = 32'd0;
    biv      = 128'd0;
    bad      = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        // One LCG step per lane: x from bits 7:0, w from bits 23:16, and the raw
        // word as the row bias (consumed only on a load beat).
        state = state * 32'd1664525 + 32'd1013904223;
        x0 = state[7:0]; w0 = state[23:16]; b0 = state;
        state = state * 32'd1664525 + 32'd1013904223;
        x1 = state[7:0]; w1 = state[23:16]; b1 = state;
        state = state * 32'd1664525 + 32'd1013904223;
        x2 = state[7:0]; w2 = state[23:16]; b2 = state;
        state = state * 32'd1664525 + 32'd1013904223;
        x3 = state[7:0]; w3 = state[23:16]; b3 = state;

        load = ((i % 7) == 2);

        if ((i % 32) == 0) begin
            x0 = 8'h00; w0 = 8'h00;
        end
        if ((i % 16) == 5) begin
            x1 = 8'h80; w1 = 8'h80;
        end
        if ((i % 16) == 12) begin
            x2 = 8'h80; w2 = 8'h7F;
        end
        if ((i % 4) == 1) begin
            x3 = 8'h03; w3 = 8'h01;
        end

        if (load) begin
            // Fixed corner products on the load beat: +254, -384, -16256.
            x0 = 8'h7F; w0 = 8'h02;
            x1 = 8'h80; w1 = 8'h03;
            x3 = 8'h80; w3 = 8'h7F;
            b0 = 32'h7FFFFF80 + (b0 & 32'h000000FF);
            b1 = 32'h80000080 - (b1 & 32'h000000FF);
            b2 = b2 & 32'h00000FFF;
            b3 = 32'h80000010 - (b3 & 32'h0000000F);
        end

        xv  = {x0, x1, x2, x3};
        wv  = {w0, w1, w2, w3};
        biv = {b0, b1, b2, b3};

        in_valid = 1'b1;

        @(negedge ips_clk);
        in_valid = 1'b0;

        for (g = 0; g < 4; g = g + 1) begin
            // Lane g sits in the most-significant-first slice, so its sat bit is
            // 3-g, its headroom field is 7-2g downto 6-2g, and its accumulator
            // slice is 127-32g downto 96-32g.
            if (shipped_geom) begin
                hr_exp = acc[127 - 32*g];
                if (headroom[7 - 2*g -: 2] !== {2{hr_exp}}) begin
                    bad = 1'b1;
                end
                if (sat[3 - g] === 1'b1) begin
                    if (acc[127 - 32*g -: 32] !== 32'h7FFFFFFF &&
                        acc[127 - 32*g -: 32] !== 32'h80000000) begin
                        bad = 1'b1;
                    end
                end else if (sat[3 - g] !== 1'b0) begin
                    bad = 1'b1;
                end
            end
        end

        xbad = 1'b0;
        if ((^acc) === 1'bx) xbad = 1'b1;
        if ((^headroom) === 1'bx) xbad = 1'b1;
        if ((^sat) === 1'bx) xbad = 1'b1;
        if ((^clip_count) === 1'bx) xbad = 1'b1;
        if ((^geom_id) === 1'bx) xbad = 1'b1;
        if (xbad !== 1'b0) bad = 1'b1;

        ips_fnv_word(acc[127:96]);
        ips_fnv_word(acc[95:64]);
        ips_fnv_word(acc[63:32]);
        ips_fnv_word(acc[31:0]);
        ips_fnv_word({24'd0, headroom});
        ips_fnv_word({28'd0, sat});
        ips_fnv_word(geom_id);

        // Prove clk_en really gates the core: idle the DUT for two clocks while
        // no beat is presented, every 32nd beat.
        if ((i % 32) == 31) begin
            clk_en = 1'b0;
            @(negedge ips_clk);
            @(negedge ips_clk);
            clk_en = 1'b1;
        end
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({24'd0, clip_count});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_int8_mac_array");
end

endmodule
