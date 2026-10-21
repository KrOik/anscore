// General 2D affine trajectory stabilizer, all matrices signed Q16.16.
module affine_video_stabilizer(
 input wire clk,rst_n,ce,
 input wire signed [31:0] s_a00,s_a01,s_a02,s_a10,s_a11,s_a12,
 input wire [6:0] s_inliers,input wire s_scene_cut,s_valid,output wire s_ready,
 input wire [16:0] cfg_alpha,input wire [6:0] cfg_min_inliers,input wire [63:0] cfg_min_det,
 output reg signed [31:0] m_c00,m_c01,m_c02,m_c10,m_c11,m_c12,
 output reg signed [31:0] m_w00,m_w01,m_w02,m_w10,m_w11,m_w12,
 output reg m_model_valid,m_valid,input wire m_ready,
 output wire busy,output reg done,output reg [3:0] error_code
);
 localparam IDLE=0,COMP0=1,COMP1=2,COMP2=3,MUL=4,EMA0=5,EMA1=6,
  DET0=7,DET1=8,DET2=9,DIV0=10,DIVIDE=11,DIVSAVE=12,IT0=13,IT1=14,IT2=15,INVEND=16,COMMIT=17,OUT=18;
 reg [4:0] state,mul_return;
 reg signed [31:0] trajectory[0:5],smoothed[0:5],input_a[0:5],next_t[0:5],next_s[0:5],inv_t[0:5],inv_s[0:5],result_c[0:5],result_w[0:5];
 reg [1:0] comp_stage;
 reg [2:0] component;
 reg inverse_select;
 reg [1:0] inverse_component;
 reg [16:0] alpha_q;
 reg [63:0] min_det_q;
 reg [65:0] mul_acc,mul_shift;
 reg [32:0] mul_factor;
 reg mul_negative;
 reg [5:0] mul_step;
 reg signed [65:0] product_result,temp,determinant;
 wire [65:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:66'd0);
 wire signed [65:0] mul_signed=mul_negative?-$signed(mul_next):$signed(mul_next);
 reg [63:0] quotient;
 reg [65:0] divisor;
 reg [66:0] remainder;
 reg div_negative;
 reg [5:0] div_step;
 wire [66:0] trial={remainder[65:0],quotient[63]};
 wire take=trial>={1'b0,divisor};
 wire [63:0] next_quotient={quotient[62:0],take};
 reg signed [31:0] left0,left1,left_translation,right0,right1;
 reg signed [31:0] ia,ib,ic,id,itx,ity,inv0,inv1;
 reg signed [32:0] cofactor;
 reg signed [65:0] comp_value,ema_value,translation_value;
 wire signed [65:0] det_value=temp-product_result;
 wire [65:0] det_magnitude=det_value<0?-$unsigned(det_value):$unsigned(det_value);
 function signed [65:0] round16;
 input signed [65:0] value;reg [65:0] magnitude;
 begin magnitude=value<0?-$unsigned(value):$unsigned(value);round16=value<0?-$signed((magnitude+66'd32768)>>16):$signed((magnitude+66'd32768)>>16);end
 endfunction
 function fits32;
 input signed [65:0] value;
 begin fits32=value>=-66'sd2147483648 && value<=66'sd2147483647;end
 endfunction
 function signed [31:0] identity;
 input integer i;
 begin identity=(i==0 || i==4)?32'sd65536:32'sd0;end
 endfunction
 function [32:0] magnitude33;
 input signed [32:0] value;
 begin magnitude33=value<0?-$unsigned(value):$unsigned(value);end
 endfunction
 task multiply;
 input signed [32:0] left,right;input [4:0] ret;
 begin mul_acc<=0;mul_shift<={33'd0,magnitude33(left)};mul_factor<=magnitude33(right);
  mul_negative<=left[32]^right[32];mul_step<=0;mul_return<=ret;state<=MUL;end
 endtask
 task reject;
 input [3:0] code;
 begin
  m_c00<=0;m_c01<=0;m_c02<=0;m_c10<=0;m_c11<=0;m_c12<=0;
  m_w00<=0;m_w01<=0;m_w02<=0;m_w10<=0;m_w11<=0;m_w12<=0;
  error_code<=code;m_model_valid<=0;m_valid<=1;state<=OUT;
 end
 endtask
 integer row,column;
 always @*begin
  row=(component>=3)?3:0;column=(component>=3)?component-3:component;
  left0=0;left1=0;left_translation=0;right0=0;right1=0;
  case(comp_stage)
   0:begin left0=input_a[row];left1=input_a[row+1];left_translation=input_a[row+2];right0=trajectory[column];right1=trajectory[column+3];end
   1:begin left0=next_s[row];left1=next_s[row+1];left_translation=next_s[row+2];right0=inv_t[column];right1=inv_t[column+3];end
   2:begin left0=next_t[row];left1=next_t[row+1];left_translation=next_t[row+2];right0=inv_s[column];right1=inv_s[column+3];end
  endcase
  comp_value=round16(temp+product_result+((column==2)?($signed(left_translation)*66'sd65536):66'sd0));
  ema_value=$signed(smoothed[component])+round16(product_result);
  ia=inverse_select?next_s[0]:next_t[0];ib=inverse_select?next_s[1]:next_t[1];
  ic=inverse_select?next_s[3]:next_t[3];id=inverse_select?next_s[4]:next_t[4];
  itx=inverse_select?next_s[2]:next_t[2];ity=inverse_select?next_s[5]:next_t[5];
  case(inverse_component)
   0:cofactor=id;
   1:cofactor=-$signed({ib[31],ib});
   2:cofactor=-$signed({ic[31],ic});
   default:cofactor=ia;
  endcase
  if(component==2)begin inv0=inverse_select?inv_s[0]:inv_t[0];inv1=inverse_select?inv_s[1]:inv_t[1];end
  else begin inv0=inverse_select?inv_s[3]:inv_t[3];inv1=inverse_select?inv_s[4]:inv_t[4];end
  translation_value=-round16(temp+product_result);
 end
 assign s_ready=state==IDLE;
 assign busy=state!=IDLE;
 integer k;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;mul_return<=0;comp_stage<=0;component<=0;inverse_select<=0;inverse_component<=0;alpha_q<=0;min_det_q<=0;
   mul_acc<=0;mul_shift<=0;mul_factor<=0;mul_negative<=0;mul_step<=0;product_result<=0;temp<=0;determinant<=0;
   quotient<=0;divisor<=1;remainder<=0;div_negative<=0;div_step<=0;
   for(k=0;k<6;k=k+1)begin trajectory[k]<=identity(k);smoothed[k]<=identity(k);input_a[k]<=0;next_t[k]<=0;next_s[k]<=0;inv_t[k]<=0;inv_s[k]<=0;result_c[k]<=0;result_w[k]<=0;end
   m_c00<=0;m_c01<=0;m_c02<=0;m_c10<=0;m_c11<=0;m_c12<=0;m_w00<=0;m_w01<=0;m_w02<=0;m_w10<=0;m_w11<=0;m_w12<=0;
   m_model_valid<=0;m_valid<=0;done<=0;error_code<=0;
  end else if(ce)begin
   done<=0;
   case(state)
    IDLE:if(s_valid)begin
     if(s_scene_cut)begin
      for(k=0;k<6;k=k+1)begin trajectory[k]<=identity(k);smoothed[k]<=identity(k);end
      m_c00<=65536;m_c01<=0;m_c02<=0;m_c10<=0;m_c11<=65536;m_c12<=0;
      m_w00<=65536;m_w01<=0;m_w02<=0;m_w10<=0;m_w11<=65536;m_w12<=0;
      m_model_valid<=1;m_valid<=1;error_code<=0;state<=OUT;
     end else if(cfg_alpha>65536)reject(4);
     else if(s_inliers<cfg_min_inliers)reject(1);
     else begin
      input_a[0]<=s_a00;input_a[1]<=s_a01;input_a[2]<=s_a02;input_a[3]<=s_a10;input_a[4]<=s_a11;input_a[5]<=s_a12;
      alpha_q<=cfg_alpha;min_det_q<=cfg_min_det;error_code<=0;comp_stage<=0;component<=0;state<=COMP0;
     end
    end
    COMP0:multiply(left0,right0,COMP1);
    COMP1:begin temp<=product_result;multiply(left1,right1,COMP2);end
    COMP2:begin
     if(!fits32(comp_value))reject(3);
     else begin
      case(comp_stage)0:next_t[component]<=comp_value;1:result_c[component]<=comp_value;2:result_w[component]<=comp_value;endcase
      if(component==5)begin
       component<=0;
       case(comp_stage)0:state<=EMA0;1:begin comp_stage<=2;state<=COMP0;end 2:state<=COMMIT;endcase
      end else begin component<=component+1'b1;state<=COMP0;end
     end
    end
    MUL:begin
     mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
     if(mul_step==32)begin product_result<=mul_signed;state<=mul_return;end else mul_step<=mul_step+1'b1;
    end
    EMA0:multiply($signed({next_t[component][31],next_t[component]})-$signed({smoothed[component][31],smoothed[component]}),$signed({16'd0,alpha_q}),EMA1);
    EMA1:begin
     if(!fits32(ema_value))reject(3);
     else begin next_s[component]<=ema_value;
      if(component==5)begin inverse_select<=0;state<=DET0;end else begin component<=component+1'b1;state<=EMA0;end
     end
    end
    DET0:multiply(ia,id,DET1);
    DET1:begin temp<=product_result;multiply(ib,ic,DET2);end
    DET2:begin
     if(det_magnitude<={2'b0,min_det_q})reject(2);
     else begin determinant<=det_value;inverse_component<=0;state<=DIV0;end
    end
    DIV0:begin
     quotient<=(cofactor<0?{31'd0,-$unsigned(cofactor)}:{31'd0,$unsigned(cofactor)})<<32;
     divisor<=determinant<0?-$unsigned(determinant):$unsigned(determinant);
     div_negative<=cofactor[32]^determinant[65];remainder<=0;div_step<=0;state<=DIVIDE;
    end
    DIVIDE:begin quotient<=next_quotient;remainder<=take?trial-{1'b0,divisor}:trial;
     if(div_step==63)state<=DIVSAVE;else div_step<=div_step+1'b1;
    end
    DIVSAVE:begin
     if(quotient>(div_negative?64'd2147483648:64'd2147483647))reject(3);
     else begin
      if(inverse_select)case(inverse_component)
       0:inv_s[0]<=div_negative?-$signed(quotient):$signed(quotient);1:inv_s[1]<=div_negative?-$signed(quotient):$signed(quotient);
       2:inv_s[3]<=div_negative?-$signed(quotient):$signed(quotient);3:inv_s[4]<=div_negative?-$signed(quotient):$signed(quotient);endcase
      else case(inverse_component)
       0:inv_t[0]<=div_negative?-$signed(quotient):$signed(quotient);1:inv_t[1]<=div_negative?-$signed(quotient):$signed(quotient);
       2:inv_t[3]<=div_negative?-$signed(quotient):$signed(quotient);3:inv_t[4]<=div_negative?-$signed(quotient):$signed(quotient);endcase
      if(inverse_component==3)begin component<=2;state<=IT0;end
      else begin inverse_component<=inverse_component+1'b1;state<=DIV0;end
     end
    end
    IT0:multiply(inv0,itx,IT1);
    IT1:begin temp<=product_result;multiply(inv1,ity,IT2);end
    IT2:begin
     if(!fits32(translation_value))reject(3);
     else begin
      if(inverse_select)inv_s[component]<=translation_value;else inv_t[component]<=translation_value;
      if(component==2)begin component<=5;state<=IT0;end else state<=INVEND;
     end
    end
    INVEND:begin
     if(!inverse_select)begin inverse_select<=1;state<=DET0;end
     else begin component<=0;comp_stage<=1;state<=COMP0;end
    end
    COMMIT:begin
     for(k=0;k<6;k=k+1)begin trajectory[k]<=next_t[k];smoothed[k]<=next_s[k];end
     m_c00<=result_c[0];m_c01<=result_c[1];m_c02<=result_c[2];m_c10<=result_c[3];m_c11<=result_c[4];m_c12<=result_c[5];
     m_w00<=result_w[0];m_w01<=result_w[1];m_w02<=result_w[2];m_w10<=result_w[3];m_w11<=result_w[4];m_w12<=result_w[5];
     m_model_valid<=1;m_valid<=1;error_code<=0;state<=OUT;
    end
    OUT:if(m_ready)begin m_valid<=0;done<=1;state<=IDLE;end
    default:reject(5);
   endcase
  end
 end
endmodule
