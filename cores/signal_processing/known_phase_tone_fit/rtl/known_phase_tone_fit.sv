// SPDX-License-Identifier: Apache-2.0
// DC-nuisance known-phase sinusoid fit over exactly N accepted samples.
// Numerical, framing and reset contracts are in CONTRACT.md and WIDTH_PROOF.md.
module known_phase_tone_fit #(
 parameter integer MAX_SAMPLES=256, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [31:0] c_count,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire signed [15:0] s_sample,
 input wire [23:0] s_phase,input wire s_last,
 output wire m_valid,input wire m_ready,output reg [2:0] m_status,
 output reg [31:0] m_requested,output reg [8:0] m_count,
 output reg [TAG_W-1:0] m_tag,
 output reg signed [127:0] m_i_numerator,m_q_numerator,
 output reg [111:0] m_denominator,
 output reg signed [55:0] m_gram_a,m_gram_b,m_gram_d
);
 localparam [2:0] OK=0,BAD_COMMAND=1,FRAME_ERROR=2,RANK_DEFICIENT=3,INTERNAL_RANGE=4;
 localparam [2:0] IDLE=0,COLLECT=1,TRIG_SEND=2,TRIG_WAIT=3,MUL_SEND=4,MUL_WAIT=5,EMIT=6;
 generate if(MAX_SAMPLES<3 || MAX_SAMPLES>256 || TAG_W<1 || TAG_W>32)begin:g_invalid
  known_phase_tone_fit_invalid_parameter__see_CONTRACT reject();
 end endgenerate
 reg [2:0] state;
 reg [4:0] operation;
 reg [8:0] length;
 reg pending_last,product_negative;
 reg signed [15:0] sample;
 reg [23:0] phase;
 reg signed [17:0] cosine,sine;
 reg signed [55:0] sum_c,sum_s,sum_x,sum_cc,sum_ss,sum_cs,sum_xc,sum_xs;
 reg signed [55:0] gram_a,gram_b,gram_d,rhs_u,rhs_v;
 reg signed [112:0] first_product;

 // The public reset is synchronous high. Only this edge-updated bridge
 // changes the reused multiplier's asynchronous active-low reset.
 reg multiplier_rst_n;
 always @(posedge clk)begin
  if(rst)multiplier_rst_n<=0;
  else multiplier_rst_n<=1;
 end
 assign c_ready=!rst &&multiplier_rst_n &&state==IDLE;
 assign s_ready=!rst &&multiplier_rst_n &&state==COLLECT;
 assign m_valid=!rst &&state==EMIT;
 wire trig_ready,trig_valid;
 wire signed [17:0] trig_cos,trig_sin;
 stream_sincos #(.PHASE_W(24),.OUT_W(18),.ITER(20),.TAG_W(1)) reference_basis(
  .clk(clk),.rst(rst),.s_valid(!rst &&state==TRIG_SEND),.s_ready(trig_ready),
  .s_phase(phase),.s_tag(1'b0),.m_valid(trig_valid),
  .m_ready(!rst &&state==TRIG_WAIT),.m_cos(trig_cos),.m_sin(trig_sin),.m_tag());

 reg signed [55:0] operand_a,operand_b,old_sum;
 wire signed [55:0] c_ext={{38{cosine[17]}},cosine};
 wire signed [55:0] s_ext={{38{sine[17]}},sine};
 wire signed [55:0] x_ext={{40{sample[15]}},sample};
 wire signed [55:0] n_ext=$signed({47'd0,length});
 always @*begin
  operand_a=0;operand_b=0;old_sum=0;
  case(operation)
   0:begin operand_a=c_ext;operand_b=c_ext;old_sum=sum_cc;end
   1:begin operand_a=s_ext;operand_b=s_ext;old_sum=sum_ss;end
   2:begin operand_a=c_ext;operand_b=s_ext;old_sum=sum_cs;end
   3:begin operand_a=x_ext;operand_b=c_ext;old_sum=sum_xc;end
   4:begin operand_a=x_ext;operand_b=s_ext;old_sum=sum_xs;end
   5:begin operand_a=n_ext;operand_b=sum_cc;end
   6:begin operand_a=sum_c;operand_b=sum_c;end
   7:begin operand_a=n_ext;operand_b=sum_cs;end
   8:begin operand_a=sum_c;operand_b=sum_s;end
   9:begin operand_a=n_ext;operand_b=sum_ss;end
   10:begin operand_a=sum_s;operand_b=sum_s;end
   11:begin operand_a=n_ext;operand_b=sum_xc;end
   12:begin operand_a=sum_x;operand_b=sum_c;end
   13:begin operand_a=n_ext;operand_b=sum_xs;end
   14:begin operand_a=sum_x;operand_b=sum_s;end
   15:begin operand_a=gram_a;operand_b=gram_d;end
   16:begin operand_a=gram_b;operand_b=gram_b;end
   17:begin operand_a=rhs_u;operand_b=gram_d;end
   18:begin operand_a=rhs_v;operand_b=gram_b;end
   19:begin operand_a=rhs_v;operand_b=gram_a;end
   20:begin operand_a=rhs_u;operand_b=gram_b;end
   default:begin end
  endcase
 end
 // Unsigned absolute values preserve even the minimum signed56 magnitude.
 wire [55:0] magnitude_a=operand_a[55]?(~$unsigned(operand_a)+56'd1):$unsigned(operand_a);
 wire [55:0] magnitude_b=operand_b[55]?(~$unsigned(operand_b)+56'd1):$unsigned(operand_b);
 wire multiply_ready,multiply_valid;
 wire [111:0] magnitude_product;
 img_hist_serial_multiply #(.A_W(56),.B_W(56)) shared_product(
  .clk(clk),.rst_n(multiplier_rst_n),.clk_en(1'b1),
  .s_valid(!rst &&multiplier_rst_n &&state==MUL_SEND),.s_ready(multiply_ready),
  .s_a(magnitude_a),.s_b(magnitude_b),.m_valid(multiply_valid),
  .m_ready(!rst &&state==MUL_WAIT),.m_product(magnitude_product));
 wire signed [112:0] signed_product=product_negative?
  -$signed({1'b0,magnitude_product}):$signed({1'b0,magnitude_product});
 wire signed [112:0] difference=first_product-signed_product;
 wire signed [112:0] negative_difference=-difference;
 wire signed [56:0] next_sum=$signed({old_sum[55],old_sum})+
  $signed({signed_product[55],signed_product[55:0]});
 function fits56;
  input signed [112:0] value;
  begin fits56=value=={{57{value[55]}},value[55:0]};end
 endfunction
 function fits112;
  input signed [112:0] value;
  begin fits112=value[112]==value[111];end
 endfunction
 task fail;
  input [2:0] code;
  begin
   m_status<=code;m_i_numerator<=0;m_q_numerator<=0;m_denominator<=0;
   m_gram_a<=0;m_gram_b<=0;m_gram_d<=0;state<=EMIT;
  end
 endtask

 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;operation<=0;length<=0;pending_last<=0;product_negative<=0;
   sample<=0;phase<=0;cosine<=0;sine<=0;first_product<=0;
   sum_c<=0;sum_s<=0;sum_x<=0;sum_cc<=0;sum_ss<=0;sum_cs<=0;sum_xc<=0;sum_xs<=0;
   gram_a<=0;gram_b<=0;gram_d<=0;rhs_u<=0;rhs_v<=0;
   m_status<=0;m_requested<=0;m_count<=0;m_tag<=0;
   m_i_numerator<=0;m_q_numerator<=0;m_denominator<=0;
   m_gram_a<=0;m_gram_b<=0;m_gram_d<=0;
  end else case(state)
   IDLE:if(c_valid &&c_ready)begin
    m_requested<=c_count;m_tag<=c_tag;m_count<=0;m_status<=OK;
    m_i_numerator<=0;m_q_numerator<=0;m_denominator<=0;
    m_gram_a<=0;m_gram_b<=0;m_gram_d<=0;
    sum_c<=0;sum_s<=0;sum_x<=0;sum_cc<=0;sum_ss<=0;sum_cs<=0;sum_xc<=0;sum_xs<=0;
    gram_a<=0;gram_b<=0;gram_d<=0;rhs_u<=0;rhs_v<=0;
    if(c_count<3 ||c_count>MAX_SAMPLES)fail(BAD_COMMAND);
    else begin length<=c_count[8:0];state<=COLLECT;end
   end
   COLLECT:if(s_valid &&s_ready)begin
    m_count<=m_count+9'd1;
    if(s_last!=(m_count+9'd1==length))fail(FRAME_ERROR);
    else begin
     sample<=s_sample;phase<=s_phase;pending_last<=s_last;state<=TRIG_SEND;
    end
   end
   TRIG_SEND:if(trig_ready)state<=TRIG_WAIT;
   TRIG_WAIT:if(trig_valid)begin
    cosine<=trig_cos;sine<=trig_sin;
    sum_c<=sum_c+{{38{trig_cos[17]}},trig_cos};
    sum_s<=sum_s+{{38{trig_sin[17]}},trig_sin};
    sum_x<=sum_x+x_ext;operation<=0;state<=MUL_SEND;
   end
   MUL_SEND:if(multiply_ready)begin
    product_negative<=operand_a[55]^operand_b[55];state<=MUL_WAIT;
   end
   MUL_WAIT:if(multiply_valid)begin
    if(operation<=4)begin
     if(!fits56(signed_product) ||next_sum[56]!=next_sum[55])fail(INTERNAL_RANGE);
     else begin
      case(operation)
       0:sum_cc<=next_sum[55:0];1:sum_ss<=next_sum[55:0];
       2:sum_cs<=next_sum[55:0];3:sum_xc<=next_sum[55:0];4:sum_xs<=next_sum[55:0];
       default:begin end
      endcase
      if(operation<4)begin operation<=operation+1'b1;state<=MUL_SEND;end
      else if(pending_last)begin operation<=5;state<=MUL_SEND;end
      else state<=COLLECT;
     end
    end else begin
     case(operation)
      5,7,9,11,13,15,17,19:begin
       first_product<=signed_product;operation<=operation+1'b1;state<=MUL_SEND;
      end
      6,8,10,12,14:begin
       if(!fits56(difference) ||((operation==6 ||operation==10)&&difference<0))fail(INTERNAL_RANGE);
       else begin
        case(operation)
         6:gram_a<=difference[55:0];8:gram_b<=difference[55:0];
         10:gram_d<=difference[55:0];12:rhs_u<=difference[55:0];14:rhs_v<=difference[55:0];
         default:begin end
        endcase
        operation<=operation+1'b1;state<=MUL_SEND;
       end
      end
      16:begin
       if(difference<0 ||!fits112(difference))fail(INTERNAL_RANGE);
       else begin
        m_gram_a<=gram_a;m_gram_b<=gram_b;m_gram_d<=gram_d;
        if(difference==0)begin
         m_status<=RANK_DEFICIENT;m_i_numerator<=0;m_q_numerator<=0;m_denominator<=0;state<=EMIT;
        end else begin m_denominator<=difference[111:0];operation<=17;state<=MUL_SEND;end
       end
      end
      18:begin
       if(!fits112(difference))fail(INTERNAL_RANGE);
       else begin
        // WIDTH_PROOF: reachable |difference|<=2^99; fits112 is also checked.
        // Concatenation performs an exact signed112-to-signed128 times2^16.
        m_i_numerator<={difference[111:0],16'b0};operation<=19;state<=MUL_SEND;
       end
      end
      20:begin
       if(!fits112(difference) ||!fits112(negative_difference))fail(INTERNAL_RANGE);
       else begin m_q_numerator<={negative_difference[111:0],16'b0};m_status<=OK;state<=EMIT;end
      end
      default:fail(INTERNAL_RANGE);
     endcase
    end
   end
   EMIT:if(m_ready)state<=IDLE;
   default:fail(INTERNAL_RANGE);
  endcase
 end
endmodule
