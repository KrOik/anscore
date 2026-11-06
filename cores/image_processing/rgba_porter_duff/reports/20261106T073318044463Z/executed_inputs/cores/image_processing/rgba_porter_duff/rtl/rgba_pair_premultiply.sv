// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
// Atomic straight-RGBA pair conversion; transparent RGB is intentionally zeroed.
module rgba_pair_premultiply #(parameter integer TAG_W=8)(
    input wire clk,rst,input wire s_valid,output wire s_ready,
    input wire [31:0] s_src,s_dst,input wire [3:0] s_mode,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [31:0] m_src,m_dst,
    output reg [3:0] m_mode,output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output wire pipeline_busy
);
    reg v1,v2;
    reg [15:0] ps[0:2],pd[0:2];
    reg [7:0] as1,ad1;
    reg [3:0] mode1;
    reg [15:0] x1,y1;
    reg [TAG_W-1:0] tag1;
    wire step=!v2 || m_ready;
    assign s_ready=!rst && step;
    assign m_valid=!rst && v2;
    assign pipeline_busy=!rst && (v1 || v2);
    function automatic [7:0] rounded(input [15:0] product);
        reg [16:0] t,f;
        begin t={1'b0,product}+17'd127;f=t+17'd1+(t>>8);rounded=f[15:8];end
    endfunction
    initial if(TAG_W<1 || TAG_W>32) $fatal(1,"rgba_pair_premultiply invalid TAG_W");
    integer i;
    always @(posedge clk) begin
        if(rst)begin
            v1<=0;v2<=0;as1<=0;ad1<=0;mode1<=0;x1<=0;y1<=0;tag1<=0;
            m_src<=0;m_dst<=0;m_mode<=0;m_x<=0;m_y<=0;m_tag<=0;
            for(i=0;i<3;i=i+1)begin ps[i]<=0;pd[i]<=0;end
        end else if(step)begin
            v1<=s_valid;v2<=v1;
            if(s_valid)begin
                for(i=0;i<3;i=i+1)begin
                    ps[i]<=s_src[8+i*8+:8]*s_src[7:0];pd[i]<=s_dst[8+i*8+:8]*s_dst[7:0];
                end
                as1<=s_src[7:0];ad1<=s_dst[7:0];mode1<=s_mode;x1<=s_x;y1<=s_y;tag1<=s_tag;
            end
            if(v1)begin
                for(i=0;i<3;i=i+1)begin m_src[8+i*8+:8]<=rounded(ps[i]);m_dst[8+i*8+:8]<=rounded(pd[i]);end
                m_src[7:0]<=as1;m_dst[7:0]<=ad1;m_mode<=mode1;m_x<=x1;m_y<=y1;m_tag<=tag1;
            end
        end
    end
endmodule
