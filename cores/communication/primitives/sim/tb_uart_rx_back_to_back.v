`timescale 1ns/1ps
// Independent bit-banged 8N1 source: exactly one stop bit, no extra gap.
// Consumer acknowledges one bit period after valid, well before next byte.
module tb_uart_rx_back_to_back;
  localparam integer BIT_CYCLES = 234;
  reg clk=0, rst_n=0, rx=1, ack=0;
  always #5 clk=~clk;
  wire [7:0] data;
  wire valid, err;
  integer got=0, delay_ack=0, i;
  reg [7:0] expected [0:31];
  uart_rx dut(.clk(clk),.rst_n(rst_n),.clk_en(1'b1),.rx_pin(rx),
              .rx_data(data),.rx_valid(valid),.rx_ack(ack),.framing_err(err));
  always @(negedge clk) begin
    ack=0;
    if (rst_n && valid) begin
      if (delay_ack == BIT_CYCLES) begin
        if (got >= 32) $fatal(1,"extra output");
        if (data !== expected[got] || err !== 1'b0)
          $fatal(1,"byte %0d expected=%02x actual=%02x framing=%b",got,expected[got],data,err);
        got=got+1;
        ack=1;
        delay_ack=0;
      end else delay_ack=delay_ack+1;
    end
  end
  task bit_time(input value);
    begin rx=value; repeat(BIT_CYCLES) @(negedge clk); end
  endtask
  task send_byte(input [7:0] value);
    integer b;
    begin
      bit_time(0);
      for(b=0;b<8;b=b+1) bit_time(value[b]);
      bit_time(1);
    end
  endtask
  initial begin
    for(i=0;i<32;i=i+1) expected[i]=(i*73)^8'ha5;
    repeat(5) @(negedge clk); rst_n=1;
    repeat(5) @(negedge clk);
    for(i=0;i<32;i=i+1) send_byte(expected[i]);
    repeat(BIT_CYCLES*12) @(negedge clk);
    if(got != 32) $fatal(1,"received %0d/32",got);
    $display("UART_BACK_TO_BACK PASS bytes=%0d",got);
    $finish;
  end
  initial begin #2000000; $fatal(1,"timeout"); end
endmodule
