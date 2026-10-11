`timescale 1ns / 1ps
// ips_conv1d_depthwise : depthwise separable 1-D convolution over a small tap
// window, with per-channel weights and per-channel output shift held in reg-array
// tables, boundary padding and a saturating quantised output.
//
// Contract, mirrored independently by models/ips_conv1d_depthwise.py:
//   One beat consumes one tap of one output sample.  Tap TAPS-1 is the most
//   significant byte of a weight row.  Per beat with in_valid:
//     xt    = pad_en ? padv : xv                      boundary pad or real sample
//     wt    = wrom[ch] field (TAPS-1-tap)             signed int8 weight
//     acc_n = (tap == 0) ? xt*wt : acc + xt*wt        18-bit signed tap sum
//     acc   <= acc_n
//   On the closing beat (tap == tcfg-1) the core requantises and publishes:
//     y_raw = (acc_n + 8) >>> srom[ch]                round then per-channel shift
//     y     <= clamp(y_raw) to the signed YB range
//     sat_last <= the clamp direction, out_valid <= 1 for that beat only
//     clip_count counts published results that saturated (8-bit, wraps)
//   Off the closing beat out_valid drops and y / sat_last keep their old value.
//   tcfg is the programmable tap count of the current output (1..TAPS).
//   cfg_id is the geometry readback word {TAPS, YB}.
//   Every register is gated by clk_en; rst_n is the active-low asynchronous
//   reset (docs/IP_CORE_SOP.md trap T2).
module ips_conv1d_depthwise #(
    parameter TAPS = 4,
    parameter YB = 8
)(
    input  wire                     clk,
    input  wire                     clk_en,
    input  wire                     rst_n,

    input  wire                     in_valid,
    input  wire  [1:0]              ch,
    input  wire  [2:0]              tap,
    input  wire  [2:0]              tcfg,
    input  wire  signed [7:0]       xv,
    input  wire                     pad_en,
    input  wire  signed [7:0]       padv,

    output reg   signed [YB-1:0]    y,
    output reg                      out_valid,
    output reg                      sat_last,
    output reg   [7:0]              clip_count,
    output reg   signed [17:0]      acc,
    output wire  [15:0]             cfg_id
);

reg signed [(TAPS*8)-1:0] wrom [0:3];
reg [2:0]                 srom [0:3];

// Depthwise 3x3 style kernels flattened to 1-D, one row per channel.  The values
// are design constants and models/ips_conv1d_depthwise.py restates them.
initial begin
    wrom[0] = {8'h02, 8'hfe, 8'h05, 8'h7f};
    wrom[1] = {8'hfb, 8'h03, 8'h03, 8'h80};
    wrom[2] = {8'h7f, 8'h81, 8'h04, 8'h02};
    wrom[3] = {8'h04, 8'hfc, 8'h7f, 8'h01};
    srom[0] = 3'd4;
    srom[1] = 3'd2;
    srom[2] = 3'd6;
    srom[3] = 3'd0;
end

localparam signed [YB-1:0] Y_MAX = {1'b0, {(YB - 1){1'b1}}};
localparam signed [YB-1:0] Y_MIN = {1'b1, {(YB - 1){1'b0}}};

localparam [7:0] ID_TAPS = TAPS;
localparam [7:0] ID_YB   = YB;

wire signed [7:0]    xt;
wire signed [7:0]    wt;
wire signed [17:0]   pext;
wire signed [17:0]   accn;
wire signed [17:0]   rnd;
wire [2:0]           sh;
wire signed [17:0]   sft;
wire signed [17:0]   sext;
wire                 ovf;
wire signed [YB-1:0] clamped;
wire                 closing;
wire signed [(TAPS*8)-1:0] wrow;

assign xt    = pad_en ? padv : xv;
assign wrow  = wrom[ch];
assign wt    = wrow[(TAPS - 1 - tap) * 8 +: 8];
assign sh    = srom[ch];
assign pext  = xt * wt;
assign accn  = (tap == 3'd0) ? pext : (acc + pext);
assign rnd   = accn + 18'h08;
assign sft   = (rnd >>> sh);
assign sext  = {{(18 - YB){sft[YB-1]}}, sft[YB-1:0]};
assign ovf   = (sft !== sext);
assign clamped = ovf ? (sft[17] ? Y_MIN : Y_MAX) : sft[YB-1:0];
assign closing = (tap == tcfg - 3'd1);
assign cfg_id  = {ID_TAPS, ID_YB};

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        y         <= {(YB){1'b0}};
        out_valid <= 1'b0;
        sat_last  <= 1'b0;
        clip_count <= 8'h00;
        acc       <= 18'h00000;
    end else if (clk_en) begin
        // The publish flag is a one-beat pulse: an idle beat must not keep it set,
        // otherwise a consumer with gaps in its input stream counts twice.
        out_valid <= 1'b0;
        if (in_valid) begin
            acc <= accn;
            if (closing) begin
                y         <= clamped;
                out_valid <= 1'b1;
                sat_last  <= ovf;
                if (ovf) begin
                    clip_count <= clip_count + 8'h01;
                end
            end
        end
    end
end

endmodule
