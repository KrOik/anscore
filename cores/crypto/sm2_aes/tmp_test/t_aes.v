module t_aes(input clk, input rst_n, input din, output [5:0] led);
  reg [255:0] ksh; reg [127:0] bsh;
  always @(posedge clk) begin ksh <= {ksh[254:0], din}; bsh <= {bsh[126:0], din}; end
  wire [127:0] res; wire rdy, rv;
  aes_core u(.clk(clk), .reset_n(rst_n), .encdec(bsh[0]), .init(bsh[1]), .next(bsh[2]),
    .ready(rdy), .key(ksh), .keylen(bsh[3]), .block(bsh), .result(res), .result_valid(rv));
  assign led = res[5:0] ^ {4'b0, rv, rdy};
endmodule
