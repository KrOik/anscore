// Store-and-forward IPv4/UDP receive. Input Ethernet frame has no preamble/FCS.
// No IP options, fragments or VLAN. UDP checksum zero is legal for IPv4.
module udp_payload_rx #(
 parameter [47:0] MAC=48'h0600aabb0cdd,
 parameter [31:0] IP=32'hc0a8890f,parameter [15:0] PORT=11452
)(
 input wire clk,rst_n,s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,input wire [95:0] s_user,
 output wire m_valid,input wire m_ready,output reg [7:0] m_data,
 output wire m_keep,m_last,output wire [95:0] m_user,
 output wire [31:0] source_ip,output wire [15:0] source_port,
 output reg [31:0] good,bad_header,bad_ip_checksum,bad_udp_checksum
);
 localparam RECEIVE=0,CHECK=1,FETCH=2,LATCH=3,OFFER=4;
 reg[2:0] state;reg[7:0] mem[0:2047];reg[7:0] q,high_byte;
 reg[10:0] index,frame_length,address,payload_length;
 reg malformed;reg[95:0] metadata;
 reg[47:0] dst_mac;reg[31:0] src_ip,dst_ip;
 reg[15:0] ethertype,ip_length,fragment,udp_length,dst_port,src_port,udp_check;
 reg[7:0] version_ihl,protocol;
 reg[31:0] ip_sum,udp_sum,pseudo_sum;
 function[15:0] fold(input[31:0] x);reg[31:0] a,b;
 begin a={16'd0,x[15:0]}+{16'd0,x[31:16]};b={16'd0,a[15:0]}+{16'd0,a[31:16]};fold=b[15:0];end endfunction
 assign s_ready=rst_n&&state==RECEIVE;
 assign m_valid=rst_n&&state==OFFER;
 assign m_keep=payload_length!=0;
 assign m_last=payload_length==0||address==41+payload_length;
 assign m_user=metadata;
 assign source_ip=src_ip;assign source_port=src_port;
 wire header_ok=!malformed&&frame_length>=42&&frame_length<=1514&&
  (dst_mac==MAC||dst_mac==48'hffffffffffff)&&ethertype==16'h0800&&
  version_ihl==8'h45&&protocol==17&&dst_ip==IP&&dst_port==PORT&&
  (fragment&16'h3fff)==0&&udp_length>=8&&ip_length==udp_length+20&&
  ip_length<=1500&&frame_length>=ip_length+14;
 always @(posedge clk)begin
  if(s_valid&&s_ready&&index<2048)mem[index]<=s_data;
  q<=mem[address];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=RECEIVE;index<=0;frame_length<=0;address<=0;payload_length<=0;
   malformed<=0;metadata<=0;dst_mac<=0;src_ip<=0;dst_ip<=0;
   ethertype<=0;ip_length<=0;fragment<=0;udp_length<=0;dst_port<=0;src_port<=0;udp_check<=0;
   version_ihl<=0;protocol<=0;ip_sum<=0;udp_sum<=0;pseudo_sum<=0;high_byte<=0;m_data<=0;
   good<=0;bad_header<=0;bad_ip_checksum<=0;bad_udp_checksum<=0;
  end else case(state)
   RECEIVE:if(s_valid)begin
    if(index==0)begin
     metadata<=s_user;malformed<=!s_keep;dst_mac<=s_data;
     ip_sum<=0;udp_sum<=0;pseudo_sum<=0;
    end else begin
     if(!s_keep||s_user!=metadata||index>=1514)malformed<=1;
     if(index<6)dst_mac<={dst_mac[39:0],s_data};
    end
    case(index)
     12:ethertype[15:8]<=s_data;13:ethertype[7:0]<=s_data;
     14:version_ihl<=s_data;16:ip_length[15:8]<=s_data;17:ip_length[7:0]<=s_data;
     20:fragment[15:8]<=s_data;21:fragment[7:0]<=s_data;23:protocol<=s_data;
     34:src_port[15:8]<=s_data;35:src_port[7:0]<=s_data;
     36:dst_port[15:8]<=s_data;37:dst_port[7:0]<=s_data;
     38:udp_length[15:8]<=s_data;39:udp_length[7:0]<=s_data;
     40:udp_check[15:8]<=s_data;41:udp_check[7:0]<=s_data;
    endcase
    if(index>=26&&index<30)src_ip<={src_ip[23:0],s_data};
    if(index>=30&&index<34)dst_ip<={dst_ip[23:0],s_data};
    if(!index[0])high_byte<=s_data;
    if(index>=14&&index<34&&index[0])ip_sum<=ip_sum+{high_byte,s_data};
    if(index>=26&&index<34&&index[0])pseudo_sum<=pseudo_sum+{high_byte,s_data};
    if(index>=34&&(index<40||index<34+udp_length))begin
     if(index[0])udp_sum<=udp_sum+{high_byte,s_data};
     else if(index==33+udp_length)udp_sum<=udp_sum+{s_data,8'd0};
    end
    if(s_last)begin frame_length<=index+1'b1;index<=0;state<=CHECK;end
    else if(index!=2047)index<=index+1'b1;
   end
   CHECK:begin
    if(!header_ok)begin bad_header<=bad_header+1'b1;state<=RECEIVE;end
    else if(fold(ip_sum)!=16'hffff)begin bad_ip_checksum<=bad_ip_checksum+1'b1;state<=RECEIVE;end
    else if(udp_check!=0&&fold(udp_sum+pseudo_sum+udp_length+17)!=16'hffff)begin
     bad_udp_checksum<=bad_udp_checksum+1'b1;state<=RECEIVE;
    end else begin
     good<=good+1'b1;payload_length<=udp_length-8;address<=42;
     if(udp_length==8)begin m_data<=0;state<=OFFER;end else state<=FETCH;
    end
   end
   FETCH:state<=LATCH;
   LATCH:begin m_data<=q;state<=OFFER;end
   OFFER:if(m_ready)begin
    if(m_last)state<=RECEIVE;else begin address<=address+1'b1;state<=FETCH;end
   end
  endcase
 end
endmodule
