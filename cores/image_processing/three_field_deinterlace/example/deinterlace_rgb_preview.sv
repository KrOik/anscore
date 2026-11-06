// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Complete grayscale-to-RGB diagnostic composition. EVERY port is CE-qualified.
module deinterlace_rgb_preview #(
    parameter integer WIDTH=128, HEIGHT=64
)(
    input wire clk,rst,ce,cfg_first_parity,
    input wire [7:0] cfg_threshold,
    input wire cfg_tint_spatial,
    input wire s_valid,
    output wire s_ready,
    input wire [7:0] s_pixel,
    input wire s_field_sof,s_eol,s_parity,
    output wire m_valid,
    input wire m_ready,
    output wire [23:0] m_rgb,
    output wire m_sof,m_eol,m_last,
    output wire done_valid,
    input wire done_ready,
    output wire [1:0] done_error,
    output wire busy
);
    wire [7:0] y;
    wire [1:0] source;
    wire signed [2:0] direction;
    reg tint;
    // Snapshot on the same first P transfer as the core configuration.
    always @(posedge clk) begin
        if(rst) tint<=0;
        else if(ce && s_valid && s_ready && !busy) tint<=cfg_tint_spatial;
    end
    assign m_rgb=(tint && source==2)?{8'hff,y,8'h00}:{y,y,y};
    three_field_deinterlace #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.BITS(8)) core(
        .clk(clk),.rst(rst),.ce(ce),.cfg_first_parity(cfg_first_parity),.cfg_threshold(cfg_threshold),
        .s_valid(s_valid),.s_ready(s_ready),.s_pixel(s_pixel),.s_field_sof(s_field_sof),.s_eol(s_eol),.s_parity(s_parity),
        .m_valid(m_valid),.m_ready(m_ready),.m_pixel(y),.m_source(source),.m_dir(direction),
        .m_sof(m_sof),.m_eol(m_eol),.m_last(m_last),.done_valid(done_valid),.done_ready(done_ready),
        .done_error(done_error),.busy(busy)
    );
endmodule
