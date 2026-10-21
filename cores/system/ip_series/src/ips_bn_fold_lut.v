`timescale 1ns / 1ps
// ips_bn_fold_lut : batch-norm folding helper.  For one channel per beat it folds
// the pre-computed (mult, add) pair out of the layer parameters and applies it to a
// weight tap (sel = 0) or to the layer bias (sel = 1), with fixed-point rounding and
// an out-of-range flag.
//
// Contract, mirrored independently by models/ips_bn_fold_lut.py.  ch selects one of
// eight channel slots; every slot holds a 12-bit signed multiplier and a 16-bit
// signed addend, read from constant LUT rows (pure muxes, no block RAM):
//   P    = w * M[ch]                     one signed product, SH-bit Q format
//   R    = P + (1 <<< (SH-1))            round half up on the shifted value
//   Q    = R >>> SH                      arithmetic shift, keeps the sign
//   fs   = sel ? Q + A[ch] : Q           the addend only folds into the bias path
//   yw   = fs clamped to the signed WB rails            (weight beats)
//   yb   = fs clamped to the signed BB rails            (bias beats)
//   oor  marks the beat whose narrowed value did not fit its own rails; oor_w /
//   oor_b are the sticky per-path flags and clip_count counts them (8-bit, wraps).
// Each path refreshes only its own register, so yw holds across bias beats and yb
// holds across weight beats; y_vld is the one-cycle echo of in_valid on the next
// enabled clock and fs_last is the published pre-narrowing value of the last beat.
// cfg_id is the geometry readback {SH, WB, BB, tag}.
// Every register is gated by clk_en; rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).
module ips_bn_fold_lut #(
    parameter SH = 9,
    parameter WB = 8,
    parameter BB = 16
)(
    input  wire                clk,
    input  wire                clk_en,
    input  wire                rst_n,
    input  wire                in_valid,
    input  wire                sel,
    input  wire [2:0]          ch,
    input  wire signed [11:0]  w,

    output reg  signed [WB-1:0] yw,
    output reg  signed [BB-1:0] yb,
    output reg  signed [23:0]   fs_last,
    output reg                  y_vld,
    output reg                  sel_last,
    output reg  [2:0]           ch_last,
    output reg                  oor,
    output reg                  oor_w,
    output reg                  oor_b,
    output reg  [7:0]           clip_count,
    output wire [31:0]          cfg_id
);

// Per-channel fold parameters.  Each entry is a 16-bit field so the slot index is a
// power-of-two stride (a plain mux select, no arithmetic); only the low IW bits of
// the multipliers are used.  Rows are written most-significant slot last, so the
// left-most literal of each row is slot 3 / slot 7 / slot 3 respectively.
wire [63:0] MULA = {16'h01a0, 16'h0200, 16'h00c0, 16'h0380};
wire [63:0] MULB = {16'h0f80, 16'h00ff, 16'h02c0, 16'h0060};
wire [63:0] ADDA = {16'h7ff0, 16'h0fc0, 16'hff80, 16'h0020};
wire [63:0] ADDB = {16'h8010, 16'hf040, 16'h0380, 16'h0000};

localparam integer IW = 12;
localparam integer AW = 16;
localparam integer PW = 24;
localparam signed [PW-1:0] HALF = (1 <<< (SH - 1));
localparam [7:0] ID_SH = SH;
localparam [7:0] ID_WB = WB;
localparam [7:0] ID_BB = BB;

wire signed [IW-1:0] m0, m1;
wire signed [AW-1:0] a0, a1;
wire [AW-1:0]        m0r, m1r;
wire signed [IW-1:0] m;
wire signed [AW-1:0] av;
wire signed [PW-1:0] aext;
wire signed [PW-1:0] prod;
wire signed [PW-1:0] rnd;
wire signed [PW-1:0] q;
wire signed [PW-1:0] fs;
wire [WB-1:0] wrail_p;
wire [WB-1:0] wrail_n;
wire [BB-1:0] brail_p;
wire [BB-1:0] brail_n;
wire wfit;
wire bfit;
wire oor_n;
wire [WB-1:0] yw_n;
wire [BB-1:0] yb_n;

assign m0r   = MULA[{ch[1:0], 4'd0} +: AW];
assign m1r   = MULB[{ch[1:0], 4'd0} +: AW];
assign m0    = m0r[IW-1:0];
assign m1    = m1r[IW-1:0];
assign m     = ch[2] ? m1 : m0;
assign a0    = ADDA[{ch[1:0], 4'd0} +: AW];
assign a1    = ADDB[{ch[1:0], 4'd0} +: AW];
assign av    = ch[2] ? a1 : a0;
assign aext  = {{(PW - AW){av[AW-1]}}, av};
assign prod  = w * m;
assign rnd   = prod + HALF;
assign q     = rnd >>> SH;
assign fs    = sel ? (q + aext) : q;
assign wrail_p = {1'b0, {(WB - 1){1'b1}}};
assign wrail_n = {1'b1, {(WB - 1){1'b0}}};
assign brail_p = {1'b0, {(BB - 1){1'b1}}};
assign brail_n = {1'b1, {(BB - 1){1'b0}}};
assign wfit  = (fs[PW-1:WB-1] == {(PW - WB + 1){fs[WB-1]}});
assign bfit  = (fs[PW-1:BB-1] == {(PW - BB + 1){fs[BB-1]}});
assign oor_n = sel ? ~bfit : ~wfit;
assign yw_n  = wfit ? fs[WB-1:0] : (fs[PW-1] ? wrail_n : wrail_p);
assign yb_n  = bfit ? fs[BB-1:0] : (fs[PW-1] ? brail_n : brail_p);
assign cfg_id = {ID_SH, ID_WB, ID_BB, 8'h2c};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        yw         <= {WB{1'b0}};
        yb         <= {BB{1'b0}};
        fs_last    <= {PW{1'b0}};
        y_vld      <= 1'b0;
        sel_last   <= 1'b0;
        ch_last    <= 3'd0;
        oor        <= 1'b0;
        oor_w      <= 1'b0;
        oor_b      <= 1'b0;
        clip_count <= 8'h00;
    end else if (clk_en) begin
        y_vld <= in_valid;
        if (in_valid) begin
            fs_last  <= fs;
            sel_last <= sel;
            ch_last  <= ch;
            oor      <= oor_n;
            if (sel) begin
                yb <= yb_n;
            end else begin
                yw <= yw_n;
            end
            if (oor_n) begin
                clip_count <= clip_count + 8'h01;
                if (sel) begin
                    oor_b <= 1'b1;
                end else begin
                    oor_w <= 1'b1;
                end
            end
        end
    end
end

endmodule
