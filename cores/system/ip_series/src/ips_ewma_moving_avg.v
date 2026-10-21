`timescale 1ns / 1ps
// ips_ewma_moving_avg : alpha-weighted EWMA running in parallel with an NTAP-tap
// circular moving average whose mean is produced by a shift-subtract divider.
//
// Written contract, mirrored independently by models/ips_ewma_moving_avg.py:
//   Samples are signed Q7 (8 bit).  The exponential average is
//       d     = x(n) - ewma(n)
//       ewma  = ewma + (d >>> KSHIFT)          (arithmetic shift = floor divide)
//   so alpha = 1 / 2**KSHIFT.  frac carries d[3:0], the low bits of that beat's
//   difference, of which the bottom KSHIFT are the ones the shift discards.  When
//   d is non-zero and the shifted term is zero (0 < d < 2**KSHIFT) the average
//   cannot move: that limit cycle latches the sticky stall flag.
//   The moving average keeps NTAP = 8 samples in a circular register file written
//   at wptr.  msum is maintained exactly as msum + x(n) - mem[wptr], and cnt counts
//   stored samples saturating at NTAP, so while the window is still filling
//   (warm-up) the mean is divided by the samples actually present, not by NTAP.
//   The mean is |msum| / cnt from DIVSTEPS = 11 restoring shift/subtract steps on
//   magnitudes (it counts them), truncated toward zero, with `mean` and `rem`
//   taking the sign of msum and |rem| < cnt.  A full sample takes 1 + DIVSTEPS + 2
//   enabled beats: capture (EWMA plus window update plus divider load), the
//   division steps, collect, output pulse.  Stage 0 idle, 1 divide, 2 collect,
//   3 output; start is ignored while busy.  Every register is gated by clk_en and
//   rst_n is the active-low asynchronous reset (docs/IP_CORE_SOP.md trap T2).
module ips_ewma_moving_avg #(
    parameter NTAP   = 8,
    parameter KSHIFT = 3
)(
    input  wire              clk,
    input  wire              clk_en,
    input  wire              rst_n,

    input  wire              start,
    input  wire signed [7:0] x_in,

    output reg  signed [7:0]  ewma,
    output reg  signed [7:0]  mean,
    output reg  signed [10:0] msum,
    output reg  [3:0]         rem,
    output reg  [3:0]         frac,
    output reg                stall,
    output reg                valid,
    output wire               busy,
    output reg  [2:0]         stage,
    output reg  [3:0]         wptr,
    output reg  [3:0]         cnt,
    output reg  [4:0]         it
);

localparam integer DIVSTEPS = 11;
localparam [3:0]   NTAP4    = NTAP;

reg signed [7:0] mem [0:NTAP-1];

reg [10:0] dreg;
reg        dsign;
reg [3:0]  dsv;
reg [5:0]  drem;
reg [10:0] dq;

integer j;

assign busy = (stage != 3'd0);

wire signed [8:0]  dif      = x_in - ewma;
wire signed [8:0]  ew_step  = dif >>> KSHIFT;
wire signed [8:0]  ew_ext   = ewma;
wire signed [8:0]  ew_nxt   = ew_ext + ew_step;

wire signed [10:0] wold     = mem[wptr];
wire signed [10:0] sum_nxt  = msum + x_in - wold;
wire [10:0]        mag_nxt  = sum_nxt[10] ? (~sum_nxt + 11'sd1) : sum_nxt;
wire [3:0]         cnt_nxt  = (cnt < NTAP4) ? (cnt + 4'd1) : cnt;

wire [5:0] shifted = {drem, dreg[10]};
wire [5:0] dsv6    = {2'd0, dsv};
wire       fits    = (shifted >= dsv6);
wire [5:0] rem_nxt = fits ? (shifted - dsv6) : shifted;

wire signed [11:0] qmag = $signed({1'b0, dq});

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ewma  <= 8'sd0;
        mean  <= 8'sd0;
        msum  <= 11'sd0;
        rem   <= 4'sd0;
        frac  <= 4'd0;
        stall <= 1'b0;
        valid <= 1'b0;
        stage <= 3'd0;
        wptr  <= 4'd0;
        cnt   <= 4'd0;
        it    <= 5'd0;
        dreg  <= 11'd0;
        dsign <= 1'b0;
        dsv   <= 4'd0;
        drem  <= 6'd0;
        dq    <= 11'd0;
        for (j = 0; j < NTAP; j = j + 1) begin
            mem[j] <= 8'sd0;
        end
    end else if (clk_en) begin
        if (start && (stage == 3'd0)) begin
            ewma  <= ew_nxt[7:0];
            frac  <= dif[3:0];
            if ((dif != 9'sd0) && (ew_step == 9'sd0)) begin
                stall <= 1'b1;
            end
            mem[wptr] <= x_in;
            msum  <= sum_nxt;
            cnt   <= cnt_nxt;
            wptr  <= (wptr == (NTAP4 - 4'd1)) ? 4'd0 : (wptr + 4'd1);
            dreg  <= mag_nxt;
            dsign <= sum_nxt[10];
            dsv   <= cnt_nxt;
            drem  <= 6'd0;
            dq    <= 11'd0;
            it    <= 5'd0;
            valid <= 1'b0;
            stage <= 3'd1;
        end else begin
            valid <= 1'b0;
            case (stage)
                3'd1: begin
                    drem <= rem_nxt;
                    dreg <= {dreg[9:0], 1'b0};
                    dq   <= {dq[9:0], fits};
                    it   <= it + 5'd1;
                    if (it == (DIVSTEPS - 5'd1)) begin
                        stage <= 3'd2;
                    end
                end
                3'd2: begin
                    mean <= dsign ? (~qmag[7:0] + 8'd1) : qmag[7:0];
                    rem  <= dsign ? (~drem[3:0] + 4'd1) : drem[3:0];
                    stage <= 3'd3;
                end
                3'd3: begin
                    valid <= 1'b1;
                    stage <= 3'd0;
                end
                default: begin
                    stage <= 3'd0;
                end
            endcase
        end
    end
end

endmodule
