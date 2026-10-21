// Min/max common-mode space-vector duty generation. One elastic output beat.
module svpwm_duty(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire signed [11:0] alpha,beta,input wire [15:0] period,
 input wire [31:0] sample_id,
 output reg m_valid,input wire m_ready,
 output reg [15:0] duty_u,duty_v,duty_w,output reg [15:0] m_period,
 output reg [1:0] error,output reg [31:0] m_sample_id
);
wire signed [23:0] root_product=$signed(beta)*24'sd1774;
wire signed [23:0] alpha_scaled=$signed(alpha)*24'sd1024;
wire signed [23:0] bv=(-alpha_scaled+root_product+24'sd1024)>>>11;
wire signed [23:0] cv=(-alpha_scaled-root_product+24'sd1024)>>>11;
wire signed [13:0] u={{2{alpha[11]}},alpha},v=bv[13:0],w=cv[13:0];
wire signed [13:0] maximum=u>v?(u>w?u:w):(v>w?v:w);
wire signed [13:0] minimum=u<v?(u<w?u:w):(v<w?v:w);
wire signed [14:0] common=($signed({maximum[13],maximum})+$signed({minimum[13],minimum}))>>>1;
wire signed [14:0] cu=$signed({u[13],u})-common;
wire signed [14:0] c_v=$signed({v[13],v})-common;
wire signed [14:0] cw=$signed({w[13],w})-common;
wire overmod=cu>1024||cu< -1024||c_v>1024||c_v< -1024||cw>1024||cw< -1024;
function [15:0] duty;
 input signed [14:0] centered;input [15:0] ticks;
 reg [11:0] shifted;reg [28:0] scaled;
 begin
  if(centered<= -1024)duty=0;
  else if(centered>=1024)duty=ticks;
  else begin shifted=centered+15'sd1024;scaled=shifted*ticks+29'd1024;duty=scaled>>11;end
 end
endfunction
assign s_ready=rst_n&&(!m_valid||m_ready);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin m_valid<=0;duty_u<=0;duty_v<=0;duty_w<=0;m_period<=0;error<=0;m_sample_id<=0;end
 else if(s_ready)begin
  m_valid<=s_valid;
  if(s_valid)begin
   m_period<=period;m_sample_id<=sample_id;error<={overmod,period<4};
   duty_u<=period<4?0:duty(cu,period);duty_v<=period<4?0:duty(c_v,period);duty_w<=period<4?0:duty(cw,period);
  end
 end
end
endmodule
