`timescale 1ns/1ps
module tb_dump;
  reg clk=0; always #18.5 clk=~clk;
  wire tx; dump_top d(.clk(clk),.uart_tx(tx),.dbg_uart());
  integer n=0; integer edges=0;
  reg prev=1;
  initial begin
    #30000000;  // 30ms
    $display("edges=%0d", edges);
    $finish;
  end
  always @(posedge clk) begin
    if (tx !== prev) begin edges=edges+1; prev<=tx; end
  end
endmodule
