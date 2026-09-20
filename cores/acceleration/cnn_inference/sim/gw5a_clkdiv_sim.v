// Minimal functional model of Gowin CLKDIV (DIV_MODE "2") for iverilog.
module CLKDIV (HCLKIN, RESETN, CALIB, CLKOUT);
input  HCLKIN;
input  RESETN;
input  CALIB;
output CLKOUT;
parameter DIV_MODE = "2";
reg clk_q = 1'b0;
assign CLKOUT = clk_q;
always @(posedge HCLKIN) begin
    if (!RESETN) clk_q <= 1'b0;
    else         clk_q <= ~clk_q;
end
endmodule
