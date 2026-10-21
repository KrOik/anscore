`timescale 1ns/1ps
module tb_invalid;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0;
 wire ready,valid,sof,eol,protocol_error,error_pulse;
 wire [1:0] error_code;
 wire [7:0] data;
 img_csi2_raw_pack #(.RAW_BITS(8)) dut(
  .clk(clk),.rst_n(rst_n),.clk_en(1'b1),.s_data(8'hff),.s_valid(1'b1),
  .s_ready(ready),.s_sof(1'b1),.s_eol(1'b1),.m_data(data),.m_valid(valid),
  .m_ready(1'b1),.m_sof(sof),.m_eol(eol),.protocol_error(protocol_error),
  .error_pulse(error_pulse),.error_code(error_code));
 initial begin
  #2;rst_n=1;@(posedge clk);#1;
  if(ready || valid || !protocol_error || !error_pulse || error_code!=3) $fatal(1,"unsupported parameter");
  @(posedge clk);#1;if(error_pulse) $fatal(1,"repeat error");
  $display("PACK invalid parameter PASS");$finish;
 end
endmodule
