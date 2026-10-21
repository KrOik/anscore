// Behavioural stand-in for the Gowin rPLL wrapper, simulation only.
// CLKOUT is not used by eth_rate_harness; CLKOUTD is the 1 MHz MDC clock.
module PLL_6M (clkout, clkoutd, clkin);
output clkout;
output clkoutd;
input  clkin;

reg [5:0] div = 0;
always @(posedge clkin) div <= div + 1'b1;
assign clkout  = div[1];
assign clkoutd = div[4];
endmodule
