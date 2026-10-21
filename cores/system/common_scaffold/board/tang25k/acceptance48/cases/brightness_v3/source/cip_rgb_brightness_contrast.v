// RGB888 configurable-pivot brightness/contrast, three elastic arithmetic stages.
// Parameter inputs must be stable throughout a frame (the command adapter latches them).
module cip_rgb_brightness_contrast(
    input wire clk,rst_n,clk_en,
    input wire [23:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
    input wire signed [9:0] brightness,input wire [15:0] contrast,input wire [7:0] pivot,
    output reg [23:0] m_data,output reg m_valid,m_sof,m_eol,input wire m_ready
);
reg v1,v2,sof1,sof2,eol1,eol2;
reg signed [8:0] dr,dg,db;
reg signed [25:0] pr,pg,pb;
reg [15:0] gain;
reg signed [9:0] offset1,offset2;
reg [7:0] pivot1,pivot2;
wire r3=!m_valid || m_ready;
wire r2=!v2 || r3;
wire r1=!v1 || r2;
assign s_ready=rst_n && r1;
function [7:0] finish;
    input signed [25:0] product;
    input signed [9:0] offset;
    input [7:0] center;
    reg signed [26:0] result;
    begin
        result=(($signed({product[25],product})+27'sd128)>>>8)+$signed({1'b0,center})+offset;
        finish=result<0?8'd0:result>255?8'd255:result[7:0];
    end
endfunction
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        v1<=0;v2<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_data<=0;
        sof1<=0;sof2<=0;eol1<=0;eol2<=0;dr<=0;dg<=0;db<=0;
        pr<=0;pg<=0;pb<=0;gain<=0;offset1<=0;offset2<=0;pivot1<=0;pivot2<=0;
    end else if(clk_en)begin
        if(r3)begin
            m_valid<=v2;
            if(v2)begin
                m_data<={finish(pr,offset2,pivot2),finish(pg,offset2,pivot2),finish(pb,offset2,pivot2)};
                m_sof<=sof2;m_eol<=eol2;
            end
        end
        if(r2)begin
            v2<=v1;
            if(v1)begin
                pr<=dr*$signed({1'b0,gain});pg<=dg*$signed({1'b0,gain});pb<=db*$signed({1'b0,gain});
                offset2<=offset1;pivot2<=pivot1;sof2<=sof1;eol2<=eol1;
            end
        end
        if(r1)begin
            v1<=s_valid;
            if(s_valid)begin
                dr<=$signed({1'b0,s_data[23:16]})-$signed({1'b0,pivot});
                dg<=$signed({1'b0,s_data[15:8]})-$signed({1'b0,pivot});
                db<=$signed({1'b0,s_data[7:0]})-$signed({1'b0,pivot});
                gain<=contrast;offset1<=brightness;pivot1<=pivot;sof1<=s_sof;eol1<=s_eol;
            end
        end
    end
end
endmodule
