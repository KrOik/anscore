`timescale 1ns / 1ps
// tb_ips_bn_fold_lut : production-line testbench for the batch-norm folding helper.
//
// BEATS deterministic beats follow the shared LCG contract documented in
// models/ips_bn_fold_lut.py.  Corners folded in explicitly on slots of i % 64: zero
// operand, both 12-bit operand rails, a weight beat that saturates the WB rails from
// both signs, a bias beat that saturates the BB rails from both signs, an exact
// half-way residue (round-half-up must give +7 for 6.5 and -6 for -6.5, so neither
// round-half-away nor round-half-to-even can match), a zero operand with a non-zero
// addend (the addend path must survive the multiply being zero) and slots that walk
// every one of the eight channel pairs.  Channels rotate every beat and the two
// directions run in blocks of three, so each path refreshes only its own register.
// Only DUT output state is folded; properties use === / !== so an X can never look
// like a pass (docs/IP_CORE_SOP.md trap T6).  The run ends after a fixed number of
// edges, never on a DUT-conditional state.
module tb_ips_bn_fold_lut;

`include "ips_tb_common.vh"

localparam integer BEATS = 280;
localparam [31:0] SEED = 32'hC0FF_EE11;
localparam integer WBT = 8;
localparam integer BBT = 16;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg                selv;
reg  [2:0]         chv;
reg  signed [11:0] wv;
reg  [31:0]        state;

wire signed [7:0]  yw;
wire signed [15:0] yb;
wire signed [23:0] fs_last;
wire               y_vld;
wire               sel_last;
wire [2:0]         ch_last;
wire               oor;
wire               oor_w;
wire               oor_b;
wire [7:0]         clip_count;
wire [31:0]        cfg_id;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the shipped configuration the manifest records.
ips_bn_fold_lut dut (
    .clk       (ips_clk),
    .clk_en    (clk_en),
    .rst_n     (rst_n),
    .in_valid  (in_valid),
    .sel       (selv),
    .ch        (chv),
    .w         (wv),
    .yw        (yw),
    .yb        (yb),
    .fs_last   (fs_last),
    .y_vld     (y_vld),
    .sel_last  (sel_last),
    .ch_last   (ch_last),
    .oor       (oor),
    .oor_w     (oor_w),
    .oor_b     (oor_b),
    .clip_count(clip_count),
    .cfg_id    (cfg_id)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
integer nb;
integer slot;
integer exp_clip;
reg        bad;
reg        xbad;
reg        consumed;
reg        held;
reg [23:0] sx;
reg [7:0]  prev_yw;
reg [15:0] prev_yb;
reg [23:0] prev_fs;
reg [2:0]  prev_ch;
reg        prev_sel;
reg        prev_oor;
reg        prev_oorw;
reg        prev_oorb;
reg [7:0]  prev_clip;

initial begin
    ips_fnv_reset();
    rst_n      = 1'b0;
    clk_en     = 1'b0;
    in_valid   = 1'b0;
    selv       = 1'b0;
    chv        = 3'd0;
    wv         = 12'sd0;
    state      = SEED;
    bad        = 1'b0;
    nb         = 0;
    slot       = 0;
    exp_clip   = 0;
    consumed   = 1'b0;
    held       = 1'b0;
    sx         = 24'd0;
    prev_yw    = 8'd0;
    prev_yb    = 16'd0;
    prev_fs    = 24'd0;
    prev_ch    = 3'd0;
    prev_sel   = 1'b0;
    prev_oor   = 1'b0;
    prev_oorw  = 1'b0;
    prev_oorb  = 1'b0;
    prev_clip  = 8'd0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        state = state * 32'd1664525 + 32'd1013904223;
        wv    = state[11:0];
        chv   = i % 8;
        selv  = ((i / 3) % 2) == 1;
        slot  = i % 64;

        if (slot == 3)  wv = 12'sd0;            // zero operand
        if (slot == 7)  wv = 12'h7ff;           // positive operand rail
        if (slot == 15) wv = 12'h800;           // negative operand rail
        if (slot == 23) begin                   // folded weight above the +rail
            chv = 3'd0;
            selv = 1'b0;
            wv = 12'h7ff;
        end
        if (slot == 25) begin                   // folded weight below the -rail
            chv = 3'd0;
            selv = 1'b0;
            wv = 12'h800;
        end
        if (slot == 31) begin                   // folded bias above the +rail
            chv = 3'd3;
            selv = 1'b1;
            wv = 12'h200;
        end
        if (slot == 33) begin                   // folded bias below the -rail
            chv = 3'd7;
            selv = 1'b1;
            wv = 12'h201;
        end
        if (slot == 39) begin                   // exact half-way residue, weight
            chv = 3'd3;
            selv = 1'b0;
            wv = 12'sd8;
        end
        if (slot == 41) begin                   // same residue with the addend, fits
            chv = 3'd3;
            selv = 1'b1;
            wv = 12'sd8;
        end
        if (slot == 47) begin                   // negative half-way residue
            chv = 3'd3;
            selv = 1'b0;
            wv = -12'sd8;
        end
        if (slot == 53) begin                   // zero operand, non-zero addend
            chv = 3'd2;
            selv = 1'b1;
            wv = 12'sd0;
        end
        if (slot == 59) begin                   // negative multiplier, positive rail
            chv = 3'd7;
            selv = 1'b0;
            wv = 12'h800;
        end
        if (slot == 61) begin                   // negative addend, fits
            chv = 3'd6;
            selv = 1'b1;
            wv = 12'h7ff;
        end

        in_valid = 1'b1;
        consumed = 1'b1;
        held     = 1'b0;

        @(negedge ips_clk);
        in_valid = 1'b0;
        observe;

        if ((i % 29) == 28) begin
            // One extra beat with in_valid low: every published value must be
            // bit-identical to the previous observation.
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

    ips_verdict(!bad, "ips_bn_fold_lut");
end

task observe;
    begin
        xbad = 1'b0;
        if ((^yw) === 1'bx) xbad = 1'b1;
        if ((^yb) === 1'bx) xbad = 1'b1;
        if ((^fs_last) === 1'bx) xbad = 1'b1;
        if ((^clip_count) === 1'bx) xbad = 1'b1;
        if ((^cfg_id) === 1'bx) xbad = 1'b1;
        if ((^ch_last) === 1'bx) xbad = 1'b1;
        if (y_vld === 1'bx || sel_last === 1'bx) xbad = 1'b1;
        if (oor === 1'bx || oor_w === 1'bx || oor_b === 1'bx) xbad = 1'b1;
        if (xbad !== 1'b0) bad = 1'b1;

        if (y_vld !== consumed) bad = 1'b1;

        if (held) begin
            if (fs_last !== prev_fs) bad = 1'b1;
            if (yw !== prev_yw) bad = 1'b1;
            if (yb !== prev_yb) bad = 1'b1;
            if (sel_last !== prev_sel) bad = 1'b1;
            if (ch_last !== prev_ch) bad = 1'b1;
            if (oor !== prev_oor) bad = 1'b1;
            if (clip_count !== prev_clip) bad = 1'b1;
        end

        if (y_vld === 1'b1) begin
            // The narrowing view agrees with the published pre-narrowing value, and
            // an out-of-range beat sits exactly on the rail of its own path.
            if (sel_last === 1'b0) begin
                sx = {{(24 - WBT){fs_last[WBT-1]}}, fs_last[WBT-1:0]};
                if (oor !== (sx !== fs_last)) bad = 1'b1;
                if (oor === 1'b0 && yw !== fs_last[WBT-1:0]) bad = 1'b1;
                if (oor === 1'b1) begin
                    if ((yw !== 8'h7f) && (yw !== 8'h80)) bad = 1'b1;
                    if (yw[WBT-1] !== fs_last[23]) bad = 1'b1;
                end
                if (yb !== prev_yb) bad = 1'b1;
            end else begin
                sx = {{(24 - BBT){fs_last[BBT-1]}}, fs_last[BBT-1:0]};
                if (oor !== (sx !== fs_last)) bad = 1'b1;
                if (oor === 1'b0 && yb !== fs_last[BBT-1:0]) bad = 1'b1;
                if (oor === 1'b1) begin
                    if ((yb !== 16'h7fff) && (yb !== 16'h8000)) bad = 1'b1;
                    if (yb[BBT-1] !== fs_last[23]) bad = 1'b1;
                end
                if (yw !== prev_yw) bad = 1'b1;
            end
            exp_clip = exp_clip + (oor === 1'b1);
            if (clip_count !== exp_clip[7:0]) bad = 1'b1;
            if (oor_w === 1'b1 && prev_oorw !== 1'b1 && sel_last !== 1'b0) bad = 1'b1;
            if (oor_b === 1'b1 && prev_oorb !== 1'b1 && sel_last !== 1'b1) bad = 1'b1;
        end

        // Sticky flags never fall back.
        if (prev_oorw === 1'b1 && oor_w !== 1'b1) bad = 1'b1;
        if (prev_oorb === 1'b1 && oor_b !== 1'b1) bad = 1'b1;

        ips_fnv_word({8'd0, fs_last});
        ips_fnv_word({24'd0, yw});
        ips_fnv_word({16'd0, yb});
        ips_fnv_word({24'd0, oor_w, oor_b, oor, ch_last, sel_last, y_vld});
        ips_fnv_word(cfg_id);

        prev_fs   = fs_last;
        prev_yw   = yw;
        prev_yb   = yb;
        prev_sel  = sel_last;
        prev_ch   = ch_last;
        prev_oor  = oor;
        prev_clip = clip_count;
        prev_oorw = oor_w;
        prev_oorb = oor_b;
        nb        = nb + 1;
    end
endtask

endmodule
