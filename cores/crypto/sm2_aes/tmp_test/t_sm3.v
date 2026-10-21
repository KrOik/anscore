module t_sm3(input clk, input rst_n, input din, output [5:0] led);
  reg [63:0] sh;
  always @(posedge clk) sh <= {sh[62:0], din};
  wire [255:0] res; wire rv, rdy;
  sm3_top u(.clk(clk), .rst_n(rst_n),
    .msg_inpt_d_i(sh), .msg_inpt_vld_byte_i(sh[7:0]),
    .msg_inpt_vld_i(sh[0]), .msg_inpt_lst_i(sh[1]), .msg_inpt_rdy_o(rdy),
    .cmprss_otpt_res_o(res), .cmprss_otpt_vld_o(rv));
  assign led = res[5:0] ^ res[255:250] ^ {4'b0, rv, rdy};
endmodule
