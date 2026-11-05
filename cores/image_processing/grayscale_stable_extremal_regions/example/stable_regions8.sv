// SPDX-License-Identifier: Apache-2.0
module stable_regions8(
    input wire clk,rst,input wire s_valid,output wire s_ready,
    input wire [7:0] s_pixel,input wire s_sof,s_eol,input wire [7:0] s_tag,
    input wire cfg_bright,input wire [7:0] cfg_delta,cfg_variation_p,cfg_variation_q,
    input wire [6:0] cfg_min_area,cfg_max_area,
    output wire m_valid,input wire m_ready,output wire [5:0] m_index,m_parent,
    output wire [7:0] m_level,output wire [6:0] m_area,m_variation_num,m_variation_den,
    output wire m_canonical,m_selected,m_sof,m_eol,m_last,
    output wire [2:0] m_errors,output wire [7:0] m_tag
);
    grayscale_stable_extremal_regions #(.WIDTH(8),.HEIGHT(8),.CONNECTIVITY(4),.TAG_W(8)) core(
        .clk(clk),.rst(rst),.s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),.s_sof(s_sof),.s_eol(s_eol),.s_tag(s_tag),
        .cfg_bright(cfg_bright),.cfg_delta(cfg_delta),.cfg_variation_p(cfg_variation_p),.cfg_variation_q(cfg_variation_q),
        .cfg_min_area(cfg_min_area),.cfg_max_area(cfg_max_area),.m_valid(m_valid),.m_ready(m_ready),
        .m_index(m_index),.m_parent(m_parent),.m_level(m_level),.m_area(m_area),.m_variation_num(m_variation_num),
        .m_variation_den(m_variation_den),.m_canonical(m_canonical),.m_selected(m_selected),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.m_errors(m_errors),.m_tag(m_tag)
    );
endmodule
