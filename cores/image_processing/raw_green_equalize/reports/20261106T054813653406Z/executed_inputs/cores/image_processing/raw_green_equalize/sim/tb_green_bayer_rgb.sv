// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_green_bayer_rgb;
 tb_raw_green_equalize #(.W(16),.H(12),.D(10),.T(8),.EXAMPLE(1)) finite_actual_chain();
endmodule
