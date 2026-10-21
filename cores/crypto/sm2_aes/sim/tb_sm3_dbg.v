`timescale 1ns/1ps
module tb_sm3_dbg;
reg clk=0, rst_n=0; always #5 clk=~clk;
reg [63:0] d; reg [7:0] vbyte; reg vld, lst;
wire rdy; wire [255:0] res; wire res_vld;
sm3_top dut(.clk(clk),.rst_n(rst_n),
  .msg_inpt_d_i(d),.msg_inpt_vld_byte_i(vbyte),
  .msg_inpt_vld_i(vld),.msg_inpt_lst_i(lst),
  .msg_inpt_rdy_o(rdy),
  .cmprss_otpt_res_o(res),.cmprss_otpt_vld_o(res_vld));
integer i;
initial begin
  d=0;vbyte=0;vld=0;lst=0;
  repeat(6) @(negedge clk); rst_n=1;
  for(i=0;i<300;i=i+1) begin
    @(negedge clk);
    if(i==4) begin d=64'h6162630000000000; vbyte=8'hE0; vld=1; lst=1; end
    else if(i==5) begin vld=0; lst=0; end
    if (res_vld) $display("RES t=%0d res=%h", $time, res);
  end
  $display("done rdy=%b pad_st=%h exp_st=%h", rdy, dut.U_sm3_pad_core.state, dut.U_sm3_expnd_core.state);
  $finish;
end
endmodule
