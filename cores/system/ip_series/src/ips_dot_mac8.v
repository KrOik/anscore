`timescale 1ns / 1ps
// ips_dot_mac8 : eight-lane fixed-point dot product with a saturating int32
// accumulator, one time-shared multiplier (one lane per beat) and an overflow
// guard report.
//
// Contract, mirrored independently by models/ips_dot_mac8.py:
//   av / bv are FLAT lane bundles (docs/IP_CORE_SOP.md trap T3): lane j is
//   av[j*AW +: AW] and bv[j*BW +: BW], both two's complement signed.
//   in_ready is high only while the engine is idle.  A vector is accepted on the
//   enabled posedge where in_valid && in_ready; that beat only starts the engine
//   (stage -> ST_MAC, phase -> 0, first -> first_lat).  The following eight
//   enabled beats consume one lane each, in lane order j = phase = 0..7, through
//   the single multiplier, so one vector needs 1 + 8 = 9 enabled cycles.  Two
//   8:1 lane muxes instead of eight parallel multipliers is what keeps the core
//   inside its two DSP budget; the producer must hold av/bv stable while
//   in_ready is low (the normal streaming back-pressure contract).  in_valid and
//   first presented while busy are ignored.
//   Accumulation, per consumed lane j, with S signed in ACCW+GUARD bits:
//     p_j = (a_j * b_j) >>> PSH                      (PSH = 0, so exact)
//     S   = sign_extend(base) + sign_extend(p_j)
//     base = 0 for j = 0 when the accepted frame flag `first` was set,
//            otherwise the accumulator carried in from the previous vector
//     if S fits in ACCW signed bits: acc_next = S[ACCW-1:0], no saturation
//     else:                          acc_next = +-int32 boundary, sat_* set
//   Published on the beat that consumes lane 7:
//     prod      = a_7 * b_7 at full AW+BW precision (pre-shift)
//     headroom  = S[ACCW+GUARD-1:ACCW] of that last beat
//     sat_pos / sat_neg = that beat's clamp direction (never both)
//     sat_count counts saturating beats over all vectors (8 bit, wraps)
//     ovf_sticky latches the first saturation ever seen since reset
//     phase = 7 (the index of the lane the publishing beat consumed),
//     pub_first = the accepted frame flag, vec_count increments, valid pulses once
//   Every register is gated by clk_en and rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_dot_mac8 #(
    parameter AW    = 16,
    parameter BW    = 16,
    parameter ACCW  = 32,
    parameter GUARD = 4
)(
    input  wire                    clk,
    input  wire                    clk_en,
    input  wire                    rst_n,

    input  wire                    in_valid,
    output wire                    in_ready,
    input  wire  [8*AW-1:0]        av,
    input  wire  [8*BW-1:0]        bv,
    input  wire                    first,

    output reg  signed [ACCW-1:0]  acc,
    output reg  signed [AW+BW-1:0] prod,
    output reg  [GUARD-1:0]        headroom,
    output reg                     sat_pos,
    output reg                     sat_neg,
    output reg                     ovf_sticky,
    output reg                     pub_first,
    output reg                     valid,
    output reg  [7:0]              vec_count,
    output reg  [7:0]              sat_count,
    output wire                    busy,
    output reg  [2:0]              phase,
    output reg  [1:0]              stage
);

localparam [2:0] LASTPH = 3'd7;
localparam [4:0] PSH    = 5'd0;

localparam [1:0] ST_IDLE = 2'd0;
localparam [1:0] ST_MAC  = 2'd1;

// ---------------------------------------------------------------------------
// one multiply beat per lane: the lane muxes are the only cost of the eight
// lanes, the multiplier itself is instantiated once
// ---------------------------------------------------------------------------
wire run     = (stage == ST_MAC);
wire publish = (run && (phase == LASTPH));

reg first_lat;

reg signed [AW-1:0] lane_a;
reg signed [BW-1:0] lane_b;

always @(*) begin
    case ({run, phase})
        4'b1000: begin lane_a = $signed(av[0*AW +: AW]); lane_b = $signed(bv[0*BW +: BW]); end
        4'b1001: begin lane_a = $signed(av[1*AW +: AW]); lane_b = $signed(bv[1*BW +: BW]); end
        4'b1010: begin lane_a = $signed(av[2*AW +: AW]); lane_b = $signed(bv[2*BW +: BW]); end
        4'b1011: begin lane_a = $signed(av[3*AW +: AW]); lane_b = $signed(bv[3*BW +: BW]); end
        4'b1100: begin lane_a = $signed(av[4*AW +: AW]); lane_b = $signed(bv[4*BW +: BW]); end
        4'b1101: begin lane_a = $signed(av[5*AW +: AW]); lane_b = $signed(bv[5*BW +: BW]); end
        4'b1110: begin lane_a = $signed(av[6*AW +: AW]); lane_b = $signed(bv[6*BW +: BW]); end
        4'b1111: begin lane_a = $signed(av[7*AW +: AW]); lane_b = $signed(bv[7*BW +: BW]); end
        default: begin lane_a = {AW{1'b0}};            lane_b = {BW{1'b0}};            end
    endcase
end

wire signed [AW+BW-1:0] pr    = lane_a * lane_b;
wire signed [AW+BW-1:0] presc = pr >>> PSH;

// ---------------------------------------------------------------------------
// saturating accumulator step, shared by all eight lanes.  The datapath is
// deliberately self-idling: with lane_* forced to zero outside ST_MAC the sum
// repeats acc, so no per-bit enable mux is needed anywhere in the wide path.
// ---------------------------------------------------------------------------
wire                clr  = (run && first_lat && (phase == 3'd0));
wire signed [ACCW-1:0]       base  = clr ? {ACCW{1'b0}} : acc;
wire signed [ACCW+GUARD-1:0] bext  = base;
wire signed [ACCW+GUARD-1:0] aext  = presc;
wire signed [ACCW+GUARD-1:0] snext = bext + aext;

wire [GUARD-1:0] grow = snext[ACCW+GUARD-1:ACCW];
wire                   ovf     = (grow != {GUARD{snext[ACCW-1]}});
wire                   cl_neg  = (ovf &&  snext[ACCW+GUARD-1]);
wire                   cl_pos  = (ovf && !snext[ACCW+GUARD-1]);
wire signed [ACCW-1:0] clamped = ovf
    ? {snext[ACCW+GUARD-1], {(ACCW-1){~snext[ACCW+GUARD-1]}}}
    : snext[ACCW-1:0];

assign in_ready = (stage == ST_IDLE);
assign busy     = (stage != ST_IDLE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc        <= {ACCW{1'b0}};
        prod       <= {(AW+BW){1'b0}};
        headroom   <= {GUARD{1'b0}};
        sat_pos    <= 1'b0;
        sat_neg    <= 1'b0;
        ovf_sticky <= 1'b0;
        pub_first  <= 1'b0;
        valid      <= 1'b0;
        vec_count  <= 8'h00;
        sat_count  <= 8'h00;
        phase      <= 3'd0;
        stage      <= ST_IDLE;
        first_lat  <= 1'b0;
    end else if (clk_en) begin
        acc      <= clamped;
        prod     <= pr;
        headroom <= grow;
        sat_pos  <= cl_pos;
        sat_neg  <= cl_neg;
        valid    <= publish;
        phase    <= (run ? (phase + 3'd1) : 3'd0);
        stage    <= (stage == ST_IDLE && in_valid) ? ST_MAC :
                    (publish            ? ST_IDLE          : stage);

        sat_count  <= sat_count + {7'd0, (run && ovf)};
        vec_count  <= vec_count + {7'd0, publish};
        ovf_sticky <= (ovf_sticky | (run && ovf));

        // phase reports the lane index the publishing beat consumed, so the
        // observation taken on the valid pulse sees LASTPH and then re-zeroes.
        phase    <= (stage == ST_IDLE) ? 3'd0 : (publish ? LASTPH : (phase + 3'd1));

        if (stage == ST_IDLE && in_valid) begin
            first_lat <= first;
            pub_first <= first;
        end
    end
end

endmodule
