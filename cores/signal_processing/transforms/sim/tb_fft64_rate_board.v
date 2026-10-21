`timescale 1ns/1ps
module tb_fft64_rate_board #(parameter TEST_DIV=1);
reg clk=0; always #5 clk=~clk;
wire uart_tx,dbg_uart;
fft64_rate_board #(.ENABLE_DIV(TEST_DIV)) dut(.*);
reg [7:0] expected[0:2111];
reg [7:0] got;
integer i,b;
initial begin
 $readmemh("fft_board_expected.mem",expected);
 wait(dut.rst_n);
 for(i=0;i<2112;i=i+1) begin
  @(negedge dbg_uart);
  repeat(351) @(posedge clk);
  for(b=0;b<8;b=b+1) begin
   got[b]=dbg_uart; repeat(234) @(posedge clk);
  end
  if(dbg_uart!==1 || got!==expected[i])
   $fatal(1,"UART mismatch byte=%0d got=%h expected=%h",i,got,expected[i]);
 end
 $display("PASS FFT27 raw UART bytes=2112 vectors=8 bins=512 cycles=768");
 $finish;
end
initial begin #60000000; $fatal(1,"timeout"); end
endmodule
