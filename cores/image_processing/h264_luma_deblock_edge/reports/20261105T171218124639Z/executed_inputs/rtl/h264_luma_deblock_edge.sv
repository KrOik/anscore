// SPDX-License-Identifier: Apache-2.0
// Original portable eight-bit luma boundary kernel; thresholds are caller-owned.
`default_nettype none
module h264_luma_deblock_edge #(parameter integer TAG_W=8)(
    input wire clk, input wire rst,
    input wire s_valid, output wire s_ready,
    input wire [63:0] s_pixels,
    input wire [2:0] s_bs,
    input wire [7:0] s_alpha,s_beta,
    input wire [4:0] s_tc0,
    input wire [TAG_W-1:0] s_tag, input wire s_last,
    output reg m_valid, input wire m_ready,
    output reg [63:0] m_pixels,
    output reg m_error,m_changed,
    output reg [TAG_W-1:0] m_tag, output reg m_last
);
    generate if(TAG_W<1 || TAG_W>32) begin: bad_parameters
        h264_luma_deblock_edge_invalid_TAG_W invalid_parameter();
    end endgenerate
    wire [7:0] p3=s_pixels[7:0],p2=s_pixels[15:8],p1=s_pixels[23:16],p0=s_pixels[31:24];
    wire [7:0] q0=s_pixels[39:32],q1=s_pixels[47:40],q2=s_pixels[55:48],q3=s_pixels[63:56];
    function automatic [7:0] distance(input [7:0] a,b);
        begin distance=(a>=b)?a-b:b-a;end
    endfunction
    function automatic signed [11:0] positive(input [7:0] a);
        begin positive=$signed({4'b0,a});end
    endfunction
    function automatic [10:0] unsigned11(input [7:0] a);
        begin unsigned11={3'b0,a};end
    endfunction
    function automatic signed [11:0] limit_delta(input signed [11:0] value,input [5:0] limit);
        reg signed [11:0] bound;
        begin
            bound=$signed({6'b0,limit});
            if(value>bound) limit_delta=bound;
            else if(value < -bound) limit_delta=-bound;
            else limit_delta=value;
        end
    endfunction
    function automatic [7:0] clip_pixel(input signed [11:0] value);
        begin
            if(value<0) clip_pixel=0;
            else if(value>255) clip_pixel=255;
            else clip_pixel=value[7:0];
        end
    endfunction
    wire gate=(distance(p0,q0)<s_alpha)&&(distance(p1,p0)<s_beta)&&(distance(q1,q0)<s_beta);
    wire ap=(distance(p2,p0)<s_beta), aq=(distance(q2,q0)<s_beta);
    wire [6:0] strong_threshold={1'b0,s_alpha[7:2]}+7'd2;
    wire strong_near=(distance(p0,q0)<strong_threshold);
    wire [8:0] average=({1'b0,p0}+{1'b0,q0}+9'd1)>>1;
    reg [63:0] result;
    reg [5:0] tc;
    reg signed [11:0] raw_delta,delta,side_delta;
    reg [10:0] sum;
    always @* begin
        result=s_pixels;tc=0;raw_delta=0;delta=0;side_delta=0;sum=0;
        if(s_bs>=1 && s_bs<=4 && gate) begin
            if(s_bs==4) begin
                if(strong_near && ap) begin
                    sum=unsigned11(p2)+(unsigned11(p1)<<1)+(unsigned11(p0)<<1)+(unsigned11(q0)<<1)+unsigned11(q1)+11'd4;
                    result[31:24]=sum[10:3];
                    sum=unsigned11(p2)+unsigned11(p1)+unsigned11(p0)+unsigned11(q0)+11'd2;
                    result[23:16]=sum[9:2];
                    sum=(unsigned11(p3)<<1)+unsigned11(p2)+(unsigned11(p2)<<1)+unsigned11(p1)+unsigned11(p0)+unsigned11(q0)+11'd4;
                    result[15:8]=sum[10:3];
                end else begin
                    sum=(unsigned11(p1)<<1)+unsigned11(p0)+unsigned11(q1)+11'd2;
                    result[31:24]=sum[9:2];
                end
                if(strong_near && aq) begin
                    sum=unsigned11(q2)+(unsigned11(q1)<<1)+(unsigned11(q0)<<1)+(unsigned11(p0)<<1)+unsigned11(p1)+11'd4;
                    result[39:32]=sum[10:3];
                    sum=unsigned11(q2)+unsigned11(q1)+unsigned11(q0)+unsigned11(p0)+11'd2;
                    result[47:40]=sum[9:2];
                    sum=(unsigned11(q3)<<1)+unsigned11(q2)+(unsigned11(q2)<<1)+unsigned11(q1)+unsigned11(q0)+unsigned11(p0)+11'd4;
                    result[55:48]=sum[10:3];
                end else begin
                    sum=(unsigned11(q1)<<1)+unsigned11(q0)+unsigned11(p1)+11'd2;
                    result[39:32]=sum[9:2];
                end
            end else begin
                tc={1'b0,s_tc0}+{5'b0,ap}+{5'b0,aq};
                raw_delta=(((positive(q0)-positive(p0))<<<2)+positive(p1)-positive(q1)+12'sd4)>>>3;
                delta=limit_delta(raw_delta,tc);
                result[31:24]=clip_pixel(positive(p0)+delta);
                result[39:32]=clip_pixel(positive(q0)-delta);
                if(ap) begin
                    side_delta=(positive(p2)+$signed({3'b0,average})-(positive(p1)<<<1))>>>1;
                    result[23:16]=clip_pixel(positive(p1)+limit_delta(side_delta,{1'b0,s_tc0}));
                end
                if(aq) begin
                    side_delta=(positive(q2)+$signed({3'b0,average})-(positive(q1)<<<1))>>>1;
                    result[47:40]=clip_pixel(positive(q1)+limit_delta(side_delta,{1'b0,s_tc0}));
                end
            end
        end
    end
    assign s_ready=!rst && (!m_valid || m_ready);
    always @(posedge clk) begin
        if(rst) begin
            m_valid<=0;m_pixels<=0;m_error<=0;m_changed<=0;m_tag<=0;m_last<=0;
        end else if(s_ready) begin
            m_valid<=s_valid;
            if(s_valid) begin
                m_pixels<=result;m_error<=(s_bs>4);m_changed<=(result!=s_pixels);
                m_tag<=s_tag;m_last<=s_last;
            end
        end
    end
endmodule
`default_nettype wire
