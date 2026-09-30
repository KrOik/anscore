`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// 二改 for GW2A-18C (Tang Primer 20K):
//   Original selects Xilinx mul_64b IP for DESIGN_FPGA / sim model for DESIGN_SIM.
//   Replaced by a single generic behavioural multiplier; yosys/synth_gowin maps
//   it onto MULT18X18 DSP blocks automatically.
//////////////////////////////////////////////////////////////////////////////////
module mul_64b_wrapper(
    input [63:0]    a,
    input [63:0]    b,

    output [127:0]  p
);
	assign	p = a * b;

endmodule
