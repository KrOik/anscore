// ============================================================================
// pi_loop.sv -- DSP-08 shared proportional+integral loop filter.
//
//   On each clk edge with upd=1 (err registered one edge later):
//       prop  <= err >>> kp_rsh            (arithmetic shift)
//       integ <= sat_pm2p28(integ + (err >>> ki_rsh))
//   corr (combinational) = prop + integ.
//
//   err is signed Q31 (1.0 ~ 2^31); right shifts attenuate, so larger
//   *_rsh values mean weaker gain.  kp_rsh/ki_rsh legality (ki_rsh > kp_rsh)
//   is enforced by the parent module's configuration checker.
//
//   integ clamps at [-2^28, 2^28-1] so prop + integ can never overflow
//   signed32 for |err| <= 2^30 (prop <= 2^30, sum <= 2^30 + 2^28 - 1 <
//   2^31 - 1).  Integrator windup beyond the clamp is possible under a
//   persistent out-of-range error; that is a documented limitation of the
//   parent spec, recovery is bounded by the clamp size.
//
//   clear=1 zeroes both state registers (takes priority over upd).
//   Single clk, synchronous active-low rst_n.
// ============================================================================
module pi_loop (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               upd,
    input  wire               clear,
    input  wire signed [31:0] err,
    input  wire        [4:0]  kp_rsh,
    input  wire        [4:0]  ki_rsh,
    output reg  signed [31:0] prop,
    output reg  signed [31:0] integ,
    output wire signed [31:0] corr
);

wire signed [31:0] istep = err >>> ki_rsh;
wire signed [32:0] isum  = {integ[31], integ} + {istep[31], istep};

assign corr = prop + integ;

always @(posedge clk) begin
    if (!rst_n) begin
        prop  <= 32'sd0;
        integ <= 32'sd0;
    end else if (clear) begin
        prop  <= 32'sd0;
        integ <= 32'sd0;
    end else if (upd) begin
        prop  <= err >>> kp_rsh;
        integ <= (isum > 33'sd268435455)  ? 32'sd268435455  :   // +2^28-1
                 (isum < -33'sd268435456) ? -32'sd268435456 :   // -2^28
                                           isum[31:0];
    end
end

endmodule
