// Bounded 3-point affine RANSAC variant. Signed16 integer coordinates.
module affine_ransac #(parameter integer CAPACITY=32,FRAC=8)(
 input wire clk,rst_n,ce,
 input wire signed [15:0] s_x,s_y,s_u,s_v,
 input wire s_first,s_last,s_valid,output wire s_ready,
 input wire [6:0] cfg_count,input wire [15:0] cfg_iterations,
 input wire [31:0] cfg_seed,cfg_threshold,
 output reg signed [39:0] a00,a01,a02,a10,a11,a12,
 output reg [6:0] best_count,
 output reg [63:0] best_residual,
 output reg model_valid,m_valid,input wire m_ready,
 output wire busy,output reg done,output reg [3:0] error_code
);
 initial if((CAPACITY!=32 && CAPACITY!=64) || FRAC<0 || FRAC>16)$fatal(1,"invalid affine parameters");
 localparam AW=$clog2(CAPACITY);
 localparam CAP=0,RNG0=1,RNG1=2,RNG2=3,HADDR=4,HREAD=5,HSAVE=6,CROSS0=7,CROSS1=8,CROSS2=9,
  MUL=10,DIVPREP=11,DIVIDE=12,DIVSAVE=13,T0=14,T1=15,T2=16,T3=17,T4=18,
  PADDR=19,PREAD=20,PSAVE=21,P0=22,P1=23,P2=24,P3=25,P4=26,SCORE=27,NEXTH=28,OUT=29,FINAL=30;
 reg [4:0] state,mul_return;
 reg [63:0] points[0:CAPACITY-1],point_q;
 reg [AW-1:0] read_address;
 reg [6:0] count_q,loaded,index_q,i0,i1,i2;
 reg [15:0] budget_q,hypothesis;
 reg [31:0] rng,threshold_q;
 reg [1:0] pick;
 reg signed [15:0] x0,y0,u0,v0,x1,y1,u1,v1,x2,y2,u2,v2,px,py,pu,pv;
 wire signed [16:0] dx1=$signed({x1[15],x1})-$signed({x0[15],x0});
 wire signed [16:0] dx2=$signed({x2[15],x2})-$signed({x0[15],x0});
 wire signed [16:0] dy1=$signed({y1[15],y1})-$signed({y0[15],y0});
 wire signed [16:0] dy2=$signed({y2[15],y2})-$signed({y0[15],y0});
 wire signed [16:0] du1=$signed({u1[15],u1})-$signed({u0[15],u0});
 wire signed [16:0] du2=$signed({u2[15],u2})-$signed({u0[15],u0});
 wire signed [16:0] dv1=$signed({v1[15],v1})-$signed({v0[15],v0});
 wire signed [16:0] dv2=$signed({v2[15],v2})-$signed({v0[15],v0});
 reg [2:0] cross_sel;
 reg [1:0] coefficient;
 reg signed [63:0] determinant,numerators[0:3],temp,diff_result;
 reg signed [39:0] ca,cb,cc,cd,ctx,cty;
 reg signed [63:0] sum_u,sum_v;
 reg [63:0] score_sum;
 reg [6:0] score_count;
 reg [63:0] mul_acc,mul_shift;
 reg [16:0] mul_factor;
 reg mul_negative;
 reg [4:0] mul_step;
 wire [63:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:64'd0);
 wire signed [63:0] mul_result=mul_negative?-$signed(mul_next):$signed(mul_next);
 reg signed [63:0] product_result;
 reg [63:0] quotient,divisor;
 reg [64:0] remainder;
 reg [5:0] div_step;
 reg div_negative;
 wire [64:0] trial={remainder[63:0],quotient[63]};
 wire take=trial>={1'b0,divisor};
 wire [63:0] next_q={quotient[62:0],take};
 wire signed [63:0] signed_quotient=div_negative?-$signed(quotient):$signed(quotient);
 wire signed [63:0] cross_difference=temp-product_result;
 wire signed [63:0] residual_u=sum_u-($signed(pu)*64'sd1<<<FRAC);
 wire signed [63:0] residual_v=sum_v-($signed(pv)*64'sd1<<<FRAC);
 wire [63:0] point_residual=(residual_u<0?-$unsigned(residual_u):$unsigned(residual_u))+
                           (residual_v<0?-$unsigned(residual_v):$unsigned(residual_v));
 wire [6:0] smaller=i0<i1?i0:i1;
 wire [6:0] larger=i0<i1?i1:i0;
 reg [6:0] modulus;
 wire [15:0] random_mod=rng[15:0]%modulus;
 wire [7:0] second_sum={1'b0,i0}+1'b1+random_mod;
 wire [6:0] third_skip0=(random_mod>=smaller)?random_mod+1'b1:random_mod;
 wire [6:0] third_skip1=(third_skip0>=larger)?third_skip0+1'b1:third_skip0;
 function [31:0] next_rng;
 input [31:0] value;reg [31:0] t;
 begin t=value^(value<<13);t=t^(t>>17);next_rng=t^(t<<5);end
 endfunction
 function in_range;
 input signed [63:0] value;
 begin in_range=(value>=-64'sd549755813888 && value<=64'sd549755813887);end
 endfunction
 task multiply;
 input signed [63:0] left;input signed [16:0] right;input [4:0] ret;
 begin
  mul_acc<=0;mul_shift<=left<0?-$unsigned(left):$unsigned(left);
  mul_factor<=right<0?-$unsigned(right):$unsigned(right);mul_negative<=left[63]^right[16];
  mul_step<=0;mul_return<=ret;state<=MUL;
 end
 endtask
 always @*begin
  case(state)RNG1:modulus=count_q-1'b1;RNG2:modulus=count_q-2'd2;default:modulus=(count_q>=3)?count_q:7'd3;endcase
 end
 assign s_ready=state==CAP;
 assign busy=loaded!=0 || state!=CAP;
 always @(posedge clk)if(rst_n&&ce)begin
  if(state==CAP && s_valid && s_first==(loaded==0) &&
    ((loaded==0 && cfg_count>=3 && cfg_count<=CAPACITY && cfg_iterations!=0 && s_last==0) ||
     (loaded!=0 && s_last==(loaded==count_q-1))))points[loaded[AW-1:0]]<={s_v,s_u,s_y,s_x};
  if(state==HREAD || state==PREAD)point_q<=points[read_address];
 end
 integer k;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAP;mul_return<=0;read_address<=0;count_q<=0;loaded<=0;index_q<=0;i0<=0;i1<=0;i2<=0;
   budget_q<=0;hypothesis<=0;rng<=1;threshold_q<=0;pick<=0;cross_sel<=0;coefficient<=0;
   x0<=0;y0<=0;u0<=0;v0<=0;x1<=0;y1<=0;u1<=0;v1<=0;x2<=0;y2<=0;u2<=0;v2<=0;px<=0;py<=0;pu<=0;pv<=0;
   determinant<=0;temp<=0;diff_result<=0;for(k=0;k<4;k=k+1)numerators[k]<=0;
   ca<=0;cb<=0;cc<=0;cd<=0;ctx<=0;cty<=0;sum_u<=0;sum_v<=0;score_sum<=0;score_count<=0;
   mul_acc<=0;mul_shift<=0;mul_factor<=0;mul_negative<=0;mul_step<=0;product_result<=0;
   quotient<=0;divisor<=1;remainder<=0;div_step<=0;div_negative<=0;
   a00<=0;a01<=0;a02<=0;a10<=0;a11<=0;a12<=0;best_count<=0;best_residual<=0;model_valid<=0;m_valid<=0;done<=0;error_code<=0;
  end else if(ce)begin
   done<=0;
   case(state)
    CAP:if(s_valid)begin
     if((loaded==0 && (cfg_count<3 || cfg_count>CAPACITY || cfg_iterations==0)) ||
       s_first!=(loaded==0) || s_last!=(loaded==((loaded==0?cfg_count:count_q)-1)))begin
      error_code<=(loaded==0 && (cfg_count<3 || cfg_count>CAPACITY || cfg_iterations==0))?1:2;
      a00<=0;a01<=0;a02<=0;a10<=0;a11<=0;a12<=0;best_count<=0;best_residual<=0;model_valid<=0;
      m_valid<=1;state<=OUT;
     end else begin
      if(loaded==0)begin count_q<=cfg_count;budget_q<=cfg_iterations;rng<=cfg_seed==0?32'd1:cfg_seed;threshold_q<=cfg_threshold;
       model_valid<=0;best_count<=0;best_residual<=0;error_code<=0;hypothesis<=0;
       a00<=0;a01<=0;a02<=0;a10<=0;a11<=0;a12<=0;
      end
      if(loaded==count_q-1 && loaded!=0)begin state<=RNG0;loaded<=loaded+1'b1;end
      else loaded<=loaded+1'b1;
     end
    end
    RNG0:begin i0<=random_mod;rng<=next_rng(rng);state<=RNG1;end
    RNG1:begin i1<=second_sum>=count_q?second_sum-count_q:second_sum;rng<=next_rng(rng);state<=RNG2;end
    RNG2:begin i2<=third_skip1;rng<=next_rng(rng);pick<=0;state<=HADDR;end
    HADDR:begin read_address<=(pick==0)?i0:(pick==1)?i1:i2;state<=HREAD;end
    HREAD:state<=HSAVE;
    HSAVE:begin
     case(pick)0:{v0,u0,y0,x0}<=point_q;1:{v1,u1,y1,x1}<=point_q;2:{v2,u2,y2,x2}<=point_q;endcase
     if(pick==2)begin cross_sel<=0;state<=CROSS0;end else begin pick<=pick+1'b1;state<=HADDR;end
    end
    CROSS0:case(cross_sel)
     0:multiply(dx1,dy2,CROSS1);1:multiply(du1,dv2,CROSS1);
     2:multiply(du1,dy2,CROSS1);3:multiply(dx1,du2,CROSS1);
     4:multiply(dv1,dy2,CROSS1);5:multiply(dx1,dv2,CROSS1);
    endcase
    CROSS1:begin
     temp<=product_result;
     case(cross_sel)
      0:multiply(dx2,dy1,CROSS2);1:multiply(du2,dv1,CROSS2);
      2:multiply(du2,dy1,CROSS2);3:multiply(dx2,du1,CROSS2);
      4:multiply(dv2,dy1,CROSS2);5:multiply(dx2,dv1,CROSS2);
     endcase
    end
    CROSS2:begin
     if(cross_sel<2 && cross_difference==0)state<=NEXTH;
     else begin
      if(cross_sel==0)determinant<=cross_difference;
      if(cross_sel>=2)numerators[cross_sel-2]<=cross_difference;
      if(cross_sel==5)begin coefficient<=0;state<=DIVPREP;end
      else begin cross_sel<=cross_sel+1'b1;state<=CROSS0;end
     end
    end
    MUL:begin
     mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
     if(mul_step==16)begin product_result<=mul_result;state<=mul_return;end else mul_step<=mul_step+1'b1;
    end
    DIVPREP:begin
     quotient<=(numerators[coefficient]<0?-$unsigned(numerators[coefficient]):$unsigned(numerators[coefficient]))<<FRAC;
     divisor<=determinant<0?-$unsigned(determinant):$unsigned(determinant);
     div_negative<=numerators[coefficient][63]^determinant[63];remainder<=0;div_step<=0;state<=DIVIDE;
    end
    DIVIDE:begin
     quotient<=next_q;remainder<=take?trial-{1'b0,divisor}:trial;
     if(div_step==63)state<=DIVSAVE;else div_step<=div_step+1'b1;
    end
    DIVSAVE:begin
     if(!in_range(signed_quotient))state<=NEXTH;
     else begin
      case(coefficient)0:ca<=signed_quotient;1:cb<=signed_quotient;2:cc<=signed_quotient;3:cd<=signed_quotient;endcase
      if(coefficient==3)state<=T0;else begin coefficient<=coefficient+1'b1;state<=DIVPREP;end
     end
    end
    T0:multiply(ca,x0,T1);
    T1:begin temp<=product_result;multiply(cb,y0,T2);end
    T2:begin
     if(!in_range(($signed(u0)*64'sd1<<<FRAC)-temp-product_result))state<=NEXTH;
     else begin ctx<=($signed(u0)*64'sd1<<<FRAC)-temp-product_result;multiply(cc,x0,T3);end
    end
    T3:begin temp<=product_result;multiply(cd,y0,T4);end
    T4:begin
     if(!in_range(($signed(v0)*64'sd1<<<FRAC)-temp-product_result))state<=NEXTH;
     else begin cty<=($signed(v0)*64'sd1<<<FRAC)-temp-product_result;score_sum<=0;score_count<=0;index_q<=0;state<=PADDR;end
    end
    PADDR:begin read_address<=index_q;state<=PREAD;end
    PREAD:state<=PSAVE;
    PSAVE:begin {pv,pu,py,px}<=point_q;state<=P0;end
    P0:multiply(ca,px,P1);
    P1:begin temp<=product_result;multiply(cb,py,P2);end
    P2:begin sum_u<=temp+product_result+ctx;multiply(cc,px,P3);end
    P3:begin temp<=product_result;multiply(cd,py,P4);end
    P4:begin sum_v<=temp+product_result+cty;state<=SCORE;end
    SCORE:begin
     if(point_residual<=threshold_q)begin score_count<=score_count+1'b1;score_sum<=score_sum+point_residual;end
     if(index_q==count_q-1)state<=NEXTH;
     else begin index_q<=index_q+1'b1;state<=PADDR;end
    end
    NEXTH:begin
     // Scoring candidates reach here only after the final SCORE state.
     if(index_q==count_q-1 && score_count>=3 &&
       (!model_valid || score_count>best_count || (score_count==best_count && score_sum<best_residual)))begin
      a00<=ca;a01<=cb;a02<=ctx;a10<=cc;a11<=cd;a12<=cty;
      best_count<=score_count;best_residual<=score_sum;model_valid<=1;
     end
     index_q<=0;score_count<=0;score_sum<=0;
     if(hypothesis==budget_q-1)state<=FINAL;
     else begin hypothesis<=hypothesis+1'b1;state<=RNG0;end
    end
    FINAL:begin m_valid<=1;if(!model_valid)error_code<=3;state<=OUT;end
    OUT:begin
     if(m_ready)begin m_valid<=0;loaded<=0;done<=1;state<=CAP;end
    end
    default:begin m_valid<=1;model_valid<=0;error_code<=4;state<=OUT;end
   endcase
  end
 end
endmodule
