`timescale 1ns/1ps
module tb_input_layer_gap_board;
reg clk=0;always #5 clk=~clk;
wire uart_tx,dbg_uart;
input_layer_gap_board dut(.*);
reg [7:0] expected[0:165],got;
integer i,b;
initial begin
 $readmemh("input_gap_expected.mem",expected);
 wait(dut.rst_n);
 for(i=0;i<332;i=i+1) begin
  @(negedge dbg_uart);repeat(351) @(posedge clk);
  for(b=0;b<8;b=b+1) begin got[b]=dbg_uart;repeat(234) @(posedge clk);end
  if(dbg_uart!==1 || got!==expected[i%166])
   $fatal(1,"UART byte=%0d got=%h expected=%h",i,got,expected[i%166]);
 end
 $display("PASS input-gap board UART frames=2 convolution_bytes=320");
 $finish;
end
initial begin #12000000;$fatal(1,"timeout");end
endmodule
