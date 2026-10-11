`timescale 1ns / 1ps
// ips_quant_int8_sym : symmetric int8 quantise / dequantise pair sharing one
// multiplier, with a programmable per-channel scale and clipping.
//
// Contract, mirrored independently by models/ips_quant_int8_sym.py.  One beat
// consumes one value; dir selects the direction and ch the channel scale:
//   a    = dir ? sign_extend(x[7:0]) : sign_extend(x)   int8 operand or activation
//   mb   = dir ? MD[ch] : MQ[ch]                        signed scale
//   sh   = SH[ch]                                       per-channel fine shift
//   P    = a * mb                                       one signed product
//   V    = (|P| + RB) >> (base + sh)                    round-half-away, base is
//                                                       9 when quantising (divide
//                                                       by the scale) and 1 when
//                                                       dequantising (multiply)
//   RB   = 1 << (base + sh - 1)                         the round bit itself
//   mv   = min(V, rail), rail = dir ? 32767 : 127       symmetric clipping
//   yq   = +-mv truncated to YB bits (quantise beats)
//   ydq  = +-mv truncated to 16 bits (dequantise beats)
//   clipped_last marks a beat whose magnitude hit a rail, sat_q / sat_d are the
//   sticky per-direction clip flags, udf_sticky marks a non-zero operand that
//   rounded to zero (the quantisation dead zone) and clip_count counts clipped
//   beats (8-bit, wraps).  y_neg is the sign of the published magnitude and y_vld
//   is the one-cycle echo of in_valid on the next enabled clock; the published
//   payload simply holds while in_valid is low.
// A symmetric scheme has an implicit zero point of 0, so no offset term appears.
// cfg_id is the geometry readback {XB, MB, YB, tag}.
// Every register is gated by clk_en; rst_n is the active-low asynchronous reset
// (docs/IP_CORE_SOP.md trap T2).
module ips_quant_int8_sym #(
    parameter XB = 12,
    parameter MB = 12,
    parameter YB = 8
)(
    input  wire                 clk,
    input  wire                 clk_en,
    input  wire                 rst_n,
    input  wire                 in_valid,
    input  wire                 dir,
    input  wire [1:0]           ch,
    input  wire signed [XB-1:0] x,

    output reg  signed [YB-1:0] yq,
    output reg  signed [15:0]   ydq,
    output reg  [15:0]          ymag,
    output reg                  y_neg,
    output reg                  y_vld,
    output reg                  clipped_last,
    output reg                  sat_q,
    output reg                  sat_d,
    output reg                  udf_sticky,
    output reg  [7:0]           clip_count,
    output wire [31:0]          cfg_id
);

// Per-channel scales: MQ is the reciprocal scale applied when quantising, MD the
// scale applied when dequantising.  models/ips_quant_int8_sym.py restates both.
// MQ0 rounds by 1/8, MQ1/MQ2/MQ3 are finer (MQ2 is coarse enough to leave a dead
// zone around zero), MD0 is wide enough to saturate the int16 rail.
wire signed [MB-1:0] MQ0 = 12'h040;
wire signed [MB-1:0] MQ1 = 12'h009;
wire signed [MB-1:0] MQ2 = 12'h006;
wire signed [MB-1:0] MQ3 = 12'h020;
wire signed [MB-1:0] MD0 = 12'h7ff;
wire signed [MB-1:0] MD1 = 12'h040;
wire signed [MB-1:0] MD2 = 12'h200;
wire signed [MB-1:0] MD3 = 12'h00a;

localparam integer BQ = 9;
localparam integer BD = 1;
localparam [7:0] ID_XB = XB;
localparam [7:0] ID_MB = MB;
localparam [7:0] ID_YB = YB;

wire signed [MB-1:0] mqt;
wire signed [MB-1:0] mdt;
wire signed [MB-1:0] mbt;
wire [1:0]           sh;
wire signed [15:0]   ax;
wire signed [15:0]   a8;
wire signed [15:0]   a;
wire signed [15:0]   mb;
wire signed [23:0]   prod;
wire [23:0]          mag;
wire [13:0]          rbq;
wire [3:0]           rbd;
wire [13:0]          rb;
wire [22:0]          w;
wire [13:0]          uq;
wire [21:0]          ud;
wire [21:0]          u;
wire [21:0]          v1;
wire [21:0]          v;
wire [21:0]          rail;
wire                 clipped;
wire [15:0]          mv;
wire                 neg;
wire                 udf;
wire signed [16:0]   ys;

assign mqt  = (ch == 2'd0) ? MQ0 : ((ch == 2'd1) ? MQ1 : ((ch == 2'd2) ? MQ2 : MQ3));
assign mdt  = (ch == 2'd0) ? MD0 : ((ch == 2'd1) ? MD1 : ((ch == 2'd2) ? MD2 : MD3));
assign mbt  = dir ? mdt : mqt;
assign sh   = (ch == 2'd0) ? 2'd0 : ((ch == 2'd1) ? 2'd1 : ((ch == 2'd2) ? 2'd2 : 2'd3));
assign ax   = {{(16 - XB){x[XB-1]}}, x};
assign a8   = {{8{x[7]}}, x[7:0]};
assign a    = dir ? a8 : ax;
assign mb   = {{(16 - MB){mbt[MB-1]}}, mbt};
assign prod = a * mb;
assign mag  = prod[23] ? (~prod + 24'd1) : prod;
assign rbq  = (sh == 2'd0) ? 14'h0100 : ((sh == 2'd1) ? 14'h0200 : ((sh == 2'd2) ? 14'h0400 : 14'h0800));
assign rbd  = (sh == 2'd0) ? 4'd1 : ((sh == 2'd1) ? 4'd2 : ((sh == 2'd2) ? 4'd4 : 4'd8));
assign rb   = dir ? {10'd0, rbd} : rbq;
assign w    = mag[22:0] + rb;
assign uq   = w[22:BQ];
assign ud   = w[22:BD];
assign u    = dir ? ud : {8'd0, uq};
assign v1   = sh[0] ? (u >> 1) : u;
assign v    = sh[1] ? (v1 >> 2) : v1;
assign rail = dir ? 22'd32767 : 22'd127;
assign clipped = (v > rail);
assign mv   = clipped ? rail[15:0] : v[15:0];
assign neg  = prod[23] && (mv != 16'd0);
assign udf  = (mv == 16'd0) && (a != 16'sd0);
assign ys   = neg ? -$signed({1'b0, mv}) : $signed({1'b0, mv});
assign cfg_id = {ID_XB, ID_MB, ID_YB, 8'h9a};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        yq           <= {YB{1'b0}};
        ydq          <= 16'h0000;
        ymag         <= 16'h0000;
        y_neg        <= 1'b0;
        y_vld        <= 1'b0;
        clipped_last <= 1'b0;
        sat_q        <= 1'b0;
        sat_d        <= 1'b0;
        udf_sticky   <= 1'b0;
        clip_count   <= 8'h00;
    end else if (clk_en) begin
        y_vld <= in_valid;
        if (in_valid) begin
            yq           <= ys[YB-1:0];
            ydq          <= ys[15:0];
            ymag         <= mv;
            y_neg        <= neg;
            clipped_last <= clipped;
            if (udf) begin
                udf_sticky <= 1'b1;
            end
            if (clipped) begin
                clip_count <= clip_count + 8'h01;
                if (dir) begin
                    sat_d <= 1'b1;
                end else begin
                    sat_q <= 1'b1;
                end
            end
        end
    end
end

endmodule
