// Resource-oriented complete DF-II transposed cascade, 1 shared multiplier.
// II and no-stall output transfer latency = 7*active_sections+1, NOT II=1.
module biquad_sos_stream #(
 parameter integer MAX_SOS=4
) (
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg signed [15:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [2:0] cfg_sections,input wire cfg_clear,
 input wire [90*MAX_SOS-1:0] cfg_coeffs,
 output reg cfg_done,cfg_error
);
 localparam IDLE=0,M0=1,Y=2,M1=3,A1=4,B2=5,A2=6,FINISH=7;
 reg [2:0] phase,active_sections,section;
 reg signed [17:0] b0[0:MAX_SOS-1],b1[0:MAX_SOS-1],b2[0:MAX_SOS-1];
 reg signed [17:0] a1[0:MAX_SOS-1],a2[0:MAX_SOS-1];
 reg signed [35:0] state1[0:MAX_SOS-1],state2[0:MAX_SOS-1];
 reg signed [15:0] x,y;
 reg signed [33:0] product;
 reg signed [35:0] accumulator;
 reg clipped;
 assign cfg_ready=rst_n && phase==IDLE && !m_tvalid;
 assign s_tready=rst_n && phase==IDLE && !cfg_valid && (!m_tvalid || m_tready);
 reg cfg_bad;
 reg signed [19:0] ca1,ca2,jury0,jury1,jury2;
 integer c;
 always @* begin
  cfg_bad=cfg_sections<1 || cfg_sections>MAX_SOS || (!cfg_clear && cfg_sections!=active_sections);
  ca1=0;ca2=0;jury0=0;jury1=0;jury2=0;
  for(c=0;c<MAX_SOS;c=c+1)begin
   ca1=$signed(cfg_coeffs[c*90+54 +:18]);ca2=$signed(cfg_coeffs[c*90+72 +:18]);
   jury0=20'sd32768+ca1+ca2;jury1=20'sd32768-ca1+ca2;jury2=20'sd32768-ca2;
   if(c<cfg_sections && (jury0<32 || jury1<32 || jury2<32))cfg_bad=1;
  end
 end
 reg signed [17:0] mult_coeff;
 reg signed [15:0] mult_sample;
 always @* begin
  mult_coeff=0;mult_sample=x;
  case(phase)
   M0:mult_coeff=b0[section];
   M1:mult_coeff=b1[section];
   A1:begin mult_coeff=a1[section];mult_sample=y;end
   B2:mult_coeff=b2[section];
   A2:begin mult_coeff=a2[section];mult_sample=y;end
  endcase
 end
 wire signed [33:0] multiply=mult_coeff*mult_sample;
 wire signed [35:0] product_wide={{2{product[33]}},product};
 wire signed [35:0] y_accum=product_wide+state1[section];
 function signed [35:0] round_even;
  input signed [35:0] value;
  reg signed [35:0] q;
  begin
   q=value>>>15;
   if(value[14:0]>15'd16384 || (value[14:0]==15'd16384 && q[0]))q=q+36'sd1;
   round_even=q;
  end
 endfunction
 wire signed [35:0] y_round=round_even(y_accum);
 wire y_clips=y_round>32767 || y_round < -32768;
 wire signed [15:0] y_saturated=y_round>32767 ? 16'sh7fff : y_round < -32768 ? 16'sh8000 : y_round[15:0];
 integer i;
 always @(posedge clk)begin
  if(!rst_n)begin
   phase<=IDLE;active_sections<=1;section<=0;x<=0;y<=0;product<=0;accumulator<=0;clipped<=0;
   m_tdata<=0;m_tuser<=0;m_tvalid<=0;cfg_done<=0;cfg_error<=0;
   for(i=0;i<MAX_SOS;i=i+1)begin
    b0[i]<=32768;b1[i]<=0;b2[i]<=0;a1[i]<=0;a2[i]<=0;state1[i]<=0;state2[i]<=0;
   end
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(m_tready)m_tvalid<=0;
   if(cfg_valid && cfg_ready)begin
    cfg_done<=1;
    if(cfg_bad)cfg_error<=1;
    else begin
     active_sections<=cfg_sections;
     for(i=0;i<MAX_SOS;i=i+1)begin
      b0[i]<=cfg_coeffs[i*90 +:18];b1[i]<=cfg_coeffs[i*90+18 +:18];b2[i]<=cfg_coeffs[i*90+36 +:18];
      a1[i]<=cfg_coeffs[i*90+54 +:18];a2[i]<=cfg_coeffs[i*90+72 +:18];
      if(cfg_clear)begin state1[i]<=0;state2[i]<=0;end
     end
    end
   end
   case(phase)
    IDLE:if(s_tvalid && s_tready)begin x<=s_tdata;section<=0;clipped<=0;phase<=M0;end
    M0:begin product<=multiply;phase<=Y;end
    Y:begin y<=y_saturated;clipped<=clipped|y_clips;phase<=M1;end
    M1:begin product<=multiply;phase<=A1;end
    A1:begin accumulator<=product_wide+state2[section];product<=multiply;phase<=B2;end
    B2:begin state1[section]<=accumulator-product_wide;product<=multiply;phase<=A2;end
    A2:begin accumulator<=product_wide;product<=multiply;phase<=FINISH;end
    FINISH:begin
     state2[section]<=accumulator-product_wide;
     if(section+1<active_sections)begin section<=section+1'b1;x<=y;phase<=M0;end
     else begin m_tdata<=y;m_tuser<=clipped;m_tvalid<=1;phase<=IDLE;end
    end
   endcase
  end
 end
`ifndef SYNTHESIS
 initial if(MAX_SOS<1 || MAX_SOS>4)$fatal(1,"MAX_SOS supported range 1..4");
`endif
endmodule
