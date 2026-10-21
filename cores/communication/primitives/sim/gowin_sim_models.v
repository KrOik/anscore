// Minimal simulation models for Gowin primitives instantiated by the RTL.
// Synthesis uses the real library cells; these stubs are for iverilog only.
module BUFG(O, I);
output O;
input  I;
assign O = I;
endmodule

// rPLL: behavioral model for the comm_20k configuration only —
// FCLKIN=27, IDIV_SEL=1, FBDIV_SEL=0, ODIV_SEL=64 -> CLKOUT = CLKIN/2.
// LOCK asserted after 8 input cycles to emulate PLL lock delay.
module rPLL (CLKOUT, CLKOUTP, CLKOUTD, CLKOUTD3, LOCK, CLKIN, CLKFB,
             FBDSEL, IDSEL, ODSEL, DUTYDA, PSDA, FDLY, RESET, RESET_P);
parameter FCLKIN = "27";
parameter IDIV_SEL = 1, FBDIV_SEL = 0, ODIV_SEL = 64;
input  CLKIN, CLKFB, RESET, RESET_P;
input  [5:0] FBDSEL, IDSEL, ODSEL;
input  [3:0] DUTYDA, PSDA, FDLY;
output reg CLKOUT = 1'b0;
output CLKOUTP, CLKOUTD, CLKOUTD3;
output reg LOCK = 1'b0;
assign CLKOUTP = 1'b0; assign CLKOUTD = 1'b0; assign CLKOUTD3 = 1'b0;
reg [3:0] lcnt = 4'd0;
always @(posedge CLKIN) begin
    CLKOUT <= ~CLKOUT;                       // /2 for this configuration
    if (lcnt != 4'hF) lcnt <= lcnt + 4'd1;
    LOCK <= (lcnt >= 4'd8);
end
endmodule
