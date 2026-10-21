// CSI-2/V4L2 RAW14 payload only; no packet/PHY or Bayer interpolation.
module raw14_pack #(parameter PIXEL_BITS=14)(
 input wire clk,rst_n,ce,input wire[13:0]s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[7:0]m_data,output wire m_valid,m_sof,m_eol,input wire m_ready,
 output reg protocol_error,error_valid,input wire error_ready,output reg[7:0]error_code,output reg[31:0]error_count);
 reg[2:0]in_index,out_index;reg emitting,locked,group_sof,group_eol,checked;
 localparam IN_LAST=3,OUT_LAST=6;
 reg[13:0]p0,p1,p2,p3;
 assign m_data=out_index==0?p0[13:6]:out_index==1?p1[13:6]:out_index==2?p2[13:6]:out_index==3?p3[13:6]:out_index==4?{p1[1:0],p0[5:0]}:out_index==5?{p2[3:0],p1[5:2]}:{p3[5:0],p2[5:4]};

 localparam PARAM_OK=PIXEL_BITS==14;

 assign s_ready=rst_n&&ce&&PARAM_OK&&!emitting;
 assign m_valid=emitting;
 assign m_sof=emitting&&group_sof&&out_index==0;
 assign m_eol=emitting&&group_eol&&out_index==OUT_LAST;
 task report_error;input[7:0]code;begin
  protocol_error<=1;if(error_count!=32'hffffffff)error_count<=error_count+1'b1;
  if(!error_valid||(ce&&error_ready))begin error_valid<=1;error_code<=code;end
 end endtask
 always @(posedge clk)begin
 if(!rst_n)begin in_index<=0;out_index<=0;emitting<=0;locked<=0;group_sof<=0;group_eol<=0;checked<=0;protocol_error<=0;error_valid<=0;error_code<=0;error_count<=0;p0<=0;p1<=0;p2<=0;p3<=0; end
 else begin
  if(ce&&error_ready)error_valid<=0;
  if(!checked)begin checked<=1;if(!PARAM_OK)report_error(1);end
  if(emitting&&ce&&m_ready)begin if(out_index==OUT_LAST)begin emitting<=0;out_index<=0;end else out_index<=out_index+1'b1;end
  if(s_valid&&s_ready)begin
   // Early EOL wins even when SOF would otherwise re-anchor this token.
   if(s_eol&&(s_sof||in_index!=IN_LAST))begin in_index<=0;locked<=0;report_error(2);end
   else if(s_sof&&in_index!=0)begin p0<=s_data; in_index<=1;locked<=1;group_sof<=1;group_eol<=0;report_error(3);end
   else if(!locked&&!s_sof)begin in_index<=0;report_error(4);end
   else begin
    case(in_index)0:p0<=s_data;1:p1<=s_data;2:p2<=s_data;3:p3<=s_data;endcase
    if(in_index==0)begin group_sof<=s_sof;locked<=1;end
    if(in_index==IN_LAST)begin in_index<=0;out_index<=0;emitting<=1;group_eol<=s_eol;end
    else in_index<=in_index+1'b1;
   end
  end
 end end
endmodule
