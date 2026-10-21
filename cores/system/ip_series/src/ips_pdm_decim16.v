`timescale 1ns / 1ps
// ips_pdm_decim16 : 1-bit PDM to 16-bit PCM decimator for the ip_series_20k line.
//
// Order-3 CIC: three cascaded integrators running on every PDM sample, followed
// by three comb differences taken once per R_RATE samples (the decimator).  The
// integrator and comb section is pure modular add/sub -- no multiply, no DSP --
// and the accumulator width is derived from the output geometry so the section
// wraps exactly like the two's-complement identity the decimator relies on.
//
// Written contract (models/ips_pdm_decim16.py implements the same rules):
//   * pdm_tick advances the filter by one oversample; the phase counter runs
//     0..R_RATE-1 and the comb stage fires on the last phase.
//   * pdm_in is mapped bipolar: 1 -> +1, 0 -> -1, so a stuck input is the
//     full-scale case rather than a silent one.
//   * i1 += x, i2 += i1, i3 += i2 are evaluated for the current sample; the comb
//     taps are then c1 = i3 - cd1, c2 = c1 - cd2, c3 = c2 - cd3 with cd1 <= i3,
//     cd2 <= c1, cd3 <= c2.
//   * the scaled word is wide = c3 <<< GAIN_SH, held in the accumulator width.
//     pcm takes the low OUT_W bits, clamped to signed full scale, and pcm_hr
//     reports the HR_BITS slice above the output field so an integrator can see
//     how far past full scale the decimated frame was.
//   * a clamped frame sets sat_pos / sat_neg for that frame, sets sat_sticky for
//     good and bumps sat_count, which saturates at SAT_MAX; out_count counts the
//     published frames and wraps.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_pdm_decim16 #(
    parameter R_RATE = 16,
    parameter OUT_W = 16,
    parameter GAIN_SH = 4,
    parameter SAT_MAX = 5
)(
    input  wire                    clk,
    input  wire                    clk_en,
    input  wire                    rst_n,

    input  wire                    pdm_tick,
    input  wire                    pdm_in,

    output reg signed [OUT_W-1:0]  pcm,
    output reg [3:0]               pcm_hr,
    output reg                     pcm_valid,
    output reg                     sat_pos,
    output reg                     sat_neg,
    output reg                     sat_sticky,
    output reg [7:0]               sat_count,
    output reg [7:0]               out_count,
    output reg [4:0]               phase
);

localparam integer ACC_W = OUT_W + GAIN_SH;
localparam integer R_LAST = R_RATE - 1;

localparam signed [ACC_W-1:0] SIGNED_ONE = 1;
localparam signed [ACC_W-1:0] SIGNED_NEG = -1;

localparam signed [OUT_W-1:0] VAL_MAX = {1'b0, {(OUT_W - 1){1'b1}}};
localparam signed [OUT_W-1:0] VAL_MIN = {1'b1, {(OUT_W - 1){1'b0}}};

reg signed [ACC_W-1:0] integ1;
reg signed [ACC_W-1:0] integ2;
reg signed [ACC_W-1:0] integ3;
reg signed [ACC_W-1:0] comb1;
reg signed [ACC_W-1:0] comb2;
reg signed [ACC_W-1:0] comb3;

wire signed [ACC_W-1:0] xi    = pdm_in ? SIGNED_ONE : SIGNED_NEG;
wire signed [ACC_W-1:0] i1_n  = integ1 + xi;
wire signed [ACC_W-1:0] i2_n  = integ2 + i1_n;
wire signed [ACC_W-1:0] i3_n  = integ3 + i2_n;

wire signed [ACC_W-1:0] c1    = i3_n - comb1;
wire signed [ACC_W-1:0] c2    = c1 - comb2;
wire signed [ACC_W-1:0] c3    = c2 - comb3;
wire signed [ACC_W-1:0] wide  = c3 <<< GAIN_SH;

wire signed [OUT_W-1:0] clip_lo = wide[OUT_W-1:0];
wire signed [ACC_W-1:0] sext = {{GAIN_SH{clip_lo[OUT_W-1]}}, clip_lo};
wire overflow = (wide != sext);
wire over_pos = overflow && !wide[ACC_W-1];
wire over_neg = overflow &&  wide[ACC_W-1];
wire signed [OUT_W-1:0] clamped = overflow ? (over_neg ? VAL_MIN : VAL_MAX) : clip_lo;
wire [3:0] hr_slice = wide[OUT_W +: 4];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pcm        <= {OUT_W{1'b0}};
        pcm_hr     <= 4'h0;
        pcm_valid  <= 1'b0;
        sat_pos    <= 1'b0;
        sat_neg    <= 1'b0;
        sat_sticky <= 1'b0;
        sat_count  <= 8'h00;
        out_count  <= 8'h00;
        phase      <= 5'd0;
        integ1     <= {ACC_W{1'b0}};
        integ2     <= {ACC_W{1'b0}};
        integ3     <= {ACC_W{1'b0}};
        comb1      <= {ACC_W{1'b0}};
        comb2      <= {ACC_W{1'b0}};
        comb3      <= {ACC_W{1'b0}};
    end else if (clk_en) begin
        if (pdm_tick) begin
            integ1 <= i1_n;
            integ2 <= i2_n;
            integ3 <= i3_n;
            if (phase == R_LAST) begin
                phase     <= 5'd0;
                pcm       <= clamped;
                pcm_hr    <= hr_slice;
                pcm_valid <= 1'b1;
                comb1     <= i3_n;
                comb2     <= c1;
                comb3     <= c2;
                if (out_count != 8'hFF) begin
                    out_count <= out_count + 8'h01;
                end
                if (overflow) begin
                    sat_sticky <= 1'b1;
                    sat_pos    <= over_pos;
                    sat_neg    <= over_neg;
                    if (sat_count < SAT_MAX) begin
                        sat_count <= sat_count + 8'h01;
                    end
                end else begin
                    sat_pos <= 1'b0;
                    sat_neg <= 1'b0;
                end
            end else begin
                phase     <= phase + 5'd1;
                pcm_valid <= 1'b0;
            end
        end
    end
end

endmodule
