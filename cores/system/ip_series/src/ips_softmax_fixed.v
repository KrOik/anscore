`timescale 1ns / 1ps
// ips_softmax_fixed : three-pass streaming softmax over LANES fixed-point logits.
//
// The core self-schedules over three consecutive lane passes, one logit per beat:
//   pass 0  running maximum            rmax <= max(rmax, lg)
//   pass 1  max-subtract + exp LUT sum delta = clamp(rmax - lg, 0, 15),
//                                      rsum <= rsum + EXP[delta]
//   pass 2  reciprocal normalise       p <= clamp((EXP[delta] * REC[rsum>>8]) >> 8)
// The vector state (rmax, rsum, psum, sat_sticky) is reinitialised on the first
// lane of pass 0, so the finished sums stay observable through the last pass-2
// beat.  resid is the sum-check residual psum - 255 of the quantised probability
// vector, sat_sticky says at least one probability clipped, and clip_count counts
// clipped probabilities over the whole run (8-bit, wraps).
//
// EXP and REC are constant vectors indexed by a variable part-select, so they map
// to LUT muxes and never to a Gowin BSRAM primitive (docs/IP_CORE_SOP.md).  The
// only multiply is the 8 x 10 unsigned probability scale.  models/ips_softmax_fixed.py
// restates every table constant and the whole contract independently.
//
// Port contract:
//   in_valid   one logit is consumed per enabled beat with in_valid high
//   lg         the logit of the current lane, signed LB-bit fixed point
//   ph_last    the pass the consumed beat belonged to
//   p_vld      the previous beat was a pass-2 beat and published p
//   cfg_id     geometry readback {LANES, LB, PB, tag}
//   Every register is gated by clk_en; rst_n is the active-low asynchronous reset
//   (docs/IP_CORE_SOP.md trap T2).
module ips_softmax_fixed #(
    parameter LANES = 16,
    parameter LB = 12,
    parameter PB = 8
)(
    input  wire                 clk,
    input  wire                 clk_en,
    input  wire                 rst_n,
    input  wire                 in_valid,
    input  wire signed [LB-1:0] lg,

    output reg  signed [LB-1:0] rmax,
    output reg  [12:0]          rsum,
    output reg  [7:0]           exp_last,
    output reg  [PB-1:0]        p,
    output reg                  p_vld,
    output reg                  sat_sticky,
    output reg  [7:0]           clip_count,
    output reg  [1:0]           ph_last,
    output wire signed [13:0]   resid,
    output wire [31:0]          cfg_id
);

// exp(-delta/2) * 255 for delta 0..15, one byte per delta, delta 0 in the least
// significant byte of EXPA.
wire [31:0] EXPA = {8'h39, 8'h5e, 8'h9b, 8'hff};
wire [31:0] EXPB = {8'h08, 8'h0d, 8'h15, 8'h23};
wire [31:0] EXPC = {8'h01, 8'h02, 8'h03, 8'h05};
wire [31:0] EXPD = {8'h00, 8'h00, 8'h00, 8'h01};
wire [127:0] EXPT = {EXPD, EXPC, EXPB, EXPA};

// floor(65280 / (bucket * 256 + 128)) in the low 10 bits of each 16-bit field,
// bucket 0 in the least significant field of REC0.
wire [63:0] REC0 = {16'h0048, 16'h0066, 16'h00aa, 16'h01fe};
wire [63:0] REC1 = {16'h0022, 16'h0027, 16'h002e, 16'h0038};
wire [63:0] REC2 = {16'h0016, 16'h0018, 16'h001a, 16'h001e};
wire [63:0] REC3 = {16'h0010, 16'h0011, 16'h0012, 16'h0014};
wire [255:0] RECIT = {REC3, REC2, REC1, REC0};

localparam integer LWIDTH = $clog2(LANES);
localparam integer LMAX = LANES - 1;
localparam [12:0] IDEAL = 13'd255;
localparam [9:0] PR_RAIL = {PB{1'b1}};
localparam [7:0] ID_LANES = LANES;
localparam [7:0] ID_LB = LB;
localparam [7:0] ID_PB = PB;

reg [LWIDTH-1:0] lane;
reg [1:0]        pass;
reg [12:0]       psum;

wire signed [LB:0]  dif;
wire                dbig;
wire        [3:0]   delta;
wire        [7:0]   ev;
wire        [3:0]   bkt;
wire        [9:0]   rrec;
wire        [17:0]  prod;
wire        [9:0]   praw;
wire                pclip;
wire        [PB-1:0] pfin;
wire        [12:0]  eext;
wire        [12:0]  pext;
wire                first_lane;
wire                lane_last;

assign dif   = rmax - lg;
assign dbig  = |dif[LB:4];
assign delta = dif[LB] ? 4'd0 : (dbig ? 4'hf : dif[3:0]);
assign ev    = EXPT[{delta, 3'd0} +: 8];
assign bkt   = rsum[11:8];
assign rrec  = RECIT[{bkt, 4'd0} +: 10];
assign prod  = ev * rrec;
assign praw  = prod[17:8];
assign pclip = (praw > PR_RAIL);
assign pfin  = pclip ? {PB{1'b1}} : praw[PB-1:0];
assign eext  = {5'd0, ev};
assign pext  = {{(13 - PB){1'b0}}, pfin};
assign first_lane = (lane == 0);
assign lane_last  = (lane == LMAX);
assign resid  = {1'b0, psum} - IDEAL;
assign cfg_id = {ID_LANES, ID_LB, ID_PB, 8'h5f};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rmax       <= {LB{1'b0}};
        rsum       <= 13'd0;
        psum       <= 13'd0;
        exp_last   <= 8'h00;
        p          <= {PB{1'b0}};
        p_vld      <= 1'b0;
        sat_sticky <= 1'b0;
        clip_count <= 8'h00;
        ph_last    <= 2'd0;
        lane       <= {LWIDTH{1'b0}};
        pass       <= 2'd0;
    end else if (clk_en) begin
        if (in_valid) begin
            ph_last <= pass;
            p_vld   <= 1'b0;
            if (pass == 2'd0) begin
                if (first_lane) begin
                    rmax       <= lg;
                    rsum       <= 13'd0;
                    psum       <= 13'd0;
                    sat_sticky <= 1'b0;
                end else if (lg > rmax) begin
                    rmax <= lg;
                end
            end else begin
                exp_last <= ev;
                if (pass == 2'd1) begin
                    rsum <= rsum + eext;
                end else begin
                    p     <= pfin;
                    p_vld <= 1'b1;
                    psum  <= psum + pext;
                    if (pclip) begin
                        sat_sticky <= 1'b1;
                        clip_count <= clip_count + 8'h01;
                    end
                end
            end
            if (lane_last) begin
                lane <= {LWIDTH{1'b0}};
                if (pass == 2'd2) begin
                    pass <= 2'd0;
                end else begin
                    pass <= pass + 2'd1;
                end
            end else begin
                lane <= lane + 1'b1;
            end
        end
    end
end

endmodule
