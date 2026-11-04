`timescale 1ns/1ps
module qoi_encoder_default(
    input wire clk,rst,s_valid, output wire s_ready,
    input wire [31:0] s_pixel, input wire s_sof,s_eol,s_error,
    input wire [7:0] s_tag, input wire s_colorspace,
    output wire m_valid, input wire m_ready,
    output wire [7:0] m_byte, output wire m_sof,m_last,
    output wire [8:0] m_index, output wire [7:0] m_tag,
    output wire d_valid, input wire d_ready,
    output wire [8:0] d_bytes, output wire [2:0] d_errors,
    output wire [7:0] d_tag, output wire d_colorspace
);
    qoi_encoder #(.WIDTH(8),.HEIGHT(8),.CHANNELS(4),.TAG_W(8)) encoder(.*);
endmodule
