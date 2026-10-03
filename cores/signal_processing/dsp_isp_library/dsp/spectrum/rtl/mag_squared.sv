// DSP-05 complex magnitude squared: paired {i,q} signed16 -> unsigned32 power.
// s_tdata[15:0]=I, s_tdata[31:16]=Q. II=1 global-stall pipeline.
// power = RNE(i*i+q*q, 2**cfg_shift), saturated to unsigned32 (unreachable
// for signed16 inputs; flag retained for contract uniformity).
module mag_squared(
 input wire clk,rst_n,
 input wire [31:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [31:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [4:0] cfg_shift,
 output reg cfg_done,output reg cfg_error
);
 reg [4:0] shift;
 reg v1,v2,v3;
 reg signed [15:0] i1,q1;
 reg [4:0] sh1,sh2,sh3;
 reg [31:0] i2,q2;
 reg [32:0] p3;
 wire pipe_active=v1|v2|v3;
 wire advance=rst_n && (!m_tvalid || m_tready);
 assign s_tready=advance && !cfg_valid;
 assign cfg_ready=rst_n && !m_tvalid && !pipe_active;
 wire s_fire=s_tvalid && s_tready;
 function [32:0] rshift_rne;
  input [32:0] v;input [4:0] k;
  reg [32:0] q,rem,half;
  begin
   q=v>>k;rem=v&((33'd1<<k)-33'd1);half=(k!=0)?(33'd1<<(k-1'b1)):33'd0;
   if(k!=0 && (rem>half || (rem==half && q[0])))q=q+33'd1;
   rshift_rne=q;
  end
 endfunction
 wire [32:0] oq=rshift_rne(p3,sh3);
 always @(posedge clk) begin
  if(!rst_n) begin
   shift<=0;v1<=0;v2<=0;v3<=0;i1<=0;q1<=0;sh1<=0;sh2<=0;sh3<=0;
   i2<=0;q2<=0;p3<=0;
   m_tdata<=0;m_tuser<=0;m_tvalid<=0;cfg_done<=0;cfg_error<=0;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(advance) begin
    m_tvalid<=v3;
    if(v3)begin
     m_tdata<=oq>33'd4294967295 ? 32'hffffffff : oq[31:0];
     m_tuser<=oq>33'd4294967295;
    end
    v3<=v2;
    if(v2)begin p3<={1'b0,i2}+{1'b0,q2};sh3<=sh2;end
    v2<=v1;
    if(v1)begin i2<=i1*i1;q2<=q1*q1;sh2<=sh1;end
    v1<=s_fire;
    if(s_fire)begin i1<=s_tdata[15:0];q1<=s_tdata[31:16];sh1<=shift;end
   end
   if(cfg_valid && cfg_ready) begin
    cfg_done<=1;
    if(cfg_shift>5'd15)cfg_error<=1;
    else shift<=cfg_shift;
   end
  end
 end
endmodule
