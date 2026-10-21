// DVI video/control TMDS lane, before serialization. CE-qualified elastic stream.
module tmds_encoder(
 input wire clk,rst_n,ce,input wire[7:0]s_data,input wire s_de,
 input wire[1:0]s_control,input wire s_valid,output wire s_ready,
 output reg[9:0]m_symbol,output reg m_valid,input wire m_ready,
 output reg signed[5:0]running_disparity
);
 function[15:0]encode;
 input[7:0]d;input signed[5:0]rd;
 reg[8:0]q;reg[9:0]code;integer n,i,b,next_rd;
 begin
 n=0;for(i=0;i<8;i=i+1)n=n+d[i];
 q[8]=!(n>4||(n==4&&!d[0]));q[0]=d[0];
 for(i=1;i<8;i=i+1)q[i]=q[8]?(q[i-1]^d[i]):~(q[i-1]^d[i]);
 n=0;for(i=0;i<8;i=i+1)n=n+q[i];b=2*n-8;
 if(rd==0||b==0)begin code={~q[8],q[8],q[8]?q[7:0]:~q[7:0]};next_rd=rd+(q[8]?b:-b);end
 else if((rd>0&&b>0)||(rd<0&&b<0))begin code={1'b1,q[8],~q[7:0]};next_rd=rd+2*q[8]-b;end
 else begin code={1'b0,q[8],q[7:0]};next_rd=rd-2*(1-q[8])+b;end
 encode={next_rd[5:0],code};
 end endfunction
 wire[15:0]encoded=encode(s_data,running_disparity);
 assign s_ready=!m_valid||m_ready;
 always @(posedge clk)begin
 if(!rst_n)begin m_valid<=0;m_symbol<=0;running_disparity<=0;end
 else if(ce)begin
 if(m_valid&&m_ready)m_valid<=0;
 if(s_valid&&s_ready)begin
 m_valid<=1;
 if(s_de)begin m_symbol<=encoded[9:0];running_disparity<=encoded[15:10];end
 else begin
 running_disparity<=0;
 case(s_control)
 0:m_symbol<=10'b1101010100;1:m_symbol<=10'b0010101011;
 2:m_symbol<=10'b0101010100;3:m_symbol<=10'b1010101011;
 endcase
 end
 end
 end
 end
endmodule
