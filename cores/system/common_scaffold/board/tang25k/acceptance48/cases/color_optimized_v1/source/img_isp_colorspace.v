// BT.601 full-range conversion, three enabled-clock elastic pipeline.
// Exact original integer coefficients, round-half-up and saturation.
module img_isp_colorspace (
 input wire clk,rst_n,clk_en,
 input wire [23:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,output reg [23:0] m_data,output reg m_valid,
 input wire m_ready,output reg m_sof,m_eol,
 input wire cfg_we,cfg_commit,cfg_yuv_to_rgb,output wire cfg_ready,output reg cfg_pending
);
reg shadow_direction,active_direction;
wire apply=cfg_pending && s_sof;
wire direction=apply?shadow_direction:active_direction;
wire advance=!m_valid || m_ready;
assign s_ready=clk_en && advance;
assign cfg_ready=clk_en && !cfg_pending;
wire signed [8:0] c0=$signed({1'b0,s_data[23:16]});
wire signed [8:0] c1=$signed({1'b0,s_data[15:8]});
wire signed [8:0] c2=$signed({1'b0,s_data[7:0]});
wire signed [8:0] u=c1-9'sd128,v=c2-9'sd128;
reg signed [17:0] p00,p01,p02,p10,p11,p12,p20,p21,p22;
reg inv1,v1,v2,sof1,eol1,sof2,eol2;
reg signed [19:0] a2,b2,c2sum;
function [7:0] clip;
 input signed [19:0] fixed_value;reg signed [19:0] value;
 begin value=fixed_value>>>8;
 if(value<0)clip=0;else if(value>255)clip=255;else clip=value[7:0];end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
 shadow_direction<=0;active_direction<=0;cfg_pending<=0;
 p00<=0;p01<=0;p02<=0;p10<=0;p11<=0;p12<=0;p20<=0;p21<=0;p22<=0;
 inv1<=0;v1<=0;v2<=0;sof1<=0;eol1<=0;sof2<=0;eol2<=0;
 a2<=0;b2<=0;c2sum<=0;m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;
 end else if(clk_en)begin
 if(cfg_we && cfg_ready)shadow_direction<=cfg_yuv_to_rgb;
 if(cfg_commit && cfg_ready)cfg_pending<=1;
 if(advance)begin
  v1<=s_valid;v2<=v1;m_valid<=v2;
  if(s_valid)begin
   inv1<=direction;sof1<=s_sof;eol1<=s_eol;
   if(!direction)begin
    p00<=77*c0;p01<=150*c1;p02<=29*c2;
    p10<=-43*c0;p11<=-85*c1;p12<=128*c2;
    p20<=128*c0;p21<=-107*c1;p22<=-21*c2;
   end else begin
    p00<=256*c0;p01<=359*v;p02<=0;
    p10<=256*c0;p11<=-88*u;p12<=-183*v;
    p20<=256*c0;p21<=454*u;p22<=0;
   end
   if(apply)begin active_direction<=shadow_direction;cfg_pending<=0;end
  end
  if(v1)begin
   a2<=$signed(p00)+$signed(p01)+$signed(p02)+20'sd128;
   b2<=$signed(p10)+$signed(p11)+$signed(p12)+(inv1?20'sd128:20'sd32896);
   c2sum<=$signed(p20)+$signed(p21)+$signed(p22)+(inv1?20'sd128:20'sd32896);
   sof2<=sof1;eol2<=eol1;
  end
  if(v2)begin m_data<={clip(a2),clip(b2),clip(c2sum)};m_sof<=sof2;m_eol<=eol2;end
 end
 end
end
endmodule
