// SPDX-License-Identifier: Apache-2.0
module triangle64_example(
    input wire clk,rst,c_valid,output wire c_ready,
    input wire signed [9:0] c_x0,c_y0,c_x1,c_y1,c_x2,c_y2,
    input wire [23:0] c_rgb0,c_rgb1,c_rgb2,input wire [7:0] c_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_x,m_y,
    output wire [23:0] m_rgb,output wire m_first,output wire [7:0] m_tag,
    output wire d_valid,input wire d_ready,output wire [1:0] d_status,
    output wire [16:0] d_count,output wire [7:0] d_tag
);
    triangle_rgb_raster #(.WIDTH(64),.HEIGHT(64),.TAG_W(8)) core(.*);
endmodule
