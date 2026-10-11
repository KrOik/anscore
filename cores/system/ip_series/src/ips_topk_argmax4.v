`timescale 1ns / 1ps
// ips_topk_argmax4 : unordered top-4 of a fixed-size vector of signed scores.
//
// Contract, mirrored independently by models/ips_topk_argmax4.py.  One candidate
// score per beat, NSC beats per vector, index idx travelling with the score.  The
// core keeps a four-lane insertion list (lane 0 the largest) built from compares and
// muxes only -- no arithmetic beyond counting:
//   gt_k  = s >  t_k                                   signed compare
//   tie_k = s == t_k && idx < i_k                      equal score: lower index wins
//   a_k   = ~v_k | gt_k | tie_k                        an empty lane always accepts
//   pos   = the first k that accepts, 3'd4 when the score did not make the list
//   lanes above pos shift down by one, lane pos takes (s, idx)
//   the first beat of a vector (beat == 0) starts from an empty list, so its score
//   lands in lane 0 and the other lanes read the sentinel pair (MIN_SC, MAX_IX)
// Because every accepted score shifts the entries below it, no index can appear
// twice in the list while the vector supplies distinct indices; ties are resolved by
// index rather than by arrival order, which rep_last marks when an insertion was
// accepted only by the index comparison.  drop_last marks a beat whose score did not
// enter, drop_count / rep_count count them (8-bit, wrap) and done pulses on the beat
// that completes a vector.  v_k says whether lane k holds an entry of this vector.
// cfg_id is the geometry readback {SW, NSC, IB, tag}.
// Every register is gated by clk_en; rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).
module ips_topk_argmax4 #(
    parameter SW = 12,
    parameter NSC = 16,
    parameter IB = 4
)(
    input  wire                clk,
    input  wire                clk_en,
    input  wire                rst_n,
    input  wire                in_valid,
    input  wire signed [SW-1:0] s,
    input  wire [IB-1:0]       idx,

    output reg  signed [SW-1:0] t0,
    output reg  signed [SW-1:0] t1,
    output reg  signed [SW-1:0] t2,
    output reg  signed [SW-1:0] t3,
    output reg  [IB-1:0]        i0,
    output reg  [IB-1:0]        i1,
    output reg  [IB-1:0]        i2,
    output reg  [IB-1:0]        i3,
    output reg                  v0,
    output reg                  v1,
    output reg                  v2,
    output reg                  v3,
    output reg  [2:0]           pos_last,
    output reg  [IB:0]          beat_last,
    output reg                  done,
    output reg                  rep_last,
    output reg                  drop_last,
    output reg                  in_last,
    output reg  [7:0]           drop_count,
    output reg  [7:0]           rep_count,
    output wire [31:0]          cfg_id
);

wire signed [SW-1:0] MIN_SC = 12'h800;
wire [IB-1:0]        MAX_IX = 4'hf;
wire [7:0]           CNT_ONE = 8'h01;

localparam [7:0] ID_SW = SW;
localparam [7:0] ID_NSC = NSC;
localparam [7:0] ID_IB = IB;

reg  [IB:0] beat;
wire       first;
wire       last;
wire [IB:0] beat_nx;
wire       ev0, ev1, ev2, ev3;
wire       gt0, gt1, gt2, gt3;
wire       tie0, tie1, tie2, tie3;
wire       a0, a1, a2, a3;
wire [2:0] pos;
wire       ins;
wire [3:0] tsel;
wire       rep_now;
wire       drop_now;
wire signed [SW-1:0] nt0, nt1, nt2, nt3;
wire [IB-1:0]        ni0, ni1, ni2, ni3;
wire       nv0, nv1, nv2, nv3;

assign first   = (beat == 0);
assign last    = (beat == NSC - 1);
assign beat_nx = last ? 5'd0 : (beat + 5'd1);

assign ev0 = v0 & ~first;
assign ev1 = v1 & ~first;
assign ev2 = v2 & ~first;
assign ev3 = v3 & ~first;

assign gt0  = (s > t0);
assign gt1  = (s > t1);
assign gt2  = (s > t2);
assign gt3  = (s > t3);
assign tie0 = (s == t0) && (idx < i0) && ev0;
assign tie1 = (s == t1) && (idx < i1) && ev1;
assign tie2 = (s == t2) && (idx < i2) && ev2;
assign tie3 = (s == t3) && (idx < i3) && ev3;
assign a0   = ~ev0 | gt0 | tie0;
assign a1   = ~ev1 | gt1 | tie1;
assign a2   = ~ev2 | gt2 | tie2;
assign a3   = ~ev3 | gt3 | tie3;

assign pos  = a0 ? 3'd0 : (a1 ? 3'd1 : (a2 ? 3'd2 : (a3 ? 3'd3 : 3'd4)));
assign ins  = (pos < 3'd4);
assign tsel = {tie3, tie2, tie1, tie0};
assign rep_now = ins && tsel[pos];
assign drop_now = (pos == 3'd4);

assign nt0 = (pos == 3'd0) ? s : t0;
assign ni0 = (pos == 3'd0) ? idx : i0;
assign nv0 = (pos == 3'd0) ? 1'b1 : ev0;

assign nt1 = (pos == 3'd1) ? s : (first ? MIN_SC : ((pos < 3'd1) ? t0 : t1));
assign ni1 = (pos == 3'd1) ? idx : (first ? MAX_IX : ((pos < 3'd1) ? i0 : i1));
assign nv1 = (pos == 3'd1) ? 1'b1 : (first ? 1'b0 : ((pos < 3'd1) ? ev0 : ev1));

assign nt2 = (pos == 3'd2) ? s : (first ? MIN_SC : ((pos < 3'd2) ? t1 : t2));
assign ni2 = (pos == 3'd2) ? idx : (first ? MAX_IX : ((pos < 3'd2) ? i1 : i2));
assign nv2 = (pos == 3'd2) ? 1'b1 : (first ? 1'b0 : ((pos < 3'd2) ? ev1 : ev2));

assign nt3 = (pos == 3'd3) ? s : (first ? MIN_SC : ((pos < 3'd3) ? t2 : t3));
assign ni3 = (pos == 3'd3) ? idx : (first ? MAX_IX : ((pos < 3'd3) ? i2 : i3));
assign nv3 = (pos == 3'd3) ? 1'b1 : (first ? 1'b0 : ((pos < 3'd3) ? ev2 : ev3));

assign cfg_id = {ID_SW, ID_NSC, ID_IB, 8'h7d};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        t0         <= MIN_SC;
        t1         <= MIN_SC;
        t2         <= MIN_SC;
        t3         <= MIN_SC;
        i0         <= MAX_IX;
        i1         <= MAX_IX;
        i2         <= MAX_IX;
        i3         <= MAX_IX;
        v0         <= 1'b0;
        v1         <= 1'b0;
        v2         <= 1'b0;
        v3         <= 1'b0;
        pos_last   <= 3'd4;
        beat_last  <= 5'd0;
        done       <= 1'b0;
        rep_last   <= 1'b0;
        drop_last  <= 1'b0;
        in_last    <= 1'b0;
        drop_count <= 8'h00;
        rep_count  <= 8'h00;
        beat       <= 5'd0;
    end else if (clk_en) begin
        // done is the one-beat pulse the header promises: an idle beat clears it,
        // so a consumer with gaps in its score stream cannot count a vector twice.
        done   <= 1'b0;
        in_last <= in_valid;
        if (in_valid) begin
            t0        <= nt0;
            t1        <= nt1;
            t2        <= nt2;
            t3        <= nt3;
            i0        <= ni0;
            i1        <= ni1;
            i2        <= ni2;
            i3        <= ni3;
            v0        <= nv0;
            v1        <= nv1;
            v2        <= nv2;
            v3        <= nv3;
            pos_last  <= pos;
            beat_last <= beat;
            done      <= last;
            rep_last  <= rep_now;
            drop_last <= drop_now;
            beat      <= beat_nx;
            if (rep_now) begin
                rep_count <= rep_count + CNT_ONE;
            end
            if (drop_now) begin
                drop_count <= drop_count + CNT_ONE;
            end
        end
    end
end

endmodule
