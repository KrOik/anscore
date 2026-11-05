// SPDX-License-Identifier: Apache-2.0
// Complete default-size instantiation; all transaction and raster ports exposed.
module seam_carve_example (
    input wire clk,rst,c_valid, input wire [7:0] c_tag, output wire c_ready,
    input wire s_valid, input wire [7:0] s_pixel, input wire s_sof,s_eol,s_last,
    output wire s_ready, output wire m_valid, input wire m_ready,
    output wire [7:0] m_pixel, output wire m_sof,m_eol,m_last,
    output wire [6:0] m_removed_x, output wire d_valid, input wire d_ready,
    output wire d_error, output wire [15:0] d_cost, output wire [7:0] d_tag
);
    grayscale_vertical_seam_carve #(.WIDTH(16),.HEIGHT(16),.TAG_W(8)) core(.*);
endmodule
