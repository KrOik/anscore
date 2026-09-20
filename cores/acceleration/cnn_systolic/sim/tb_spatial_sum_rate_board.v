`timescale 1ns/1ps
module tb_spatial_sum_rate_board;
reg clk=0;
always #5 clk=~clk;
wire tx,debug_tx;
spatial_sum_rate_board #(.UART_BAUD(2700000)) dut(clk,tx,debug_tx);
reg [7:0] expected[0:53];
integer count=0;
initial $readmemh("expected.mem",expected);
always @(posedge clk) begin
 if(dut.rst_n && dut.tx_valid && dut.tx_ready) begin
  if(dut.tx_data !== expected[count%54])
   $fatal(1,"UART byte %0d got=%h expected=%h",count,dut.tx_data,expected[count%54]);
  count=count+1;
  if(count==108) begin $display("PASS SSF1 board harness: 108 UART bytes, 48 signed results");$finish;end
 end
end
initial begin #10000000;$fatal(1,"TIMEOUT");end
endmodule
