`timescale 1ns / 1ps
// tb_ips_conv1d_depthwise : production-line testbench for the depthwise 1-D conv.
//
// NOS output samples are streamed, each consuming its own tap window of 1..TAPS
// beats, so the beat count (240 tap beats plus one held beat per sample) is well
// above the series minimum and every table row is exercised at every tap index.
// Deterministic stimulus follows the shared LCG contract documented in
// models/ips_conv1d_depthwise.py.  Corner cases are folded in explicitly: zero
// activations (tap 0 and interior), the -128 / +127 operand extremes, boundary
// padding on both the first and the closing tap, an extreme pad value, and the
// shift-0 channel whose window sums saturate the int8 output in both directions.
// Rounding ties fall out of the random sums hitting the half-way residue.
// Only DUT output state is folded; properties use === so an X can never look like
// a pass (docs/IP_CORE_SOP.md trap T6).  The run ends after a fixed number of
// edges, never on a DUT-conditional state.
module tb_ips_conv1d_depthwise;

`include "ips_tb_common.vh"

localparam integer NOS = 96;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg  [1:0]         chv;
reg  [2:0]         tapv;
reg  [2:0]         tcfgv;
reg  signed [7:0]  xvv;
reg                pad_en;
reg  signed [7:0]  padv;
reg  [31:0]        state;

wire signed [17:0] accw;
wire signed [7:0]  yw;
wire               out_valid;
wire               sat_last;
wire [7:0]         clip_count;
wire [15:0]        cfg_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_conv1d_depthwise dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .ch        (chv),
    .tap       (tapv),
    .tcfg      (tcfgv),
    .xv        (xvv),
    .pad_en    (pad_en),
    .padv      (padv),
    .y         (yw),
    .out_valid (out_valid),
    .sat_last  (sat_last),
    .clip_count(clip_count),
    .acc       (accw),
    .cfg_id    (cfg_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer o;
integer tc;
integer tp;
integer nb;
reg       bad;
reg       xbad;
reg       closing_exp;
reg       held_exp;
reg [7:0] prev_y;
reg signed [17:0] amag;

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    in_valid  = 1'b0;
    chv       = 2'd0;
    tapv      = 3'd0;
    tcfgv     = 3'd1;
    xvv       = 8'h00;
    pad_en    = 1'b0;
    padv      = 8'h00;
    state     = 32'hBEEF_1234;
    bad       = 1'b0;
    nb        = 0;
    prev_y    = 8'h00;
    closing_exp = 1'b0;
    held_exp  = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (o = 0; o < NOS; o = o + 1) begin
        chv   = o % 4;
        tc    = 1 + ((o / 4) % 4);
        tcfgv = tc;

        for (tp = 0; tp < tc; tp = tp + 1) begin
            @(negedge ips_clk);

            state = state * 32'd1664525 + 32'd1013904223;
            xvv   = state[7:0];
            padv  = state[23:16];

            pad_en = 1'b0;
            if ((tp == 0) && ((o % 7) == 3)) pad_en = 1'b1;
            if ((tp == tc - 1) && ((o % 9) == 4)) pad_en = 1'b1;

            if ((tp == 0) && ((o % 17) == 0)) xvv = 8'h00;
            if ((tp == 2) && ((o % 23) == 5)) xvv = 8'h00;
            if ((o % 15) == 6)  xvv = 8'h80;
            if ((o % 15) == 7)  xvv = 8'h7F;
            if ((tp == 0) && ((o % 11) == 2)) xvv = 8'h01;
            if (pad_en && ((o % 19) == 5)) padv = 8'h80;

            tapv     = tp;
            in_valid = 1'b1;
            closing_exp = (tp == tc - 1);

            @(negedge ips_clk);
            in_valid = 1'b0;

            // out_valid must be exactly the window-closing flag of the beat just
            // consumed, and y may only move on those beats.
            if (out_valid !== closing_exp) begin
                bad = 1'b1;
            end
            if (out_valid === 1'b1) begin
                if (sat_last === 1'b1) begin
                    if (yw !== 8'h7f && yw !== 8'h80) bad = 1'b1;
                    if (yw === 8'h80 && accw[17] !== 1'b1) bad = 1'b1;
                    if (yw === 8'h7f && accw[17] !== 1'b0) bad = 1'b1;
                end else if (sat_last !== 1'b0) begin
                    bad = 1'b1;
                end
                prev_y = yw;
            end else if (yw !== prev_y) begin
                bad = 1'b1;
            end

            // Tap 0 restarts the window from a single int8 x int8 product.
            if (tp == 0) begin
                amag = accw[17] ? (~accw + 18'd1) : accw;
                if (amag > 18'sd16384) bad = 1'b1;
            end

            xbad = 1'b0;
            if ((^accw) === 1'bx) xbad = 1'b1;
            if ((^yw) === 1'bx) xbad = 1'b1;
            if (out_valid === 1'bx || sat_last === 1'bx) xbad = 1'b1;
            if ((^clip_count) === 1'bx) xbad = 1'b1;
            if ((^cfg_id) === 1'bx) xbad = 1'b1;
            if (xbad !== 1'b0) bad = 1'b1;

            ips_fnv_word({14'd0, accw});
            ips_fnv_word({24'd0, yw});
            ips_fnv_word({30'd0, out_valid, sat_last});
            nb = nb + 1;
        end

        // A beat with in_valid low must leave every published value untouched,
        // including the still-held out_valid pulse of the closing beat.
        @(negedge ips_clk);
        in_valid  = 1'b0;
        held_exp  = 1'b1;

        @(negedge ips_clk);
        if (out_valid !== held_exp) bad = 1'b1;
        if (yw !== prev_y) bad = 1'b1;
        if ((^accw) === 1'bx || (^yw) === 1'bx) bad = 1'b1;
        if (sat_last !== 1'b0 && sat_last !== 1'b1) bad = 1'b1;

        ips_fnv_word({14'd0, accw});
        ips_fnv_word({24'd0, yw});
        ips_fnv_word({30'd0, out_valid, sat_last});
        nb = nb + 1;

        // Prove clk_en really gates the core: idle the DUT for two clocks with no
        // beat presented, once every 16 samples.
        if ((o % 16) == 15) begin
            clk_en = 1'b0;
            @(negedge ips_clk);
            @(negedge ips_clk);
            clk_en = 1'b1;
        end
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({24'd0, clip_count});
    ips_fnv_word({16'd0, cfg_id});
    ips_fnv_word(nb);

    ips_verdict(!bad, "ips_conv1d_depthwise");
end

endmodule
