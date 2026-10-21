// Store complete60..1514-byte Ethernet frame, then send uninterrupted RMII.
// Input excludes preamble/FCS.50MHz common clock,100Mbps dibits,96bit IFG.
module rmii_frame_tx(
 input wire clk,rst_n,s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,input wire [95:0] s_user,
 output wire txen,output wire [1:0] txd,
 output wire done_valid,input wire done_ready,output reg [1:0] done_error,
 output reg [95:0] done_user,output reg [31:0] sent_frames,sent_bytes
);
 localparam LOAD=0,PRE=1,DATA=2,FCS=3,GAP=4,DONE=5,DRAIN=6;
 reg[2:0] state;reg[7:0] mem[0:2047],q,byte_data;
 reg[10:0] count,length,address,index;
 reg[1:0] dibit;reg[2:0] prebyte;reg[3:0] fcs_dibit;reg[5:0] gap_count;
 reg[31:0] crc,fcs;
 function[31:0] crcbyte(input[31:0] c,input[7:0] b);reg[31:0] x;integer j;
 begin x=c;for(j=0;j<8;j=j+1)x=(x[0]^b[j])?(x>>1)^32'hedb88320:x>>1;crcbyte=x;end endfunction
 wire[7:0] preamble=prebyte==7?8'hd5:8'h55;
 assign s_ready=rst_n&&(state==LOAD||state==DRAIN);
 assign txen=rst_n&&(state==PRE||state==DATA||state==FCS);
 assign txd=state==PRE?(preamble>>(2*dibit)):
  state==DATA?(byte_data>>(2*dibit)):state==FCS?(fcs>>(2*fcs_dibit)):2'd0;
 assign done_valid=rst_n&&state==DONE;
 always @(posedge clk)begin
  if(state==LOAD&&s_valid)mem[count]<=s_data;
  q<=mem[address];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=LOAD;count<=0;length<=0;address<=0;index<=0;
   dibit<=0;prebyte<=0;fcs_dibit<=0;gap_count<=0;crc<=32'hffffffff;fcs<=0;
   byte_data<=0;done_error<=0;done_user<=0;sent_frames<=0;sent_bytes<=0;end
  else case(state)
   LOAD:if(s_valid)begin
    if(count==0)done_user<=s_user;
    if(!s_keep||(count!=0&&s_user!=done_user)||count>=1514)begin
     done_error<=2;state<=s_last?DONE:DRAIN;
    end else if(s_last)begin
     length<=count+1'b1;
     if(count<59)begin done_error<=1;state<=DONE;end
     else begin
      prebyte<=0;dibit<=0;address<=0;index<=0;crc<=32'hffffffff;state<=PRE;
     end
    end else count<=count+1'b1;
   end
   DRAIN:if(s_valid&&s_last)state<=DONE;
   PRE:begin
    dibit<=dibit+1'b1;
    if(dibit==3)begin
     if(prebyte==7)begin byte_data<=q;address<=1;state<=DATA;end
     else prebyte<=prebyte+1'b1;
    end
   end
   DATA:begin
    dibit<=dibit+1'b1;
    if(dibit==3)begin
     crc<=crcbyte(crc,byte_data);
     if(index==length-1'b1)begin fcs<=~crcbyte(crc,byte_data);fcs_dibit<=0;state<=FCS;end
     else begin index<=index+1'b1;byte_data<=q;address<=address+1'b1;end
    end
   end
   FCS:if(fcs_dibit==15)begin
    state<=GAP;gap_count<=0;sent_frames<=sent_frames+1'b1;sent_bytes<=sent_bytes+length;
   end else fcs_dibit<=fcs_dibit+1'b1;
   GAP:if(gap_count==47)state<=DONE;else gap_count<=gap_count+1'b1;
   DONE:if(done_ready)begin state<=LOAD;count<=0;done_error<=0;end
  endcase
 end
endmodule
