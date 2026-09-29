`timescale 1ns/1ps
module tb_uart_rx_stream_board;
  reg clk=0;
  always #5 clk=~clk;
  wire pass, fail;
  uart_rx_stream_board dut(.clk(clk),.dbg_pass(pass),.dbg_fail(fail));
  initial begin
    wait(dut.done);
    #20;
    if(pass !== 1'b1 || fail !== 1'b0 || dut.received !== 32)
      $fatal(1,"stream board failed: received=%0d",dut.received);
    $display("UART_STREAM_BOARD PASS received=%0d",dut.received);
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
