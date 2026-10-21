// Frame-aware byte-pair unpacker; an incomplete sample never becomes visible.
module raw16_unpack #(parameter PIXEL_BITS=16,BIG_ENDIAN=0)(
 input wire clk,rst_n,ce,input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg[15:0]m_data,output reg m_valid,m_sof,m_eol,input wire m_ready,
 output reg protocol_error,error_valid,input wire error_ready,output reg[7:0]error_code,output reg[31:0]error_count);
 localparam PARAM_OK=PIXEL_BITS==16&&(BIG_ENDIAN==0||BIG_ENDIAN==1);
 reg[7:0]first_byte;reg has_first,group_sof,locked,checked;
 assign s_ready=rst_n&&ce&&PARAM_OK&&(!m_valid||m_ready);
 task report_error;input[7:0]code;begin protocol_error<=1;if(error_count!=32'hffffffff)error_count<=error_count+1'b1;
 if(!error_valid||(ce&&error_ready))begin error_valid<=1;error_code<=code;end end endtask
 always @(posedge clk)begin
 if(!rst_n)begin first_byte<=0;has_first<=0;group_sof<=0;locked<=0;checked<=0;m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;protocol_error<=0;error_valid<=0;error_code<=0;error_count<=0;end
 else begin
 if(ce&&error_ready)error_valid<=0;
 if(!checked)begin checked<=1;if(!PARAM_OK)report_error(1);end
 if(ce&&m_ready&&m_valid)m_valid<=0;
 if(s_valid&&s_ready)begin
 if(s_eol&&(!has_first||s_sof))begin has_first<=0;locked<=0;report_error(2);end
 else if(s_sof&&has_first)begin first_byte<=s_data;has_first<=1;group_sof<=1;locked<=1;report_error(3);end
 else if(!locked&&!s_sof)begin has_first<=0;report_error(4);end
 else if(!has_first)begin first_byte<=s_data;has_first<=1;group_sof<=s_sof;locked<=1;end
 else begin m_data<=BIG_ENDIAN?{first_byte,s_data}:{s_data,first_byte};m_valid<=1;m_sof<=group_sof;m_eol<=s_eol;has_first<=0;end
 end
 end end
endmodule
