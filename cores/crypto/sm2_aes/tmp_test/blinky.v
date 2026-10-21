module blinky(input clk, output reg [3:0] cnt);
  always @(posedge clk) cnt <= cnt + 1;
endmodule
