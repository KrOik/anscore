`timescale 1ns/1ps
// SPDX-License-Identifier: Apache-2.0
// Up to 64 signed9 gradients, suitable for central differences of unsigned8 pixels.
// The caller supplies complete ordered/masked tile gradients and its last marker.
module gradient_tile_score(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [8:0] s_gx,s_gy,
    input wire s_keep,s_last,
    input wire [30:0] s_threshold,
    input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire signed [31:0] m_score,m_max_score,
    output wire [1:0] m_saturated,m_status,
    output wire m_corner,m_isotropic,
    output wire [6:0] m_count,
    output wire [24:0] m_energy,
    output wire [7:0] m_tag
);
    block_shi_tomasi core(.*);
endmodule
