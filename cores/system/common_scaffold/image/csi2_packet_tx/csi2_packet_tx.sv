// CSI-2 legacy VC packet byte transmitter. Output is provisional until DONE.
module csi2_packet_tx(
 input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire [1:0] cfg_vc,input wire [5:0] cfg_dt,
 input wire [15:0] cfg_word_count,input wire abort,
 input wire [7:0] s_data,input wire s_valid,s_last,output wire s_ready,
 output reg [7:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_last,done_valid,input wire done_ready,
 output reg done_error,output reg [7:0] error_code,
 output wire busy,output reg [31:0] output_bytes
);
 localparam IDLE=0,HEADER=1,LOAD=2,PAYLOAD=3,CRC_LO=4,CRC_HI=5,DONE=6;
 reg [2:0] state;
 reg [23:0] header;
 reg [1:0] hi;
 reg short_packet;
 reg [15:0] remaining,crc;
 reg[7:0]payload;
 function [5:0] ecc;
 input [23:0] d;
 begin
 ecc[0]=^(d&24'hf12cb7);ecc[1]=^(d&24'hf2555b);
 ecc[2]=^(d&24'h749a6d);ecc[3]=^(d&24'hb8e38e);
 ecc[4]=^(d&24'hdf03f0);ecc[5]=^(d&24'heffc00);
 end endfunction
 function [15:0] crc_byte;
 input [15:0] c;input [7:0] d;reg[15:0]t;integer i;
 begin t=c;for(i=0;i<8;i=i+1)t=(t[0]^d[i])?((t>>1)^16'h8408):(t>>1);crc_byte=t;end
 endfunction
 assign start_ready=state==IDLE;
 assign busy=state!=IDLE;
 assign s_ready=state==LOAD;
 assign m_valid=state==HEADER||state==PAYLOAD||state==CRC_LO||state==CRC_HI;
 assign m_sof=state==HEADER&&hi==0;
 assign m_last=(state==HEADER&&hi==3&&short_packet)||state==CRC_HI;
 assign done_valid=state==DONE;
 always @*begin
 m_data=0;
 case(state)
 HEADER:case(hi)0:m_data=header[7:0];1:m_data=header[15:8];2:m_data=header[23:16];3:m_data={2'b00,ecc(header)};endcase
 PAYLOAD:m_data=payload;
 CRC_LO:m_data=crc[7:0];CRC_HI:m_data=crc[15:8];
 default:m_data=0;
 endcase
 end
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;header<=0;hi<=0;short_packet<=0;remaining<=0;crc<=16'hffff;
 payload<=0;done_error<=0;error_code<=0;output_bytes<=0;
 end else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DONE;done_error<=1;error_code<=3;end
 else case(state)
 IDLE:if(start_valid)begin
 header<={cfg_word_count,cfg_vc,cfg_dt};hi<=0;short_packet<=cfg_dt<16;
 remaining<=cfg_word_count;crc<=16'hffff;output_bytes<=0;done_error<=0;error_code<=0;
 if(cfg_dt>=4&&cfg_dt<=7)begin state<=DONE;done_error<=1;error_code<=1;end
 else state<=HEADER;
 end
 HEADER:if(m_ready)begin
 output_bytes<=output_bytes+1'b1;
 if(hi!=3)hi<=hi+1'b1;
 else if(short_packet)state<=DONE;
 else if(remaining==0)state<=CRC_LO;
 else state<=LOAD;
 end
 LOAD:if(s_valid)begin
 if(s_last!=(remaining==1))begin state<=DONE;done_error<=1;error_code<=2;end
 else begin payload<=s_data;crc<=crc_byte(crc,s_data);state<=PAYLOAD;end
 end
 PAYLOAD:if(m_ready)begin
 output_bytes<=output_bytes+1'b1;remaining<=remaining-1'b1;
 if(remaining==1)state<=CRC_LO;else state<=LOAD;
 end
 CRC_LO:if(m_ready)begin output_bytes<=output_bytes+1'b1;state<=CRC_HI;end
 CRC_HI:if(m_ready)begin output_bytes<=output_bytes+1'b1;state<=DONE;end
 DONE:if(done_ready)state<=IDLE;
 default:state<=IDLE;
 endcase
 end
 end
endmodule
