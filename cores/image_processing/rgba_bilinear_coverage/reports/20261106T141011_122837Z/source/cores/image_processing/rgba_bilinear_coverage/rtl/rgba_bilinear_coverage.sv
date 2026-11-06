// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module rgba_bilinear_coverage #(parameter integer TAG_W=8)(
    input wire clk,rst,
    input wire s_valid,output wire s_ready,
    input wire [31:0] s_00,s_10,s_01,s_11, // straight {A,R,G,B}
    input wire [7:0] s_fx,s_fy,
    input wire [15:0] s_x,s_y,input wire [TAG_W-1:0] s_tag,
    output wire m_valid,input wire m_ready,
    output reg [31:0] m_rgba, // premultiplied {R,G,B,A}
    output reg [15:0] m_x,m_y,output reg [TAG_W-1:0] m_tag,
    output wire busy
);
    localparam [3:0] IDLE=0,WEIGHT_SETUP=1,WEIGHT_MUL=2,WEIGHT_SAVE=3,
        ALPHA_MUL=4,ALPHA_ADD=5,COLOR_ALPHA_MUL=6,COLOR_WEIGHT_SETUP=7,
        COLOR_WEIGHT_MUL=8,COLOR_ADD=9,ROUND=10,HOLD=11;
    reg [3:0] state;
    reg [31:0] pixels[0:3];
    reg [8:0] wx0,wx1,wy0,wy1;
    reg [1:0] tap,channel;
    reg [16:0] mul_a,mul_b,weight;
    reg [33:0] product;
    reg [23:0] alpha_sum;
    reg [31:0] colors[0:2];
    wire [7:0] alpha=pixels[tap][31:24];
    assign s_ready=!rst && state==IDLE;
    assign m_valid=!rst && state==HOLD;
    assign busy=!rst && state!=IDLE;
    function automatic [7:0] color_byte(input [31:0] argb,input [1:0] lane);
        case(lane)
            0:color_byte=argb[23:16];
            1:color_byte=argb[15:8];
            default:color_byte=argb[7:0];
        endcase
    endfunction
    function automatic [7:0] round_alpha(input [23:0] n);
        reg [8:0] result;
        begin
            result={1'b0,n[23:16]}+9'((n[15:0]>16'h8000) ||
                       (n[15:0]==16'h8000 && n[16]));
            round_alpha=result[7:0];
        end
    endfunction
    // n <= 65025*65536. Exact floor(high16/255), then full 24-bit
    // remainder vs half of 255*65536. No intermediate premultiplication rounding.
    function automatic [7:0] round_color(input [31:0] n);
        reg [16:0] folded;
        reg [7:0] quotient;
        reg [15:0] residual_high;
        reg [23:0] remainder;
        reg [8:0] result;
        begin
            folded={1'b0,n[31:16]}+17'd1+({1'b0,n[31:16]}>>8);
            quotient=folded[15:8];
            residual_high=n[31:16]-({quotient,8'b0}-{8'b0,quotient});
            remainder={residual_high[7:0],n[15:0]};
            result={1'b0,quotient}+9'((remainder>24'h7f8000) ||
                        (remainder==24'h7f8000 && quotient[0]));
            round_color=result[7:0];
        end
    endfunction
    initial if(TAG_W<1 || TAG_W>32) $fatal(1,"rgba_bilinear_coverage TAG_W 1..32");
    integer k;
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;tap<=0;channel<=0;wx0<=0;wx1<=0;wy0<=0;wy1<=0;
            mul_a<=0;mul_b<=0;weight<=0;product<=0;alpha_sum<=0;
            m_rgba<=0;m_x<=0;m_y<=0;m_tag<=0;
            for(k=0;k<4;k=k+1)pixels[k]<=0;
            for(k=0;k<3;k=k+1)colors[k]<=0;
        end else begin
            // One shared unsigned 17x17 product register, one expression.
            if(state==WEIGHT_MUL || state==ALPHA_MUL ||
               state==COLOR_ALPHA_MUL || state==COLOR_WEIGHT_MUL)
                product<=mul_a*mul_b;
            case(state)
                IDLE:if(s_valid)begin
                    pixels[0]<=s_00;pixels[1]<=s_10;pixels[2]<=s_01;pixels[3]<=s_11;
                    wx0<=9'd256-{1'b0,s_fx};wx1<={1'b0,s_fx};
                    wy0<=9'd256-{1'b0,s_fy};wy1<={1'b0,s_fy};
                    m_x<=s_x;m_y<=s_y;m_tag<=s_tag;
                    alpha_sum<=0;tap<=0;channel<=0;
                    for(k=0;k<3;k=k+1)colors[k]<=0;
                    state<=WEIGHT_SETUP;
                end
                WEIGHT_SETUP:begin
                    mul_a<={8'b0,(tap[0]?wx1:wx0)};
                    mul_b<={8'b0,(tap[1]?wy1:wy0)};state<=WEIGHT_MUL;
                end
                WEIGHT_MUL:state<=WEIGHT_SAVE;
                WEIGHT_SAVE:begin
                    weight<=product[16:0];mul_a<=product[16:0];
                    mul_b<={9'b0,alpha};state<=ALPHA_MUL;
                end
                ALPHA_MUL:state<=ALPHA_ADD;
                ALPHA_ADD:begin
                    alpha_sum<=alpha_sum+product[23:0];channel<=0;
                    mul_a<={9'b0,alpha};mul_b<={9'b0,color_byte(pixels[tap],0)};
                    state<=COLOR_ALPHA_MUL;
                end
                COLOR_ALPHA_MUL:state<=COLOR_WEIGHT_SETUP;
                COLOR_WEIGHT_SETUP:begin
                    mul_a<=weight;mul_b<={1'b0,product[15:0]};state<=COLOR_WEIGHT_MUL;
                end
                COLOR_WEIGHT_MUL:state<=COLOR_ADD;
                COLOR_ADD:begin
                    colors[channel]<=colors[channel]+product[31:0];
                    if(channel==2)begin
                        if(tap==3)state<=ROUND;
                        else begin tap<=tap+1'b1;state<=WEIGHT_SETUP;end
                    end else begin
                        channel<=channel+1'b1;mul_a<={9'b0,alpha};
                        mul_b<={9'b0,color_byte(pixels[tap],channel+1'b1)};
                        state<=COLOR_ALPHA_MUL;
                    end
                end
                ROUND:begin
                    m_rgba<={round_color(colors[0]),round_color(colors[1]),
                             round_color(colors[2]),round_alpha(alpha_sum)};
                    state<=HOLD;
                end
                HOLD:if(m_ready)state<=IDLE;
                default:state<=IDLE;
            endcase
        end
    end
endmodule
