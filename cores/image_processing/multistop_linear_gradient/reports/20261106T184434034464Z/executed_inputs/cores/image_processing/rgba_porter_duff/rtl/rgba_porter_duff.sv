// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module rgba_porter_duff #(parameter integer TAG_W=8)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [31:0] s_src,s_dst, // {R,G,B,A}, premultiplied unsigned bytes
    input wire [3:0] s_mode,input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,output reg [31:0] m_rgba,
    output reg [1:0] m_error,output reg [3:0] m_mode,
    output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output wire pipeline_busy
);
    reg v1,v2,v3;
    reg [15:0] ps[0:3],pd[0:3];
    reg [16:0] sums[0:3];
    reg [1:0] error1,error2;
    reg [3:0] mode1,mode2;
    reg [15:0] x1,y1,x2,y2;
    reg [TAG_W-1:0] tag1,tag2;
    reg [7:0] fa,fb;
    wire step=!v3 || m_ready;
    wire src_bad=s_src[31:24]>s_src[7:0] || s_src[23:16]>s_src[7:0] || s_src[15:8]>s_src[7:0];
    wire dst_bad=s_dst[31:24]>s_dst[7:0] || s_dst[23:16]>s_dst[7:0] || s_dst[15:8]>s_dst[7:0];
    wire [1:0] error_in=s_mode>12 ? 2'd1 : src_bad ? 2'd2 : dst_bad ? 2'd3 : 2'd0;
    assign s_ready=!rst && step;
    assign m_valid=!rst && v3;
    assign pipeline_busy=!rst && (v1 || v2 || v3);
    // Exact round-to-nearest for denominator 255, then clamp. No half ties exist.
    function automatic [7:0] quantize(input [16:0] total);
        reg [16:0] biased,folded;
        begin
            if(total>=17'd65025) quantize=8'd255;
            else begin
                biased=total+17'd127; // <=65151, so the fold is exact on this domain.
                folded=biased+17'd1+(biased>>8);
                quantize=folded[15:8];
            end
        end
    endfunction
    always_comb begin
        fa=0;fb=0;
        case(s_mode)
            0:begin fa=0;fb=0;end
            1:begin fa=255;fb=0;end
            2:begin fa=0;fb=255;end
            3:begin fa=255;fb=8'd255-s_src[7:0];end
            4:begin fa=8'd255-s_dst[7:0];fb=255;end
            5:begin fa=s_dst[7:0];fb=0;end
            6:begin fa=0;fb=s_src[7:0];end
            7:begin fa=8'd255-s_dst[7:0];fb=0;end
            8:begin fa=0;fb=8'd255-s_src[7:0];end
            9:begin fa=s_dst[7:0];fb=8'd255-s_src[7:0];end
            10:begin fa=8'd255-s_dst[7:0];fb=s_src[7:0];end
            11:begin fa=8'd255-s_dst[7:0];fb=8'd255-s_src[7:0];end
            12:begin fa=255;fb=255;end
            default:begin fa=0;fb=0;end
        endcase
    end
    initial if(TAG_W<1 || TAG_W>32) $fatal(1,"rgba_porter_duff TAG_W must be 1..32");
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            v1<=0;v2<=0;v3<=0;error1<=0;error2<=0;m_error<=0;
            mode1<=0;mode2<=0;m_mode<=0;x1<=0;y1<=0;x2<=0;y2<=0;m_x<=0;m_y<=0;
            tag1<=0;tag2<=0;m_tag<=0;m_rgba<=0;
            for(i=0;i<4;i=i+1)begin ps[i]<=0;pd[i]<=0;sums[i]<=0;end
        end else if(step) begin
            v1<=s_valid;v2<=v1;v3<=v2;
            if(s_valid) begin
                for(i=0;i<4;i=i+1)begin
                    ps[i]<=s_src[i*8+:8]*fa;pd[i]<=s_dst[i*8+:8]*fb;
                end
                error1<=error_in;mode1<=s_mode;x1<=s_x;y1<=s_y;tag1<=s_tag;
            end
            if(v1) begin
                for(i=0;i<4;i=i+1)sums[i]<={1'b0,ps[i]}+{1'b0,pd[i]};
                error2<=error1;mode2<=mode1;x2<=x1;y2<=y1;tag2<=tag1;
            end
            if(v2) begin
                for(i=0;i<4;i=i+1)m_rgba[i*8+:8]<=error2!=0 ? 8'd0 : quantize(sums[i]);
                m_error<=error2;m_mode<=mode2;m_x<=x2;m_y<=y2;m_tag<=tag2;
            end
        end
    end
endmodule
