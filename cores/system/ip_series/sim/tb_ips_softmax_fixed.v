`timescale 1ns / 1ps
// tb_ips_softmax_fixed : production-line testbench for the three-pass softmax.
//
// NVEC vectors of 16 signed logits are streamed as 48 beats each (pass 0 running
// max, pass 1 exp-LUT sum, pass 2 reciprocal-normalised probabilities); every
// logits value is re-presented on all three passes exactly as
// models/ips_softmax_fixed.py documents.  The vector patterns are deterministic
// and cover the required corners: an exact delta 0..15 ramp (full exp-LUT
// coverage), an all-tied vector where every lane is a maximum, both LB rails, a
// single dominant lane whose reciprocal bucket clamps its probability, and two
// LCG-derived random flavours.  Extra beats with in_valid low check that the whole
// published state holds.
// Only DUT output state is folded; properties use === / !== so an X can never look
// like a pass (docs/IP_CORE_SOP.md trap T6), and the phase-sensitive properties are
// written against the core's own ph_last so they stay legal for any geometry.
// The run ends after a fixed number of edges, never on a DUT-conditional state.
module tb_ips_softmax_fixed;

`include "ips_tb_common.vh"

localparam integer LANES_TB = 16;
localparam integer PBS      = 48;
localparam integer NVEC     = 8;
localparam integer NB       = NVEC * PBS;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg signed [11:0]  lgd;
reg [31:0]         state;

wire signed [11:0] rmaxw;
wire [12:0]        rsumw;
wire [7:0]         explast;
wire [7:0]         pw;
wire               p_vld;
wire               sat_sticky;
wire [7:0]         clip_count;
wire [1:0]         ph_last;
wire [13:0]        resid;
wire [31:0]        cfg_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_softmax_fixed dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .lg         (lgd),
    .rmax       (rmaxw),
    .rsum       (rsumw),
    .exp_last   (explast),
    .p          (pw),
    .p_vld      (p_vld),
    .sat_sticky (sat_sticky),
    .clip_count (clip_count),
    .ph_last    (ph_last),
    .resid      (resid),
    .cfg_id     (cfg_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

reg signed [11:0] lga [0:15];

integer i;
integer l;
integer v;
integer ph;
integer ln;
integer nb;
reg        bad;
reg        xbad;
reg [13:0] prev_resid;
reg [11:0] prev_rmax;
reg [12:0] prev_rsum;
reg [7:0]  prev_e;
reg [7:0]  prev_p;
reg [1:0]  prev_ph;
reg        prev_sat;
reg        prev_vld;

// One observation window: the beat presented since the last posedge must have
// published the documented state transitions, and nothing may move when the beat
// was not presented at all.
task observe;
    input consumed;
    begin
        xbad = 1'b0;
        if ((^rmaxw) === 1'bx) xbad = 1'b1;
        if ((^rsumw) === 1'bx) xbad = 1'b1;
        if ((^explast) === 1'bx) xbad = 1'b1;
        if ((^pw) === 1'bx) xbad = 1'b1;
        if ((^resid) === 1'bx) xbad = 1'b1;
        if ((^clip_count) === 1'bx) xbad = 1'b1;
        if ((^cfg_id) === 1'bx) xbad = 1'b1;
        if (p_vld === 1'bx || sat_sticky === 1'bx) xbad = 1'b1;
        if ((^ph_last) === 1'bx) xbad = 1'b1;
        if (xbad !== 1'b0) bad = 1'b1;

        if (p_vld !== (ph_last === 2'd2)) bad = 1'b1;
        if (ph_last === 2'd0 && rsumw !== 13'd0) bad = 1'b1;
        if (ph_last === 2'd0 && explast !== prev_e) bad = 1'b1;
        if (ph_last !== 2'd2 && pw !== prev_p) bad = 1'b1;
        if (ph_last === 2'd1 && sat_sticky !== prev_sat) bad = 1'b1;

        if (ph_last !== 2'd0) begin
            if (lgd === rmaxw && explast !== 8'hff) bad = 1'b1;
            if (explast === 8'hff && lgd !== rmaxw) bad = 1'b1;
        end

        if (consumed) begin
            if (ph_last === 2'd2 && resid !== prev_resid + {6'd0, pw}) bad = 1'b1;
        end else begin
            if (rmaxw !== prev_rmax) bad = 1'b1;
            if (rsumw !== prev_rsum) bad = 1'b1;
            if (explast !== prev_e) bad = 1'b1;
            if (pw !== prev_p) bad = 1'b1;
            if (ph_last !== prev_ph) bad = 1'b1;
            if (sat_sticky !== prev_sat) bad = 1'b1;
            if (p_vld !== prev_vld) bad = 1'b1;
            if (resid !== prev_resid) bad = 1'b1;
        end

        ips_fnv_word({20'd0, rmaxw});
        ips_fnv_word({19'd0, rsumw});
        ips_fnv_word({16'd0, explast, pw});
        ips_fnv_word({28'd0, ph_last, p_vld, sat_sticky});
        ips_fnv_word({18'd0, resid});
        ips_fnv_word(cfg_id);

        prev_rmax  = rmaxw;
        prev_rsum  = rsumw;
        prev_resid = resid;
        prev_e     = explast;
        prev_p     = pw;
        prev_ph    = ph_last;
        prev_sat   = sat_sticky;
        prev_vld   = p_vld;
        nb         = nb + 1;
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    in_valid   = 1'b0;
    lgd        = 12'sd0;
    state      = 32'h5C0FFEE1;
    bad        = 1'b0;
    nb         = 0;
    prev_rmax  = 12'd0;
    prev_rsum  = 13'd0;
    prev_resid = 14'd0;
    prev_e     = 8'h00;
    prev_p     = 8'h00;
    prev_ph    = 2'd0;
    prev_sat   = 1'b0;
    prev_vld   = 1'b0;
    for (l = 0; l < LANES_TB; l = l + 1) begin
        lga[l] = 12'sd0;
    end

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < NB; i = i + 1) begin
        if ((i % PBS) == 0) begin
            v = i / PBS;
            for (l = 0; l < LANES_TB; l = l + 1) begin
                state = state * 32'd1664525 + 32'd1013904223;
                case (v % 6)
                    0:       lga[l] = 12'd64 - l;
                    1:       lga[l] = 12'd100;
                    2:       lga[l] = {4'd0, state[7:0]};
                    3:       lga[l] = (l == 0) ? 12'sd0 : 12'h800;
                    4:       lga[l] = (l < 3) ? 12'h7ff : 12'h800;
                    default: lga[l] = {4'd0, state[7:0]} - 12'd128;
                endcase
            end
        end

        ph = i % PBS;
        ln = ph % LANES_TB;

        @(negedge ips_clk);
        lgd      = lga[ln];
        in_valid = 1'b1;

        @(negedge ips_clk);
        in_valid = 1'b0;
        observe(1'b1);

        if ((i % 16) == 15) begin
            @(negedge ips_clk);
            observe(1'b0);
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

    ips_verdict(!bad, "ips_softmax_fixed");
end

endmodule
