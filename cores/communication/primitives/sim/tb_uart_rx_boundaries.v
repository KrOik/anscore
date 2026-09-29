`timescale 1ns/1ps
module tb_uart_rx_boundaries;
  localparam integer C=234;
  reg clk=0, rst_n=0, ce=1, rx=1, ack=0;
  always #5 clk=~clk;
  wire [7:0] data;
  wire valid, err;
  uart_rx dut(.clk(clk),.rst_n(rst_n),.clk_en(ce),.rx_pin(rx),
    .rx_data(data),.rx_valid(valid),.rx_ack(ack),.framing_err(err));
  task bit_time(input value);
    begin rx=value; repeat(C) @(negedge clk); end
  endtask
  task frame(input [7:0] value,input stop);
    integer b;
    begin
      bit_time(0);
      for(b=0;b<8;b=b+1) bit_time(value[b]);
      bit_time(stop); rx=1;
    end
  endtask
  task check(input [7:0] value,input framing);
    begin
      if(valid!==1 || data!==value || err!==framing)
        $fatal(1,"expected %02x/%b got valid=%b %02x/%b",value,framing,valid,data,err);
    end
  endtask
  task consume;
    begin ack=1; @(negedge clk); ack=0; @(negedge clk);
      if(valid!==0) $fatal(1,"ack did not clear valid");
    end
  endtask
  initial begin
    repeat(5) @(negedge clk); rst_n=1;
    repeat(5) @(negedge clk);
    rx=0; repeat(10) @(negedge clk); rx=1;
    repeat(C*11) @(negedge clk);
    if(valid!==0) $fatal(1,"false start accepted");
    frame(8'h36,1); check(8'h36,0);
    // A full subsequent frame must not corrupt an unread holding register.
    frame(8'hc9,1); check(8'h36,0);
    ce=0; ack=1;
    repeat(20) @(negedge clk); check(8'h36,0);
    ack=0; ce=1; consume;
    frame(8'h81,0); check(8'h81,1);
    repeat(C*2) @(negedge clk); check(8'h81,1); consume;
    frame(8'h5a,1); check(8'h5a,0); consume;
    // With ack continuously high, completed frames still assert valid.
    ack=1;
    fork
      begin frame(8'ha6,1); end
      begin wait(valid===1); #1; check(8'ha6,0); end
    join
    $display("UART_BOUNDARIES PASS false_start hold overrun clk_en framing recovery ack_high");
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
