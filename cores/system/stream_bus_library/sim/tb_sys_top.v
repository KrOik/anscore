`timescale 1ns/1ps
module tb_sys_top #(parameter PROFILE=0,BIT_CYCLES=12);
reg clk=0;
always #1 clk=~clk;
reg uart_rx=1;
wire uart_tx;
wire [1:0] led;
sys_top #(.PROFILE(PROFILE),.BIT_CYCLES(BIT_CYCLES)) dut(clk,uart_rx,uart_tx,led);
endmodule
