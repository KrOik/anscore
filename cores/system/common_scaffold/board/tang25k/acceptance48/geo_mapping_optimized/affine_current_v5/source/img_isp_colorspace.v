// Exact BT.601 products in synchronous ROM, four enabled-clock pipeline.
module img_isp_colorspace (
 input wire clk,rst_n,clk_en,input wire [23:0] s_data,input wire s_valid,
 output wire s_ready,input wire s_sof,s_eol,output reg [23:0] m_data,
 output reg m_valid,input wire m_ready,output reg m_sof,m_eol,
 input wire cfg_we,cfg_commit,cfg_yuv_to_rgb,output wire cfg_ready,output reg cfg_pending
);
reg shadow_direction,active_direction;
wire apply=cfg_pending && s_sof;
wire direction=apply?shadow_direction:active_direction;
wire advance=!m_valid || m_ready;
assign s_ready=clk_en && advance;assign cfg_ready=clk_en && !cfg_pending;
(* ram_style="block" *) reg [71:0] rt[0:255];
(* ram_style="block" *) reg [89:0] gt[0:255],bt[0:255];
reg [71:0] rq;reg [89:0] gq,bq;
integer i;
initial begin for(i=0;i<256;i=i+1)begin
 rt[i][0+:18]=77*i;rt[i][18+:18]=-43*i;rt[i][36+:18]=128*i;rt[i][54+:18]=256*i;
 gt[i][0+:18]=150*i;gt[i][18+:18]=-85*i;gt[i][36+:18]=-107*i;gt[i][54+:18]=-88*(i-128);gt[i][72+:18]=454*(i-128);
 bt[i][0+:18]=29*i;bt[i][18+:18]=128*i;bt[i][36+:18]=-21*i;bt[i][54+:18]=359*(i-128);bt[i][72+:18]=-183*(i-128);
 end end
always @(posedge clk)if(clk_en && advance && s_valid)begin rq<=rt[s_data[23:16]];gq<=gt[s_data[15:8]];bq<=bt[s_data[7:0]];end
reg inv1,v1,v2,v3,sof1,sof2,sof3,eol1,eol2,eol3;
reg signed [19:0] a_lo,a_hi,b_lo,b_hi,c_lo,c_hi,a_sum,b_sum,c_sum;
function [7:0] clip;input signed [19:0] q;reg signed [19:0] value;
 begin value=q>>>8;if(value<0)clip=0;else if(value>255)clip=255;else clip=value[7:0];end
endfunction
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
 shadow_direction<=0;active_direction<=0;cfg_pending<=0;inv1<=0;v1<=0;v2<=0;v3<=0;
 sof1<=0;sof2<=0;sof3<=0;eol1<=0;eol2<=0;eol3<=0;
 a_lo<=0;a_hi<=0;b_lo<=0;b_hi<=0;c_lo<=0;c_hi<=0;a_sum<=0;b_sum<=0;c_sum<=0;
 m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;
 end else if(clk_en)begin
 if(cfg_we && cfg_ready)shadow_direction<=cfg_yuv_to_rgb;
 if(cfg_commit && cfg_ready)cfg_pending<=1;
 if(advance)begin
 v1<=s_valid;v2<=v1;v3<=v2;m_valid<=v3;
 if(s_valid)begin inv1<=direction;sof1<=s_sof;eol1<=s_eol;if(apply)begin active_direction<=shadow_direction;cfg_pending<=0;end end
 if(v1)begin
 if(!inv1)begin
 a_lo<=$signed(rq[0+:18])+$signed(gq[0+:18]);a_hi<=$signed(bq[0+:18])+20'sd128;
 b_lo<=$signed(rq[18+:18])+$signed(gq[18+:18]);b_hi<=$signed(bq[18+:18])+20'sd32896;
 c_lo<=$signed(rq[36+:18])+$signed(gq[36+:18]);c_hi<=$signed(bq[36+:18])+20'sd32896;
 end else begin
 a_lo<=$signed(rq[54+:18])+$signed(bq[54+:18]);a_hi<=20'sd128;
 b_lo<=$signed(rq[54+:18])+$signed(gq[54+:18]);b_hi<=$signed(bq[72+:18])+20'sd128;
 c_lo<=$signed(rq[54+:18])+$signed(gq[72+:18]);c_hi<=20'sd128;
 end
 sof2<=sof1;eol2<=eol1;
 end
 if(v2)begin a_sum<=a_lo+a_hi;b_sum<=b_lo+b_hi;c_sum<=c_lo+c_hi;sof3<=sof2;eol3<=eol2;end
 if(v3)begin m_data<={clip(a_sum),clip(b_sum),clip(c_sum)};m_sof<=sof3;m_eol<=eol3;end
 end
 end
end
endmodule
