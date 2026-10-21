module sm3_top(
    input clk, input rst_n,
    input [63:0] msg_inpt_d_i, input [7:0] msg_inpt_vld_byte_i,
    input msg_inpt_vld_i, input msg_inpt_lst_i,
    output msg_inpt_rdy_o,
    output [255:0] cmprss_otpt_res_o, output cmprss_otpt_vld_o);
  assign msg_inpt_rdy_o = 1'b0;
  assign cmprss_otpt_res_o = 256'd0;
  assign cmprss_otpt_vld_o = 1'b0;
endmodule
