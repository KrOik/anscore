// Buffered UDP payload -> EthernetII/IPv4/UDP frame (no preamble or FCS).
// A command owns one payload. Empty payload commands require no input beat.
module udp_frame_tx #(
 parameter [47:0] MAC=48'h0600aabb0cdd,
 parameter [31:0] IP=32'hc0a8890f
)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [47:0] cmd_dst_mac,input wire [31:0] cmd_dst_ip,
 input wire [15:0] cmd_src_port,cmd_dst_port,cmd_length,cmd_ip_id,
 input wire [95:0] cmd_user,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,
 output wire m_valid,input wire m_ready,output reg [7:0] m_data,
 output wire m_keep,m_last,output wire [95:0] m_user,
 output wire done_valid,input wire done_ready,output reg [1:0] done_error
);
 localparam IDLE=0,LOAD=1,CHECK=2,FETCH=3,LATCH=4,OFFER=5,DRAIN=6,DONE=7;
 reg[2:0] state;reg[47:0] dst_mac;reg[31:0] dst_ip;
 reg[15:0] src_port,dst_port,length,ip_id,ip_check,udp_check;
 reg[95:0] metadata;reg[10:0] count,index,frame_length;
 reg[7:0] mem[0:2047],q,high_byte;reg[31:0] payload_sum;
 wire[15:0] udp_length=length+8,ip_length=length+28;
 wire[10:0] read_address=index-11'd42;
 function[15:0] fold(input[31:0] x);reg[31:0] a,b;
 begin a={16'd0,x[15:0]}+{16'd0,x[31:16]};b={16'd0,a[15:0]}+{16'd0,a[31:16]};fold=b[15:0];end endfunction
 wire[15:0] udp_complement=~fold(payload_sum+IP[31:16]+IP[15:0]+dst_ip[31:16]+dst_ip[15:0]+17+udp_length+src_port+dst_port+udp_length);
 assign cmd_ready=rst_n&&state==IDLE;
 assign s_ready=rst_n&&(state==LOAD||state==DRAIN);
 assign m_valid=rst_n&&state==OFFER;
 assign m_keep=1'b1;assign m_last=index==frame_length-1'b1;
 assign m_user=metadata;assign done_valid=rst_n&&state==DONE;
 always @(posedge clk)begin
  if(state==LOAD&&s_valid)mem[count]<=s_data;
  q<=mem[read_address];
 end
 reg[7:0] header;
 always @*begin
  header=0;
  if(index<6)header=dst_mac>>(8*(5-index));
  else if(index<12)header=MAC>>(8*(11-index));
  else case(index)
   12:header=8'h08;13:header=0;14:header=8'h45;15:header=0;
   16:header=ip_length[15:8];17:header=ip_length[7:0];
   18:header=ip_id[15:8];19:header=ip_id[7:0];20:header=8'h40;21:header=0;
   22:header=64;23:header=17;24:header=ip_check[15:8];25:header=ip_check[7:0];
   26:header=IP[31:24];27:header=IP[23:16];28:header=IP[15:8];29:header=IP[7:0];
   30:header=dst_ip[31:24];31:header=dst_ip[23:16];32:header=dst_ip[15:8];33:header=dst_ip[7:0];
   34:header=src_port[15:8];35:header=src_port[7:0];36:header=dst_port[15:8];37:header=dst_port[7:0];
   38:header=udp_length[15:8];39:header=udp_length[7:0];40:header=udp_check[15:8];41:header=udp_check[7:0];
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;dst_mac<=0;dst_ip<=0;src_port<=0;dst_port<=0;length<=0;
   ip_id<=0;ip_check<=0;udp_check<=0;metadata<=0;count<=0;index<=0;frame_length<=0;
   high_byte<=0;payload_sum<=0;m_data<=0;done_error<=0;end
  else case(state)
   IDLE:if(cmd_valid)begin
    dst_mac<=cmd_dst_mac;dst_ip<=cmd_dst_ip;src_port<=cmd_src_port;dst_port<=cmd_dst_port;
    length<=cmd_length;ip_id<=cmd_ip_id;metadata<=cmd_user;count<=0;index<=0;payload_sum<=0;done_error<=0;
    if(cmd_length>1472)begin done_error<=1;state<=DONE;end
    else if(cmd_length==0)state<=CHECK;else state<=LOAD;
   end
   LOAD:if(s_valid)begin
    if(!s_keep||s_last!=(count==length-1'b1))begin
     done_error<=2;state<=s_last?DONE:DRAIN;
    end else begin
     if(count[0])payload_sum<=payload_sum+{high_byte,s_data};
     else begin high_byte<=s_data;if(s_last)payload_sum<=payload_sum+{s_data,8'd0};end
     count<=count+1'b1;if(s_last)state<=CHECK;
    end
   end
   DRAIN:if(s_valid&&s_last)state<=DONE;
   CHECK:begin
    ip_check<=~fold(32'h4500+ip_length+ip_id+32'h4000+32'h4011+IP[31:16]+IP[15:0]+dst_ip[31:16]+dst_ip[15:0]);
    udp_check<=udp_complement==0?16'hffff:udp_complement;
    frame_length<=length+42<60?60:length+42;state<=FETCH;
   end
   FETCH:state<=LATCH;
   LATCH:begin m_data<=index>=42&&index<length+42?q:header;state<=OFFER;end
   OFFER:if(m_ready)begin if(m_last)state<=DONE;else begin index<=index+1'b1;state<=FETCH;end end
   DONE:if(done_ready)state<=IDLE;
  endcase
 end
endmodule
