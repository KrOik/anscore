`timescale 1ns/1ps
module tb_uart_diagnostic_top;
 reg clk=0,rx=1;
 always #5 clk=~clk;
 wire tx;
 wire [7:0] probe,data;
 wire valid,error;
 integer received=0;
 uart_diagnostic_top #(.BIT_CYCLES(16)) dut(clk,rx,tx,probe);
 sys_uart_rx #(.BIT_CYCLES(16)) monitor(clk,dut.rst_n,tx,data,valid,error);
 always @(posedge clk) if(dut.rst_n&&valid) begin
  if(data!==8'h55||error) $fatal(1,"beacon byte");
  received=received+1;
 end
 initial begin
  wait(dut.rst_n);
  @(negedge clk); rx=0; repeat(16) @(negedge clk);
  for(integer i=0;i<8;i=i+1) begin rx=(8'ha7>>i)&1; repeat(16) @(negedge clk); end
  rx=1; repeat(20) @(negedge clk);
  if(dut.rx_data!==8'ha7||dut.rx_toggle!==1||dut.sticky_error) $fatal(1,"diagnostic RX");
  wait(received==1); #1;
  $display("PASS UART diagnostic physical-pin fanout RX A7 TX 55");
  $finish;
 end
 initial begin #8000000; $fatal(1,"diagnostic timeout"); end
endmodule
