`timescale 1ns / 1ps
// ips_int8_mac_array : signed int8 multiply-accumulate array with per-lane
// saturating accumulators, per-row bias load, requantising arithmetic shift and
// a saturating-beat counter.
//
// Contract, mirrored independently by models/ips_int8_mac_array.py:
//   Lane 0 occupies the most significant slice of every packed vector.
//   Per lane g, on each in_valid beat:
//     p[g]    = x[g] * w[g]                 signed 8x8 product, 16 bits
//     term[g] = (p[g] + 1) >>> 2            round then arithmetic shift by 2
//     base[g] = load ? bias[g] : acc[g]
//     tot[g]  = sign_extend(base[g]) + sign_extend(term[g])   in ACCW+GUARD bits
//     sat[g]  = tot[g] does not fit the signed ACCW range
//     acc[g] <= clamp(tot[g])
//     headroom[g] <= tot[g][ACCW+GUARD-1 -: GUARD]
//   clip_count counts beats in which at least one lane saturated (8-bit, wraps).
//   geom_id is the configuration readback word {LANES, ACCW, GUARD, 8'hB7} so an
//   integrator can confirm the geometry the core was synthesized with.
//   Every register is gated by clk_en; rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_int8_mac_array #(
    parameter LANES = 4,
    parameter ACCW = 32,
    parameter GUARD = 2
)(
    input  wire                    clk,
    input  wire                    clk_en,
    input  wire                    rst_n,

    input  wire                    in_valid,
    input  wire                    load,
    input  wire  [LANES*8-1:0]     x,
    input  wire  [LANES*8-1:0]     w,
    input  wire  [LANES*ACCW-1:0]  bias,

    output reg   [LANES*ACCW-1:0]  acc,
    output reg   [LANES*GUARD-1:0] headroom,
    output reg   [LANES-1:0]       sat,
    output reg   [7:0]             clip_count,
    output wire  [31:0]            geom_id
);

genvar g;

localparam signed [ACCW-1:0] ACC_MAX = {1'b0, {(ACCW - 1){1'b1}}};
localparam signed [ACCW-1:0] ACC_MIN = {1'b1, {(ACCW - 1){1'b0}}};

localparam [7:0] ID_LANES = LANES;
localparam [7:0] ID_ACCW  = ACCW;
localparam [7:0] ID_GUARD = GUARD;

wire [LANES*ACCW-1:0]  next_acc;
wire [LANES*GUARD-1:0] next_hr;
wire [LANES-1:0]       next_sat;
wire                   any_ovf;

// MSB-first lane geometry: the lane processed by iteration g is (g-1) and it
// lives in slice (LANES-g) of every packed vector.  The loop counts down so that
// every lane offset stays inside a part-select.
generate
for (g = LANES; g > 0; g = g - 1) begin : LANE
    wire signed [7:0]  ax = x[(LANES - g) * 8 +: 8];
    wire signed [7:0]  aw = w[(LANES - g) * 8 +: 8];
    wire signed [15:0] mp = ax * aw;
    wire signed [16:0] me = {mp[15], mp};
    wire signed [16:0] mr = (me + 17'sd1);
    wire signed [16:0] term = (mr >>> 3'd2);

    wire signed [ACCW-1:0] cur  = acc[(LANES - g) * ACCW +: ACCW];
    wire signed [ACCW-1:0] bia  = bias[(LANES - g) * ACCW +: ACCW];
    wire signed [ACCW-1:0] base = load ? bia : cur;

    wire signed [ACCW+GUARD-1:0] sb = {{GUARD{base[ACCW-1]}}, base};
    wire signed [ACCW+GUARD-1:0] st = {{(ACCW + GUARD - 17){term[16]}}, term};
    wire signed [ACCW+GUARD-1:0] tot = (sb + st);

    wire signed [ACCW+GUARD-1:0] sext = {{GUARD{tot[ACCW-1]}}, tot[ACCW-1:0]};
    wire                ovf  = (tot !== sext);
    wire                pol  = tot[ACCW+GUARD-1];
    wire signed [ACCW-1:0] clamped = ovf ? (pol ? ACC_MIN : ACC_MAX) : tot[ACCW-1:0];

    assign next_acc[(LANES - g) * ACCW +: ACCW] = clamped;
    assign next_hr[(LANES - g) * GUARD +: GUARD] = tot[ACCW + GUARD - 1 -: GUARD];
    assign next_sat[LANES - g] = ovf;
end
endgenerate

assign any_ovf = |next_sat;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        acc        <= {(LANES * ACCW){1'b0}};
        headroom   <= {(LANES * GUARD){1'b0}};
        sat        <= {(LANES){1'b0}};
        clip_count <= 8'h00;
    end else if (clk_en) begin
        if (in_valid) begin
            acc      <= next_acc;
            headroom <= next_hr;
            sat      <= next_sat;
            if (any_ovf) begin
                clip_count <= clip_count + 8'h01;
            end
        end
    end
end

assign geom_id = {ID_LANES, ID_ACCW, ID_GUARD, 8'hB7};

endmodule
