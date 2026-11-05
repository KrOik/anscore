`timescale 1ns/1ps
module diffusion16(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire [7:0] s_pixel,s_k,input wire [4:0] s_iterations,
    input wire s_sof,s_eol,s_last,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,output wire [7:0] m_pixel,
    output wire [15:0] m_value_q8,output wire [3:0] m_x,m_y,
    output wire m_sof,m_eol,m_last,m_keep,output wire [4:0] m_errors,
    output wire [7:0] m_tag
);
    grayscale_anisotropic_diffusion #(.WIDTH(16),.HEIGHT(16),.TAG_W(8)) core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),
        .s_k(s_k),.s_iterations(s_iterations),.s_sof(s_sof),.s_eol(s_eol),
        .s_last(s_last),.s_tag(s_tag),.m_valid(m_valid),.m_ready(m_ready),
        .m_pixel(m_pixel),.m_value_q8(m_value_q8),.m_x(m_x),.m_y(m_y),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_keep(m_keep),
        .m_errors(m_errors),.m_tag(m_tag));
endmodule
