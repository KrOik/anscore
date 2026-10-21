// CSI-2 legacy two-bit VC byte-stream packet receiver. No physical D-PHY.
// Long-packet payload is PROVISIONAL until its successful packet report.
// Every handshake requires ce. Reset has priority over ce. See README.md.
module csi2_packet_rx #(
 parameter integer MAX_WORD_COUNT=4096
)(
 input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire cfg_check_sequence,abort,
 input wire [7:0] s_data,input wire s_valid,s_last,output wire s_ready,
 output wire h_valid,input wire h_ready,
 output reg [1:0] h_vc,output reg [5:0] h_dt,
 output reg [15:0] h_word_count,output reg h_short,h_corrected,
 output wire [7:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_first,m_last,output wire [1:0] m_vc,output wire [5:0] m_dt,
 output wire p_valid,input wire p_ready,
 output reg p_error,output reg [7:0] p_error_code,
 output reg p_header_valid,output wire [1:0] p_vc,output wire [5:0] p_dt,
 output wire [15:0] p_word_count,output wire p_short,p_corrected,
 output reg [15:0] p_payload_bytes,p_crc_calculated,p_crc_received,
 output reg p_last,
 output wire done_valid,input wire done_ready,
 output reg done_error,output reg [7:0] error_code,output wire busy,
 output reg [31:0] packet_count,corrected_count,crc_error_count,
 output reg [3:0] frame_active,line_active
);
 localparam IDLE=0,HEADER=1,CHECK=2,HEADER_OUT=3,PAYLOAD=4,
 CRC_LO=5,CRC_HI=6,REPORT=7,DONE=8;
 localparam [7:0] BAD_PARAMETER=1,HEADER_ECC=2,ECC_RESERVED=3,
 TRUNCATED=4,WORD_COUNT_LIMIT=5,SHORT_RESERVED=6,SEQUENCE=7,
 PAYLOAD_CRC=8,ABORTED=9;
 reg [3:0] state;
 reg [1:0] header_index;
 reg [31:0] header_bits;
 reg end_seen,sequence_check,fatal_packet,abort_pending;
 reg [15:0] remaining,crc;
 reg [7:0] payload_hold;
 reg payload_valid,payload_first,payload_last;
 reg [15:0] frame_number[0:3],line_number[0:3];
 integer j;
 function [5:0] ecc;
 input [23:0] d;
 begin
 ecc[0]=^(d&24'hf12cb7);
 ecc[1]=^(d&24'hf2555b);
 ecc[2]=^(d&24'h749a6d);
 ecc[3]=^(d&24'hb8e38e);
 ecc[4]=^(d&24'hdf03f0);
 ecc[5]=^(d&24'heffc00);
 end endfunction
 function [15:0] crc_byte;
 input [15:0] old_crc;input [7:0] value;
 reg [15:0] t;integer k;
 begin
 t=old_crc;
 for(k=0;k<8;k=k+1) t=(t[0]^value[k])?((t>>1)^16'h8408):(t>>1);
 crc_byte=t;
 end endfunction
 function [31:0] increment_sat;
 input [31:0] n;
 begin increment_sat=(&n)?n:n+1'b1;end endfunction
 wire [5:0] syndrome=ecc(header_bits[23:0])^header_bits[29:24];
 reg [23:0] repaired;
 reg ecc_correctable;
 integer bit_index;
 always @*begin
 repaired=header_bits[23:0];ecc_correctable=syndrome==0;
 for(bit_index=0;bit_index<24;bit_index=bit_index+1)
 if(syndrome==ecc(24'b1<<bit_index))begin
 repaired[bit_index]=~header_bits[bit_index];ecc_correctable=1;
 end
 for(bit_index=0;bit_index<6;bit_index=bit_index+1)
 if(syndrome==(6'b1<<bit_index))ecc_correctable=1;
 end
 wire [1:0] decoded_vc=repaired[7:6];
 wire [5:0] decoded_dt=repaired[5:0];
 wire [15:0] decoded_wc=repaired[23:8];
 wire decoded_short=decoded_dt<16;
 reg short_sequence_bad;
 always @*begin
 short_sequence_bad=0;
 if(sequence_check)case(h_dt)
 0:short_sequence_bad=frame_active[h_vc]||line_active[h_vc];
 1:short_sequence_bad=!frame_active[h_vc]||line_active[h_vc]||frame_number[h_vc]!=h_word_count;
 2:short_sequence_bad=!frame_active[h_vc]||line_active[h_vc];
 3:short_sequence_bad=!frame_active[h_vc]||!line_active[h_vc]||line_number[h_vc]!=h_word_count;
 default:short_sequence_bad=0;
 endcase
 end
 assign start_ready=rst_n&&!abort&&state==IDLE;
 assign s_ready=rst_n&&!abort&&((state==HEADER)||(state==PAYLOAD&&!payload_valid)||(state==CRC_LO)||(state==CRC_HI));
 assign h_valid=rst_n&&state==HEADER_OUT;
 assign m_valid=rst_n&&payload_valid;
 assign m_data=payload_hold;assign m_first=payload_first;assign m_last=payload_last;
 assign m_vc=h_vc;assign m_dt=h_dt;
 assign p_valid=rst_n&&state==REPORT;
 assign p_vc=h_vc;assign p_dt=h_dt;assign p_word_count=h_word_count;
 assign p_short=h_short;assign p_corrected=h_corrected;
 assign done_valid=rst_n&&state==DONE;
 assign busy=rst_n&&state!=IDLE&&state!=DONE;
 // Abort cancels outstanding payload/header tokens. Their hold contract ends
 // at an accepted abort; a previously visible terminal record is immutable.
 task fail_packet;
 input [7:0] code;
 begin
 p_error<=1;p_error_code<=code;p_last<=1;fatal_packet<=1;
 done_error<=1;if(!done_error)error_code<=code;
 payload_valid<=0;state<=REPORT;
 end endtask
 task finish_short;
 begin
 if(short_sequence_bad)fail_packet(SEQUENCE);
 else begin
 case(h_dt)
 0:begin frame_active[h_vc]<=1;frame_number[h_vc]<=h_word_count;end
 1:frame_active[h_vc]<=0;
 2:begin line_active[h_vc]<=1;line_number[h_vc]<=h_word_count;end
 3:line_active[h_vc]<=0;
 default:begin end
 endcase
 state<=REPORT;
 end
 end endtask
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;header_index<=0;header_bits<=0;end_seen<=0;
 sequence_check<=0;fatal_packet<=0;abort_pending<=0;remaining<=0;crc<=16'hffff;
 payload_hold<=0;payload_valid<=0;payload_first<=0;payload_last<=0;
 h_vc<=0;h_dt<=0;h_word_count<=0;h_short<=0;h_corrected<=0;
 p_error<=0;p_error_code<=0;p_header_valid<=0;p_payload_bytes<=0;
 p_crc_calculated<=0;p_crc_received<=0;p_last<=0;
 done_error<=0;error_code<=0;packet_count<=0;corrected_count<=0;crc_error_count<=0;
 frame_active<=0;line_active<=0;
 for(j=0;j<4;j=j+1)begin frame_number[j]<=0;line_number[j]<=0;end
 end else if(ce)begin
 if(state==IDLE)begin
 if(start_valid&&!abort)begin
 sequence_check<=cfg_check_sequence;header_index<=0;header_bits<=0;end_seen<=0;
 fatal_packet<=0;abort_pending<=0;payload_valid<=0;h_vc<=0;h_dt<=0;h_word_count<=0;h_short<=0;h_corrected<=0;
 p_error<=0;p_error_code<=0;p_header_valid<=0;p_payload_bytes<=0;p_crc_calculated<=0;p_crc_received<=0;p_last<=0;
 done_error<=0;error_code<=0;packet_count<=0;corrected_count<=0;crc_error_count<=0;
 frame_active<=0;line_active<=0;
 if(MAX_WORD_COUNT<0||MAX_WORD_COUNT>65535)begin done_error<=1;error_code<=BAD_PARAMETER;state<=DONE;end
 else state<=HEADER;
 end
 end else if(state==DONE)begin
 if(done_ready)state<=IDLE;
 end else if(state==REPORT)begin
 if(abort)abort_pending<=1;
 if(p_ready)begin
 packet_count<=increment_sat(packet_count);
 if(p_last||fatal_packet)state<=DONE;
 else if(abort||abort_pending)begin done_error<=1;if(!done_error)error_code<=ABORTED;state<=DONE;end
 else begin
 header_index<=0;header_bits<=0;end_seen<=0;fatal_packet<=0;
 h_vc<=0;h_dt<=0;h_word_count<=0;h_short<=0;h_corrected<=0;
 p_error<=0;p_error_code<=0;p_header_valid<=0;p_payload_bytes<=0;
 p_crc_calculated<=0;p_crc_received<=0;p_last<=0;state<=HEADER;
 end
 end
 end else if(abort)fail_packet(ABORTED);
 else case(state)
 HEADER:if(s_valid)begin
 header_bits[header_index*8+:8]<=s_data;
 if(s_last&&header_index!=3)fail_packet(TRUNCATED);
 else if(header_index==3)begin end_seen<=s_last;state<=CHECK;end
 else header_index<=header_index+1'b1;
 end
 CHECK:begin
 if(header_bits[31:30]!=0)fail_packet(ECC_RESERVED);
 else if(!ecc_correctable)fail_packet(HEADER_ECC);
 else begin
 h_vc<=decoded_vc;h_dt<=decoded_dt;h_word_count<=decoded_wc;
 h_short<=decoded_short;h_corrected<=syndrome!=0;p_header_valid<=1;
 if(syndrome!=0)corrected_count<=increment_sat(corrected_count);
 if(decoded_short&&decoded_dt>=4&&decoded_dt<=7)fail_packet(SHORT_RESERVED);
 else if(!decoded_short&&decoded_wc>MAX_WORD_COUNT)fail_packet(WORD_COUNT_LIMIT);
 else begin
 remaining<=decoded_wc;crc<=16'hffff;p_crc_calculated<=decoded_short?16'd0:16'hffff;
 p_last<=end_seen;state<=HEADER_OUT;
 end
 end
 end
 HEADER_OUT:if(h_ready)begin
 if(h_short)finish_short;
 else if(end_seen)fail_packet(TRUNCATED);
 else if(h_word_count==0)state<=CRC_LO;
 else state<=PAYLOAD;
 end
 PAYLOAD:begin
 if(payload_valid)begin
 if(m_ready)begin
 payload_valid<=0;
 if(end_seen)fail_packet(TRUNCATED);
 else if(remaining==0)state<=CRC_LO;
 end
 end else if(s_valid)begin
 payload_hold<=s_data;payload_valid<=1;payload_first<=p_payload_bytes==0;
 payload_last<=remaining==1;remaining<=remaining-1'b1;
 p_payload_bytes<=p_payload_bytes+1'b1;crc<=crc_byte(crc,s_data);
 p_crc_calculated<=crc_byte(crc,s_data);end_seen<=s_last;
 end
 end
 CRC_LO:if(s_valid)begin
 p_crc_received[7:0]<=s_data;p_crc_calculated<=crc;
 if(s_last)fail_packet(TRUNCATED);else state<=CRC_HI;
 end
 CRC_HI:if(s_valid)begin
 p_crc_received[15:8]<=s_data;p_crc_calculated<=crc;p_last<=s_last;
 if({s_data,p_crc_received[7:0]}!=crc)begin
 p_error<=1;p_error_code<=PAYLOAD_CRC;done_error<=1;
 if(!done_error)error_code<=PAYLOAD_CRC;
 crc_error_count<=increment_sat(crc_error_count);
 end
 state<=REPORT;
 end
 default:fail_packet(ABORTED);
 endcase
 end
 end
endmodule
