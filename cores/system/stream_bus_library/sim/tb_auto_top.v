`timescale 1ns/1ps
module tb_auto_top #(parameter PROFILE=0);
reg clk=0; always #1 clk=~clk;
reg uart_rx=1; wire uart_tx; wire [1:0] led;
sys_auto_top #(.PROFILE(PROFILE),.BIT_CYCLES(12),.START_DELAY(10)) dut(clk,uart_rx,uart_tx,led);
endmodule
