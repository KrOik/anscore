// SPDX-License-Identifier: Apache-2.0
// One exact three-frequency relation per command; all arithmetic is serialized.
module spectral_bicoherence #(
 parameter integer DATA_W=12, MAX_AVERAGES=64, TAG_W=8,
 parameter integer LG=(MAX_AVERAGES<2?0:$clog2(MAX_AVERAGES)),
 parameter integer P_W=2*DATA_W+1, T_W=3*DATA_W+2,
 parameter integer B_W=T_W+LG, U_W=2*P_W+1+LG,
 parameter integer V_W=2*DATA_W+1+LG
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_averages,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,
 // Six signed lanes, least significant first: Xre,Xim,Yre,Yim,Zre,Zim.
 input wire [6*DATA_W-1:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,
 output reg [2:0] m_status,output reg [16:0] m_bicoherence_q16,
 output reg signed [B_W-1:0] m_b_re,m_b_im,
 output reg [U_W-1:0] m_u,output reg [V_W-1:0] m_v,
 output reg [TAG_W-1:0] m_tag,output wire m_last
);
 localparam integer C_W=(MAX_AVERAGES<2?1:$clog2(MAX_AVERAGES+1));
 localparam integer MA=U_W, MB=B_W, MP=MA+MB;
 localparam integer DEN_W=U_W+V_W, NUM_W=2*B_W+1, DIV_W=NUM_W+16;
 localparam [3:0] IDLE=0,INPUTS=1,M_ISSUE=2,M_WAIT=3,
  NORMALIZE=4,D_ISSUE=5,D_WAIT=6,OUTPUTS=7,FLUSH=8;
 reg [3:0] state,operation;
 reg [C_W-1:0] count,averages;
 reg signed [DATA_W-1:0] xr,xi,yr,yi,zr,zi;
 reg signed [2*DATA_W-1:0] xy0,xy1;
 reg signed [P_W-1:0] pr,pi;
 reg signed [P_W+DATA_W-1:0] triple0,triple1;
 reg signed [T_W-1:0] tr,ti;
 reg [2*P_W-1:0] power_p0;
 reg [2*DATA_W-1:0] power_z0;
 reg [2*P_W:0] power_p;
 reg signed [B_W-1:0] br,bi;
 reg [U_W-1:0] usum;
 reg [V_W-1:0] vsum;
 reg [2*B_W-1:0] b_square;
 reg [NUM_W-1:0] numerator;
 reg [DEN_W-1:0] denominator;
 reg [MA-1:0] mul_a;
 reg [MB-1:0] mul_b;
 reg mul_negative,product_negative;
 wire mul_ready,mul_valid;
 wire [MP-1:0] mul_product;
 // Inputs are magnitudes, so signed minima need no signed absolute-value code.
 function [DATA_W-1:0] abs_d;
  input signed [DATA_W-1:0] value;
  begin abs_d=value[DATA_W-1]?(~value+1'b1):value;end
 endfunction
 function [P_W-1:0] abs_p;
  input signed [P_W-1:0] value;
  begin abs_p=value[P_W-1]?(~value+1'b1):value;end
 endfunction
 function [B_W-1:0] abs_b;
  input signed [B_W-1:0] value;
  begin abs_b=value[B_W-1]?(~value+1'b1):value;end
 endfunction
 always @* begin
  mul_a=0;mul_b=0;mul_negative=0;
  case(operation)
   0:begin mul_a=abs_d(xr);mul_b=abs_d(yr);mul_negative=xr[DATA_W-1]^yr[DATA_W-1];end
   1:begin mul_a=abs_d(xi);mul_b=abs_d(yi);mul_negative=xi[DATA_W-1]^yi[DATA_W-1];end
   2:begin mul_a=abs_d(xr);mul_b=abs_d(yi);mul_negative=xr[DATA_W-1]^yi[DATA_W-1];end
   3:begin mul_a=abs_d(xi);mul_b=abs_d(yr);mul_negative=xi[DATA_W-1]^yr[DATA_W-1];end
   4:begin mul_a=abs_p(pr);mul_b=abs_d(zr);mul_negative=pr[P_W-1]^zr[DATA_W-1];end
   5:begin mul_a=abs_p(pi);mul_b=abs_d(zi);mul_negative=pi[P_W-1]^zi[DATA_W-1];end
   6:begin mul_a=abs_p(pi);mul_b=abs_d(zr);mul_negative=pi[P_W-1]^zr[DATA_W-1];end
   7:begin mul_a=abs_p(pr);mul_b=abs_d(zi);mul_negative=pr[P_W-1]^zi[DATA_W-1];end
   8:begin mul_a=abs_p(pr);mul_b=abs_p(pr);end
   9:begin mul_a=abs_p(pi);mul_b=abs_p(pi);end
   10:begin mul_a=abs_d(zr);mul_b=abs_d(zr);end
   11:begin mul_a=abs_d(zi);mul_b=abs_d(zi);end
   12:begin mul_a=abs_b(br);mul_b=abs_b(br);end
   13:begin mul_a=abs_b(bi);mul_b=abs_b(bi);end
   14:begin mul_a=usum;mul_b=vsum;end
   default:begin end
  endcase
 end
 wire helper_rst=rst || state==FLUSH;
 img_hist_serial_multiply #(.A_W(MA),.B_W(MB)) multiply(
  .clk(clk),.rst_n(!helper_rst),.clk_en(1'b1),
  .s_valid(!rst && state==M_ISSUE),.s_ready(mul_ready),.s_a(mul_a),.s_b(mul_b),
  .m_valid(mul_valid),.m_ready(1'b1),.m_product(mul_product));
 wire signed [MP:0] signed_product=product_negative?
  -$signed({1'b0,mul_product}):$signed({1'b0,mul_product});
 wire signed [P_W:0] next_pr=$signed({{(P_W+1-2*DATA_W){xy0[2*DATA_W-1]}},xy0})-
  $signed(signed_product[P_W:0]);
 wire signed [P_W:0] next_pi=$signed({{(P_W+1-2*DATA_W){xy1[2*DATA_W-1]}},xy1})+
  $signed(signed_product[P_W:0]);
 wire signed [T_W:0] next_tr=$signed({{(T_W+1-P_W-DATA_W){triple0[P_W+DATA_W-1]}},triple0})+
  $signed(signed_product[T_W:0]);
 wire signed [T_W:0] next_ti=$signed({{(T_W+1-P_W-DATA_W){triple1[P_W+DATA_W-1]}},triple1})-
  $signed(signed_product[T_W:0]);
 wire signed [B_W:0] next_br=$signed({br[B_W-1],br})+
  $signed({{(B_W+1-T_W){tr[T_W-1]}},tr});
 wire signed [B_W:0] next_bi=$signed({bi[B_W-1],bi})+
  $signed({{(B_W+1-T_W){ti[T_W-1]}},ti});
 wire [2*DATA_W:0] power_z={1'b0,power_z0}+{1'b0,mul_product[2*DATA_W-1:0]};
 wire [U_W:0] next_u={1'b0,usum}+{{(U_W-2*P_W){1'b0}},power_p};
 wire [V_W:0] next_v={1'b0,vsum}+{{(V_W-2*DATA_W){1'b0}},power_z};
 wire div_ready,div_valid,div_zero;
 wire [DIV_W-1:0] div_quotient,div_remainder;
 wire [DIV_W-1:0] div_den={{(DIV_W-DEN_W){1'b0}},denominator};
 integer_divider #(.W(DIV_W)) divide(
  .clk(clk),.rst(helper_rst),.s_valid(!rst && state==D_ISSUE),.s_ready(div_ready),
  .s_numerator({numerator,16'b0}),.s_denominator(div_den),
  .m_valid(div_valid),.m_ready(1'b1),.m_quotient(div_quotient),
  .m_remainder(div_remainder),.m_divzero(div_zero));
 wire [DIV_W:0] twice_remainder={div_remainder,1'b0};
 wire round_up=twice_remainder>{1'b0,div_den} ||
  (twice_remainder=={1'b0,div_den} && div_quotient[0]);
 wire [DIV_W:0] rounded={1'b0,div_quotient}+{{DIV_W{1'b0}},round_up};
 assign c_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==INPUTS;
 assign m_valid=!rst && state==OUTPUTS;
 assign m_last=m_valid;
 task fatal_result;
  input [2:0] status;
  begin
   m_status<=status;m_bicoherence_q16<=0;m_b_re<=0;m_b_im<=0;m_u<=0;m_v<=0;
   state<=FLUSH;
  end
 endtask
 always @(posedge clk) begin
  if(rst)begin
   state<=IDLE;operation<=0;count<=0;averages<=0;
   m_status<=0;m_bicoherence_q16<=0;m_b_re<=0;m_b_im<=0;m_u<=0;m_v<=0;m_tag<=0;
   br<=0;bi<=0;usum<=0;vsum<=0;product_negative<=0;
  end else case(state)
   IDLE:if(c_valid)begin
    m_tag<=c_tag;count<=0;br<=0;bi<=0;usum<=0;vsum<=0;
    m_status<=0;m_bicoherence_q16<=0;m_b_re<=0;m_b_im<=0;m_u<=0;m_v<=0;
    if(c_averages==0 || c_averages>MAX_AVERAGES)fatal_result(1);
    else begin averages<=c_averages[C_W-1:0];state<=INPUTS;end
   end
   INPUTS:if(s_valid)begin
    if(s_last!=(count==averages-1'b1))fatal_result(2);
    else begin
     xr<=s_data[DATA_W-1:0];xi<=s_data[2*DATA_W-1:DATA_W];
     yr<=s_data[3*DATA_W-1:2*DATA_W];yi<=s_data[4*DATA_W-1:3*DATA_W];
     zr<=s_data[5*DATA_W-1:4*DATA_W];zi<=s_data[6*DATA_W-1:5*DATA_W];
     operation<=0;state<=M_ISSUE;
    end
   end
   M_ISSUE:if(mul_ready)begin product_negative<=mul_negative;state<=M_WAIT;end
   M_WAIT:if(mul_valid)begin
    state<=M_ISSUE;operation<=operation+1'b1;
    case(operation)
     0:xy0<=signed_product[2*DATA_W-1:0];
     1:pr<=next_pr[P_W-1:0];
     2:xy1<=signed_product[2*DATA_W-1:0];
     3:pi<=next_pi[P_W-1:0];
     4:triple0<=signed_product[P_W+DATA_W-1:0];
     5:tr<=next_tr[T_W-1:0];
     6:triple1<=signed_product[P_W+DATA_W-1:0];
     7:ti<=next_ti[T_W-1:0];
     8:power_p0<=mul_product[2*P_W-1:0];
     9:power_p<={1'b0,power_p0}+{1'b0,mul_product[2*P_W-1:0]};
     10:power_z0<=mul_product[2*DATA_W-1:0];
     11:begin
      if(next_br[B_W]!=next_br[B_W-1] || next_bi[B_W]!=next_bi[B_W-1] || next_u[U_W] || next_v[V_W])fatal_result(4);
      else begin
       br<=next_br[B_W-1:0];bi<=next_bi[B_W-1:0];usum<=next_u[U_W-1:0];vsum<=next_v[V_W-1:0];
       if(count==averages-1'b1)state<=NORMALIZE;
       else begin count<=count+1'b1;state<=INPUTS;end
      end
     end
     12:b_square<=mul_product[2*B_W-1:0];
     13:numerator<={1'b0,b_square}+{1'b0,mul_product[2*B_W-1:0]};
     14:begin
      denominator<=mul_product[DEN_W-1:0];
      if((mul_product>>DEN_W)!=0 || numerator>{1'b0,mul_product[DEN_W-1:0]})fatal_result(4);
      else state<=D_ISSUE;
     end
     default:fatal_result(4);
    endcase
   end
   NORMALIZE:begin
    m_b_re<=br;m_b_im<=bi;m_u<=usum;m_v<=vsum;
    if(usum==0 || vsum==0)begin
     m_status<=3;m_bicoherence_q16<=0;
     if(br!=0 || bi!=0)fatal_result(4);else state<=OUTPUTS;
    end else begin operation<=12;state<=M_ISSUE;end
   end
   D_ISSUE:if(div_ready)state<=D_WAIT;
   D_WAIT:if(div_valid)begin
    if(div_zero || div_remainder>=div_den || rounded>65536)fatal_result(4);
    else begin m_status<=0;m_bicoherence_q16<=rounded[16:0];state<=OUTPUTS;end
   end
   FLUSH:state<=OUTPUTS;
   OUTPUTS:if(m_ready)state<=IDLE;
   default:fatal_result(4);
  endcase
 end
`ifndef SYNTHESIS
 initial begin
  if(DATA_W<2 || DATA_W>16 || MAX_AVERAGES<1 || MAX_AVERAGES>256 || TAG_W<1 || TAG_W>32 ||
   LG!=(MAX_AVERAGES<2?0:$clog2(MAX_AVERAGES)) || P_W!=2*DATA_W+1 || T_W!=3*DATA_W+2 ||
   B_W!=T_W+LG || U_W!=2*P_W+1+LG || V_W!=2*DATA_W+1+LG)
   $fatal(1,"spectral_bicoherence: unsupported static configuration");
 end
`endif
endmodule
