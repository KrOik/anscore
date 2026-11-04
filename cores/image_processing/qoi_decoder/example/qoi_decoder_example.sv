// Complete default direct wiring, no implicit CE-qualified stream connection.
`timescale 1ns/1ps
module qoi_decoder_example(
    input wire clk,rst,s_valid,s_last,m_ready,
    input wire [7:0] s_byte,s_tag,output wire s_ready,m_valid,
    output wire [31:0] m_rgba,m_width,m_height,output wire [2:0] m_x,m_y,
    output wire m_sof,m_eol,m_last,output wire [7:0] m_channels,m_tag,
    output wire m_colorspace,output wire [2:0] m_status,output wire [8:0] m_bytes
);
    qoi_decoder core(.*);
endmodule
