// SPDX-License-Identifier: Apache-2.0
`default_nettype none
// Ordered single-spectrum power samples, BINS bins in each of FRAMES frames.
module spectral_kurtosis #(
 parameter integer BINS=64,FRAMES=16,POWER_W=24,FRAC_W=12,TAG_W=8,
 localparam integer BIN_W=(BINS<2)?1:$clog2(BINS),
 localparam integer FRAME_W=(FRAMES<2)?1:$clog2(FRAMES),
 localparam integer GROW=$clog2(FRAMES),COEF_W=$clog2(FRAMES+2),
 localparam integer SUM_W=POWER_W+GROW,SUM2_W=2*POWER_W+GROW,
 localparam integer STAT_W=2*SUM_W+COEF_W,Q_W=FRAC_W+COEF_W
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [Q_W-1:0] c_lower,c_upper,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [POWER_W-1:0] s_power,input wire s_last,
 output wire m_valid,input wire m_ready,
 output reg [2:0] m_status,output reg [BIN_W-1:0] m_bin,
 output reg [SUM_W-1:0] m_sum,output reg [SUM2_W-1:0] m_sum2,
 output reg [STAT_W-1:0] m_numerator,m_denominator,
 output reg [Q_W-1:0] m_sk_q,output reg m_inexact,m_outside,m_last,
 output reg [TAG_W-1:0] m_tag,output wire busy
);
 localparam integer DIV_W=STAT_W+FRAC_W,RAM_W=SUM_W+SUM2_W;
 localparam [3:0] IDLE=0,LOAD=1,SQ_REQ=2,SQ_WAIT=3,WRITE=4,
  READ=5,CHECK=6,S1_REQ=7,S1_WAIT=8,SCALE=9,DIV_REQ=10,DIV_WAIT=11,HOLD=12;
 localparam [COEF_W-1:0] CM=FRAMES,CP=FRAMES+1,CN=FRAMES-1;
 reg [3:0] state;
 reg [BIN_W-1:0] bin_index;
 reg [FRAME_W-1:0] frame_index;
 reg [POWER_W-1:0] power;
 reg [Q_W-1:0] lower,upper;
 reg [TAG_W-1:0] tag;
 reg out_valid;
 // One packed synchronous-read/write bank; the first frame overwrites each
 // location before any accumulation read. No RAM reset or clear sweep.
 reg [RAM_W-1:0] ram[0:BINS-1];
 reg [RAM_W-1:0] ram_q,write_data;
 wire input_fire=s_valid && s_ready;
 wire ram_read=!rst && ((state==LOAD && input_fire && frame_index!=0) || state==READ);
 always @(posedge clk)begin
  if(ram_read)ram_q<=ram[bin_index];
  if(!rst && state==WRITE)ram[bin_index]<=write_data;
 end
 reg [SUM_W-1:0] acc_sum;
 reg [SUM2_W-1:0] acc_sum2;
 reg [2*SUM_W-1:0] sum_square;
 reg [STAT_W-1:0] numerator,denominator;
 wire [SUM_W-1:0] prior_sum=(frame_index==0)?{SUM_W{1'b0}}:ram_q[SUM_W-1:0];
 wire [SUM2_W-1:0] prior_sum2=(frame_index==0)?{SUM2_W{1'b0}}:ram_q[RAM_W-1:SUM_W];
 wire [SUM_W-1:0] added_sum=prior_sum+{{GROW{1'b0}},power};
 wire mul_ready,mul_valid;
 wire [2*SUM_W-1:0] product;
 wire [SUM_W-1:0] mul_operand=(state==S1_REQ)?acc_sum:{{GROW{1'b0}},power};
 img_hist_serial_multiply #(.A_W(SUM_W),.B_W(SUM_W)) square(
  .clk(clk),.rst_n(!rst),.clk_en(1'b1),
  .s_valid(!rst && (state==SQ_REQ || state==S1_REQ)),.s_ready(mul_ready),
  .s_a(mul_operand),.s_b(mul_operand),
  .m_valid(mul_valid),.m_ready(!rst && (state==SQ_WAIT || state==S1_WAIT)),.m_product(product));
 wire [SUM2_W-1:0] added_sum2=prior_sum2+{{GROW{1'b0}},product[2*POWER_W-1:0]};
 // These are compile-time coefficient multiplications, bounded by 65. They
 // do not instantiate one runtime square or divider per bin.
 wire [2*SUM_W-1:0] weighted_sum2=acc_sum2*CM;
 wire [2*SUM_W-1:0] dispersion=weighted_sum2-sum_square;
 wire [STAT_W-1:0] scaled_numerator=dispersion*CP;
 wire [STAT_W-1:0] scaled_denominator=sum_square*CN;
 wire div_ready,div_valid,div_zero;
 wire [DIV_W-1:0] quotient,remainder;
 wire [DIV_W-1:0] div_numerator={{FRAC_W{1'b0}},numerator}<<FRAC_W;
 wire [DIV_W-1:0] div_denominator={{FRAC_W{1'b0}},denominator};
 integer_divider #(.W(DIV_W)) ratio(
  .clk(clk),.rst(rst),.s_valid(!rst && state==DIV_REQ),.s_ready(div_ready),
  .s_numerator(div_numerator),.s_denominator(div_denominator),
  .m_valid(div_valid),.m_ready(!rst && state==DIV_WAIT),
  .m_quotient(quotient),.m_remainder(remainder),.m_divzero(div_zero));
 wire [DIV_W:0] twice_remainder={1'b0,remainder}<<1;
 wire round_up=(twice_remainder>{1'b0,div_denominator}) ||
  (twice_remainder=={1'b0,div_denominator} && quotient[0]);
 wire [DIV_W:0] rounded={1'b0,quotient}+{{DIV_W{1'b0}},round_up};
 assign c_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==LOAD;
 assign m_valid=!rst && out_valid;
 assign busy=!rst && state!=IDLE;
 generate if(BINS<1 || BINS>256 || FRAMES<2 || FRAMES>64 || POWER_W<1 || POWER_W>32 ||
  FRAC_W<0 || FRAC_W>16 || TAG_W<1 || TAG_W>32)begin:invalid
  spectral_kurtosis_invalid_parameters__see_README invalid_configuration();
 end endgenerate
 task fatal_marker(input [2:0] status,input [BIN_W-1:0] index);
  begin
   out_valid<=1;m_status<=status;m_bin<=index;m_sum<=0;m_sum2<=0;
   m_numerator<=0;m_denominator<=0;m_sk_q<=0;m_inexact<=0;m_outside<=0;
   m_last<=1;m_tag<=tag;state<=HOLD;
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;bin_index<=0;frame_index<=0;power<=0;lower<=0;upper<=0;tag<=0;
   acc_sum<=0;acc_sum2<=0;sum_square<=0;numerator<=0;denominator<=0;
   out_valid<=0;m_status<=0;m_bin<=0;m_sum<=0;m_sum2<=0;
   m_numerator<=0;m_denominator<=0;m_sk_q<=0;m_inexact<=0;m_outside<=0;m_last<=0;m_tag<=0;
  end else case(state)
   IDLE:if(c_valid && c_ready)begin
    tag<=c_tag;lower<=c_lower;upper<=c_upper;bin_index<=0;frame_index<=0;
    if(c_lower>c_upper)begin fatal_marker(3'd1,0);m_tag<=c_tag;end
    else state<=LOAD;
   end
   LOAD:if(input_fire)begin
    if(s_last!==(bin_index==BINS-1))fatal_marker(3'd2,bin_index);
    else begin power<=s_power;state<=SQ_REQ;end
   end
   SQ_REQ:if(mul_ready)state<=SQ_WAIT;
   SQ_WAIT:if(mul_valid)begin write_data<={added_sum2,added_sum};state<=WRITE;end
   WRITE:begin
    if(bin_index==BINS-1)begin
     bin_index<=0;
     if(frame_index==FRAMES-1)begin frame_index<=0;state<=READ;end
     else begin frame_index<=frame_index+1'b1;state<=LOAD;end
    end else begin bin_index<=bin_index+1'b1;state<=LOAD;end
   end
   READ:state<=CHECK;
   CHECK:begin
    acc_sum<=ram_q[SUM_W-1:0];acc_sum2<=ram_q[RAM_W-1:SUM_W];
    if(ram_q[SUM_W-1:0]==0)begin
     out_valid<=1;m_status<=3;m_bin<=bin_index;m_sum<=0;m_sum2<=0;
     m_numerator<=0;m_denominator<=0;m_sk_q<=0;m_inexact<=0;m_outside<=0;
     m_last<=(bin_index==BINS-1);m_tag<=tag;state<=HOLD;
    end else state<=S1_REQ;
   end
   S1_REQ:if(mul_ready)state<=S1_WAIT;
   S1_WAIT:if(mul_valid)begin sum_square<=product;state<=SCALE;end
   SCALE:begin
    if(weighted_sum2<sum_square || scaled_denominator==0)fatal_marker(3'd4,bin_index);
    else begin numerator<=scaled_numerator;denominator<=scaled_denominator;state<=DIV_REQ;end
   end
   DIV_REQ:if(div_ready)state<=DIV_WAIT;
   DIV_WAIT:if(div_valid)begin
    if(div_zero || (rounded>>Q_W)!=0)fatal_marker(3'd4,bin_index);
    else begin
     out_valid<=1;m_status<=0;m_bin<=bin_index;m_sum<=acc_sum;m_sum2<=acc_sum2;
     m_numerator<=numerator;m_denominator<=denominator;m_sk_q<=rounded[Q_W-1:0];
     m_inexact<=(remainder!=0);m_outside<=(rounded[Q_W-1:0]<lower || rounded[Q_W-1:0]>upper);
     m_last<=(bin_index==BINS-1);m_tag<=tag;state<=HOLD;
    end
   end
   HOLD:if(m_valid && m_ready)begin
    out_valid<=0;
    if(m_last)state<=IDLE;
    else begin bin_index<=bin_index+1'b1;state<=READ;end
   end
   default:state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
