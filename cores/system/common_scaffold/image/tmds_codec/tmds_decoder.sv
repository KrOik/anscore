// Strict DVI video/control lane decoder. A control token acquires/reacquires lock.
module tmds_decoder(
 input wire clk,rst_n,ce,input wire[9:0]s_symbol,input wire s_valid,output wire s_ready,
 output reg[7:0]m_data,output reg m_de,output reg[1:0]m_control,
 output reg m_error,m_valid,input wire m_ready,
 output reg synchronized,output reg signed[5:0]running_disparity
);
 function[15:0]encode;
 input[7:0]d;input signed[5:0]rd;
 reg[8:0]q;reg[9:0]code;integer n,i,b,next_rd;
 begin
 n=0;for(i=0;i<8;i=i+1)n=n+d[i];q[8]=!(n>4||(n==4&&!d[0]));q[0]=d[0];
 for(i=1;i<8;i=i+1)q[i]=q[8]?(q[i-1]^d[i]):~(q[i-1]^d[i]);
 n=0;for(i=0;i<8;i=i+1)n=n+q[i];b=2*n-8;
 if(rd==0||b==0)begin code={~q[8],q[8],q[8]?q[7:0]:~q[7:0]};next_rd=rd+(q[8]?b:-b);end
 else if((rd>0&&b>0)||(rd<0&&b<0))begin code={1'b1,q[8],~q[7:0]};next_rd=rd+2*q[8]-b;end
 else begin code={1'b0,q[8],q[7:0]};next_rd=rd-2*(1-q[8])+b;end
 encode={next_rd[5:0],code};
 end endfunction
 reg[7:0]q,d;integer i;
 always @*begin
 q=s_symbol[9]?~s_symbol[7:0]:s_symbol[7:0];d[0]=q[0];
 for(i=1;i<8;i=i+1)d[i]=s_symbol[8]?(q[i]^q[i-1]):~(q[i]^q[i-1]);
 end
 wire[15:0]check_code=encode(d,running_disparity);
 wire control=s_symbol==10'b1101010100||s_symbol==10'b0010101011||s_symbol==10'b0101010100||s_symbol==10'b1010101011;
 assign s_ready=!m_valid||m_ready;
 always @(posedge clk)begin
 if(!rst_n)begin m_data<=0;m_de<=0;m_control<=0;m_error<=0;m_valid<=0;synchronized<=0;running_disparity<=0;end
 else if(ce)begin
 if(m_valid&&m_ready)m_valid<=0;
 if(s_valid&&s_ready)begin
 m_valid<=1;m_data<=0;m_de<=0;m_control<=0;m_error<=0;
 if(control)begin
 synchronized<=1;running_disparity<=0;
 case(s_symbol)
 10'b1101010100:m_control<=0;10'b0010101011:m_control<=1;
 10'b0101010100:m_control<=2;10'b1010101011:m_control<=3;
 endcase
 end else if(synchronized&&check_code[9:0]==s_symbol)begin
 m_data<=d;m_de<=1;running_disparity<=check_code[15:10];
 end else begin m_error<=1;synchronized<=0;running_disparity<=0;end
 end
 end
 end
endmodule
