// Linux Bayer16 payload little endian by default; complete16-bit sample buffer.
module raw16_pack #(parameter PIXEL_BITS=16,BIG_ENDIAN=0)(
 input wire clk,rst_n,ce,input wire[15:0]s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire[7:0]m_data,output wire m_valid,m_sof,m_eol,input wire m_ready,
 output reg protocol_error,error_valid,input wire error_ready,output reg[7:0]error_code,output reg[31:0]error_count);
 localparam PARAM_OK=PIXEL_BITS==16&&(BIG_ENDIAN==0||BIG_ENDIAN==1);
 reg[15:0]pixel;reg valid,byte_index,sof,eol,locked,checked;
 wire consume=ce&&m_ready&&valid;
 assign s_ready=rst_n&&ce&&PARAM_OK&&(!valid||(consume&&byte_index));
 assign m_valid=valid;assign m_data=(byte_index^BIG_ENDIAN)?pixel[15:8]:pixel[7:0];
 assign m_sof=valid&&sof&&!byte_index;assign m_eol=valid&&eol&&byte_index;
 task report_error;input[7:0]code;begin protocol_error<=1;if(error_count!=32'hffffffff)error_count<=error_count+1'b1;
 if(!error_valid||(ce&&error_ready))begin error_valid<=1;error_code<=code;end end endtask
 always @(posedge clk)begin
 if(!rst_n)begin pixel<=0;valid<=0;byte_index<=0;sof<=0;eol<=0;locked<=0;checked<=0;protocol_error<=0;error_valid<=0;error_code<=0;error_count<=0;end
 else begin
 if(ce&&error_ready)error_valid<=0;
 if(!checked)begin checked<=1;if(!PARAM_OK)report_error(1);end
 if(consume)begin if(byte_index)begin valid<=0;byte_index<=0;end else byte_index<=1;end
 if(s_valid&&s_ready)begin
 if(!locked&&!s_sof)report_error(4);
 else begin pixel<=s_data;valid<=1;byte_index<=0;sof<=s_sof;eol<=s_eol;locked<=1;end
 end
 end end
endmodule
