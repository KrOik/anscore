`timescale 1ns / 1ps
// tb_ips_quant_int8_sym : production-line testbench for the symmetric quantise /
// dequantise pair.
//
// BEATS deterministic beats follow the shared LCG contract documented in
// models/ips_quant_int8_sym.py.  Corners folded in explicitly (slots of i % 64):
// zero operand, both activation rails (+2047 / -2048), both int8 operand extremes
// (+127 / -127), an exact half-way residue on the channel whose scale divides by
// two (round-half-away and round-half-to-even must disagree), a channel whose
// reciprocal scale is coarse enough that a non-zero operand rounds to zero (the
// quantisation dead zone), a quantise beat that saturates the int8 rail from both
// signs and a dequantise beat that saturates the int16 rail from both signs.
// Channels 0..3 rotate every beat and both directions run in blocks of five, so all
// four programmable fine shifts and both scale tables are used.  Only DUT output
// state is folded; properties use === / !== so an X can never look like a pass
// (docs/IP_CORE_SOP.md trap T6).  The run ends after a fixed number of edges, never
// on a DUT-conditional state.
module tb_ips_quant_int8_sym;

`include "ips_tb_common.vh"

localparam integer BEATS = 300;
localparam [31:0] SEED = 32'h7A1F_00D5;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg                dirv;
reg  [1:0]         chv;
reg  signed [11:0] xv;
reg  [31:0]        state;

wire signed [7:0]  yq;
wire signed [15:0] ydq;
wire [15:0]        ymag;
wire               y_neg;
wire               y_vld;
wire               clipped_last;
wire               sat_q;
wire               sat_d;
wire               udf_sticky;
wire [7:0]         clip_count;
wire [31:0]        cfg_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_quant_int8_sym dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .in_valid     (in_valid),
    .dir          (dirv),
    .ch           (chv),
    .x            (xv),
    .yq           (yq),
    .ydq          (ydq),
    .ymag         (ymag),
    .y_neg        (y_neg),
    .y_vld        (y_vld),
    .clipped_last (clipped_last),
    .sat_q        (sat_q),
    .sat_d        (sat_d),
    .udf_sticky   (udf_sticky),
    .clip_count   (clip_count),
    .cfg_id       (cfg_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer nb;
integer slot;
reg        bad;
reg        xbad;
reg        consumed;
reg        held;
reg [7:0]  yq_chk;
reg [15:0] ydq_chk;
reg [15:0] prev_ymag;
reg [7:0]  prev_yq;
reg [15:0] prev_ydq;
reg        prev_neg;
reg        prev_clip;
reg        prev_satq;
reg        prev_satd;
reg        prev_udf;

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    in_valid   = 1'b0;
    dirv       = 1'b0;
    chv        = 2'd0;
    xv         = 12'sd0;
    state      = SEED;
    bad        = 1'b0;
    nb         = 0;
    consumed   = 1'b0;
    held       = 1'b0;
    prev_ymag  = 16'd0;
    prev_yq    = 8'd0;
    prev_ydq   = 16'd0;
    prev_neg   = 1'b0;
    prev_clip  = 1'b0;
    prev_satq  = 1'b0;
    prev_satd  = 1'b0;
    prev_udf   = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        state = state * 32'd1664525 + 32'd1013904223;
        xv    = state[11:0];
        chv   = i % 4;
        dirv  = ((i / 5) % 2) == 1;
        slot  = i % 64;

        if (slot == 3)  xv = 12'sd0;        // zero operand
        if (slot == 7)  xv = 12'h7ff;       // positive activation rail
        if (slot == 15) xv = 12'h800;       // negative activation rail
        if (slot == 23) xv = 12'h07f;       // int8 operand +127
        if (slot == 31) xv = 12'h081;       // int8 operand -127
        if (slot == 39) begin               // exact half-way residue, quantise
            chv = 2'd1;
            dirv = 1'b0;
            xv = 12'd512;
        end
        if (slot == 47) begin               // non-zero operand rounds to zero
            chv = 2'd2;
            dirv = 1'b0;
            xv = 12'sd40;
        end
        if (slot == 55) begin               // int8 rail from the positive side
            chv = 2'd0;
            dirv = 1'b0;
            xv = 12'sd1200;
        end
        if (slot == 59) begin               // int8 rail from the negative side
            chv = 2'd0;
            dirv = 1'b0;
            xv = -12'sd1200;
        end
        if (slot == 61) begin               // int16 rail, negative operand
            chv = 2'd0;
            dirv = 1'b1;
            xv = 12'h081;
        end
        if (slot == 63) begin               // int16 rail, positive operand
            chv = 2'd0;
            dirv = 1'b1;
            xv = 12'h07f;
        end

        in_valid = 1'b1;
        consumed = 1'b1;
        held     = 1'b0;

        @(negedge ips_clk);
        in_valid = 1'b0;
        observe;

        if ((i % 23) == 22) begin
            // One extra beat with in_valid low: y_vld follows in_valid, everything
            // else must be bit-identical to the previous observation.
            @(negedge ips_clk);
            consumed = 1'b0;
            held     = 1'b1;
            observe;
        end

        if ((i % 40) == 39) begin
            clk_en = 1'b0;
            @(negedge ips_clk);
            @(negedge ips_clk);
            clk_en = 1'b1;
        end
    end

    repeat (4) @(negedge ips_clk);
    ips_fnv_word({24'd0, clip_count});
    ips_fnv_word(nb);

    ips_verdict(!bad, "ips_quant_int8_sym");
end

task observe;
    begin
        xbad = 1'b0;
        if ((^yq) === 1'bx) xbad = 1'b1;
        if ((^ydq) === 1'bx) xbad = 1'b1;
        if ((^ymag) === 1'bx) xbad = 1'b1;
        if ((^clip_count) === 1'bx) xbad = 1'b1;
        if ((^cfg_id) === 1'bx) xbad = 1'b1;
        if (y_neg === 1'bx || y_vld === 1'bx) xbad = 1'b1;
        if (clipped_last === 1'bx || sat_q === 1'bx) xbad = 1'b1;
        if (sat_d === 1'bx || udf_sticky === 1'bx) xbad = 1'b1;
        if (xbad !== 1'b0) bad = 1'b1;

        if (y_vld !== consumed) bad = 1'b1;

        if (held) begin
            if (ymag !== prev_ymag) bad = 1'b1;
            if (yq !== prev_yq) bad = 1'b1;
            if (ydq !== prev_ydq) bad = 1'b1;
            if (y_neg !== prev_neg) bad = 1'b1;
            if (clipped_last !== prev_clip) bad = 1'b1;
        end

        // A published magnitude always sits inside the rail of its direction and
        // the narrowed views agree with it.
        if (y_vld === 1'b1) begin
            if (dirv === 1'b0) begin
                if (ymag > 16'd127) bad = 1'b1;
                yq_chk = y_neg ? (~ymag[7:0] + 8'd1) : ymag[7:0];
                if (yq !== yq_chk) bad = 1'b1;
            end else begin
                ydq_chk = y_neg ? (~ymag + 16'd1) : ymag;
                if (ydq !== ydq_chk) bad = 1'b1;
            end
            if (clipped_last === 1'b1) begin
                if (dirv === 1'b0 && ymag !== 16'd127) bad = 1'b1;
                if (dirv === 1'b1 && ymag !== 16'd32767) bad = 1'b1;
            end else if (clipped_last !== 1'b0) begin
                bad = 1'b1;
            end
        end

        // Sticky flags never fall back.
        if (prev_satq === 1'b1 && sat_q !== 1'b1) bad = 1'b1;
        if (prev_satd === 1'b1 && sat_d !== 1'b1) bad = 1'b1;
        if (prev_udf === 1'b1 && udf_sticky !== 1'b1) bad = 1'b1;

        ips_fnv_word({16'd0, ymag});
        ips_fnv_word({24'd0, yq});
        ips_fnv_word({16'd0, ydq});
        ips_fnv_word({26'd0, sat_q, sat_d, udf_sticky, clipped_last, y_neg, y_vld});
        ips_fnv_word(cfg_id);

        prev_ymag = ymag;
        prev_yq   = yq;
        prev_ydq  = ydq;
        prev_neg  = y_neg;
        prev_clip = clipped_last;
        prev_satq = sat_q;
        prev_satd = sat_d;
        prev_udf  = udf_sticky;
        nb        = nb + 1;
    end
endtask

endmodule
