// CSI-2/V4L2 RAW14 payload only; no packet/PHY or Bayer interpolation.
module raw14_unpack #(parameter PIXEL_BITS=14)(
 input wire clk,rst_n,ce,input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[13:0]m_data,output wire m_valid,m_sof,m_eol,input wire m_ready,
 output reg protocol_error,error_valid,input wire error_ready,output reg[7:0]error_code,output reg[31:0]error_count);
 reg[2:0]in_index,out_index;reg emitting,locked,group_sof,group_eol,checked;
 localparam IN_LAST=6,OUT_LAST=3;
 reg[7:0]b0,b1,b2,b3,b4,b5,b6;
 assign m_data=out_index==0?{b0,b4[5:0]}:out_index==1?{b1,b5[3:0],b4[7:6]}:out_index==2?{b2,b6[1:0],b5[7:4]}:{b3,b6[7:2]};

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
 if(!rst_n)begin in_index<=0;out_index<=0;emitting<=0;locked<=0;group_sof<=0;group_eol<=0;checked<=0;protocol_error<=0;error_valid<=0;error_code<=0;error_count<=0;b0<=0;b1<=0;b2<=0;b3<=0;b4<=0;b5<=0;b6<=0; end
 else begin
  if(ce&&error_ready)error_valid<=0;
  if(!checked)begin checked<=1;if(!PARAM_OK)report_error(1);end
  if(emitting&&ce&&m_ready)begin if(out_index==OUT_LAST)begin emitting<=0;out_index<=0;end else out_index<=out_index+1'b1;end
  if(s_valid&&s_ready)begin
   // Early EOL wins even when SOF would otherwise re-anchor this token.
   if(s_eol&&(s_sof||in_index!=IN_LAST))begin in_index<=0;locked<=0;report_error(2);end
   else if(s_sof&&in_index!=0)begin b0<=s_data; in_index<=1;locked<=1;group_sof<=1;group_eol<=0;report_error(3);end
   else if(!locked&&!s_sof)begin in_index<=0;report_error(4);end
   else begin
    case(in_index)0:b0<=s_data;1:b1<=s_data;2:b2<=s_data;3:b3<=s_data;4:b4<=s_data;5:b5<=s_data;6:b6<=s_data;endcase
    if(in_index==0)begin group_sof<=s_sof;locked<=1;end
    if(in_index==IN_LAST)begin in_index<=0;out_index<=0;emitting<=1;group_eol<=s_eol;end
    else in_index<=in_index+1'b1;
   end
  end
 end end
endmodule
