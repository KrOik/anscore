module farrow_cubic_stream (
 input wire clk,rst_n,input wire signed[15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output wire signed[15:0] m_tdata,output wire m_tvalid,input wire m_tready,output wire m_tuser,
 input wire cfg_valid,output wire cfg_ready,input wire[5:0] cfg_delay,input wire[12:0] cfg_mu,
 input wire cfg_clear,output reg cfg_done,cfg_error
);
 reg[4:0] delay;reg[12:0] mu;reg[5:0] used;
 reg signed[15:0] history[0:33];
 reg[4:0] valid;wire advance=!valid[4] || m_tready;
 assign cfg_ready=rst_n && valid==0;
 assign s_tready=rst_n && advance && !cfg_valid;
 assign m_tvalid=valid[4];
 reg signed[15:0] result;reg clipped;
 assign m_tdata=result;assign m_tuser=clipped;
 wire signed[19:0] a=delay==0 ? s_tdata : (delay<=used ? history[delay-1'b1] : 16'sd0);
 wire signed[19:0] b=delay<used ? history[delay] : 16'sd0;
 wire signed[19:0] c=delay+1<used ? history[delay+1] : 16'sd0;
 wire signed[19:0] d=delay+2<used ? history[delay+2] : 16'sd0;
 wire signed[19:0] a0=b<<<1,a1=c-a,a2=(a<<<1)-(b<<<2)-b+(c<<<2)-d,a3=-a+(b<<<1)+b-(c<<<1)-c+d;
 reg signed[28:0] h0,h1,h2,h3,b10,b11,b12,b20,b21,b30;
 reg[12:0] u0,u1,u2;
 // Explicit balanced logic multiplier: no Verilog multiply operator.
 function signed[41:0] logic_product;
 input signed[28:0] x;input[12:0] u;
 reg signed[41:0] p[0:15];integer j,k;
 begin
  for(j=0;j<16;j=j+1)begin
   p[j]=0;
   if(j<13)if(u[j])p[j]=$signed({{13{x[28]}},x})<<<j;
  end
  for(k=8;k>=1;k=k/2)for(j=0;j<k;j=j+1)p[j]=p[2*j]+p[2*j+1];
  logic_product=p[0];
 end
 endfunction
 function signed[28:0] mul_round;
 input signed[28:0] x;input[12:0] u;
 reg signed[41:0] p;reg signed[29:0] q;
 begin p=logic_product(x,u);q=p>>>12;if(p[11:0]>2048 || (p[11:0]==2048 && q[0]))q=q+1;mul_round=q[28:0];end
 endfunction
 wire signed[28:0] final_q=h3>>>9;
 wire signed[28:0] final_r=final_q+((h3[8:0]>256 || (h3[8:0]==256 && final_q[0])) ? 29'sd1:29'sd0);
 integer i;
 always @(posedge clk)begin
  if(!rst_n)begin
   delay<=0;mu<=0;used<=0;valid<=0;result<=0;clipped<=0;cfg_done<=0;cfg_error<=0;
   h0<=0;h1<=0;h2<=0;h3<=0;b10<=0;b11<=0;b12<=0;b20<=0;b21<=0;b30<=0;u0<=0;u1<=0;u2<=0;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(cfg_valid && cfg_ready)begin
    cfg_done<=1;
    if(cfg_delay>31 || cfg_mu>4096)cfg_error<=1;
    else begin delay<=cfg_delay[4:0];mu<=cfg_mu;if(cfg_clear)used<=0;end
   end
   if(advance)begin
    valid<={valid[3:0],s_tvalid && s_tready};
    if(s_tvalid && s_tready)begin
     h0<=$signed(a3)<<<8;b10<=$signed(a2)<<<8;b11<=$signed(a1)<<<8;b12<=$signed(a0)<<<8;u0<=mu;
     history[0]<=s_tdata;for(i=1;i<34;i=i+1)history[i]<=history[i-1];if(used<34)used<=used+1'b1;
    end
    if(valid[0])begin h1<=mul_round(h0,u0)+b10;b20<=b11;b21<=b12;u1<=u0;end
    if(valid[1])begin h2<=mul_round(h1,u1)+b20;b30<=b21;u2<=u1;end
    if(valid[2])h3<=mul_round(h2,u2)+b30;
    if(valid[3])begin result<=final_r>32767 ? 16'sh7fff : final_r < -32768 ? 16'sh8000 : final_r[15:0];clipped<=final_r>32767 || final_r < -32768;end
   end
  end
 end
endmodule
