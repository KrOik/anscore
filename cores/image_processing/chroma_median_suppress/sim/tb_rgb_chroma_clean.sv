// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_rgb_chroma_clean;
 tb_chroma_median_suppress #(.W(16),.H(12),.D(8),.T(8),.EXAMPLE(1)) finite_actual_chain();
endmodule
