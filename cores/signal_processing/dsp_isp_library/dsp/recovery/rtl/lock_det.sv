// ============================================================================
// lock_det.sv -- DSP-08 shared lock detector.
//
//   On each clk edge with en=1, a leaky magnitude integrator is updated:
//       lavg <= lavg + (({mag,6'b0} - lavg) >>> 6)     (arithmetic shift)
//   lavg is an unsigned Q18.6 estimate of mag (time constant ~64 updates).
//   The comparison value is lavg >>> 6 (integer code units).
//
//   cnt counts consecutive updates with (lavg >>> 6) < thr, saturating at
//   255; any update at/above thr resets cnt to 0 (strict, no hysteresis).
//   lock = (cnt >= nreq).
//
//   lavg resets to its maximum (24'hFFFFFF) on reset and clear so lock can
//   only be earned after the estimate has decayed below thr and stayed
//   there for nreq consecutive updates (~2-3 estimator time constants).
//
//   clear=1 re-arms lavg to maximum, zeroes cnt and lock (priority > en).
//   Single clk, synchronous active-low rst_n.
// ============================================================================
module lock_det (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    input  wire        clear,
    input  wire [17:0] mag,
    input  wire [15:0] thr,
    input  wire [7:0]  nreq,
    output reg         lock,
    output wire [17:0] level    // lavg >>> 6, current smoothed |err|
);

reg  [23:0] lavg;
reg  [7:0]  cnt;

wire signed [24:0] diff = {1'b0, mag, 6'b0} - {1'b0, lavg};   // signed
wire signed [24:0] step = diff >>> 6;
wire        [17:0] lvl  = lavg[23:6];

assign level = lvl;

always @(posedge clk) begin
    if (!rst_n) begin
        lavg <= 24'hFFFFFF;
        cnt  <= 8'd0;
        lock <= 1'b0;
    end else if (clear) begin
        lavg <= 24'hFFFFFF;
        cnt  <= 8'd0;
        lock <= 1'b0;
    end else if (en) begin
        lavg <= lavg + step[23:0];
        if (lvl < {2'b0, thr}) begin
            cnt  <= (cnt == 8'd255) ? cnt : cnt + 8'd1;
            lock <= ({1'b0, cnt} + 9'd1 >= {1'b0, nreq});
        end else begin
            cnt  <= 8'd0;
            lock <= 1'b0;
        end
    end
end

endmodule
