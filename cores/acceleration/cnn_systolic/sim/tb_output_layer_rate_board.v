`timescale 1ns/1ps
module tb_output_layer_rate_board #(parameter TEST_PAGES=2);
reg clk=0; always #5 clk=~clk;
wire uart_tx,dbg_uart;
output_layer_rate_board #(.PAGES(TEST_PAGES)) dut(.*);
reg [7:0] expected[0:37],got;
integer i,b;
initial begin
 $readmemh("accumulation_expected.mem",expected);
 wait(dut.rst_n);
 for(i=0;i<76;i=i+1) begin
  @(negedge dbg_uart); repeat(351) @(posedge clk);
  for(b=0;b<8;b=b+1) begin got[b]=dbg_uart; repeat(234) @(posedge clk); end
  if(dbg_uart!==1 || got!==expected[i%38])
   $fatal(1,"UART mismatch byte=%0d got=%h expected=%h",i,got,expected[i%38]);
 end
 $display("PASS output-layer board UART frames=2 values=32 full_rate=1");
 $finish;
end
initial begin #3000000; $fatal(1,"timeout"); end
endmodule
