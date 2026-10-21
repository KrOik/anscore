// General homogeneous reprojection Q*[x,y,disparity,1], then XYZ/W.
// Q and disparity are signed fixed point; output rounds nearest, ties away from zero.
module disparity_reproject #(
 parameter WIDTH=16,HEIGHT=8,DISP_BITS=24,DISP_FRAC=4,
 parameter Q_BITS=32,Q_FRAC=16,OUT_BITS=32,OUT_FRAC=12
)(input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire[3:0] cfg_index,input wire signed[Q_BITS-1:0] cfg_value,
 input wire cfg_commit_valid,output wire cfg_commit_ready,output reg cfg_error,
 input wire start_valid,output wire start_ready,
 input wire signed[DISP_BITS-1:0] s_disparity,input wire s_invalid,
 input wire s_valid,output wire s_ready,input wire s_sof,s_eol,s_last,
 output reg signed[OUT_BITS-1:0] m_x,m_y,m_z,
 output reg m_invalid,m_wzero,m_wnegative,output reg[2:0] m_saturated,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[2:0] error_code
);
 localparam IDLE=0,INPUT=1,MUL_INIT=2,MUL_STEP=3,MUL_SAVE=4,H_DONE=5,DIV_INIT=6,DIV_STEP=7,DIV_ROUND=8,DIV_SAVE=9,HOLD=10,DONE=11;
 reg[3:0] state;
 reg signed[Q_BITS-1:0] shadow[0:15],active_q[0:15];reg[15:0] written;reg configured;
 integer x,y,pixel,row,col,step,axis;integer i;
 reg signed[31:0] vector[0:3];reg signed[63:0] homogeneous[0:3],accumulator;
 reg[31:0] multiplier;reg[63:0] multiplicand,mul_sum;reg mul_negative;
 wire[63:0] mul_next=mul_sum+(multiplier[0]?multiplicand:64'd0);
 reg signed[31:0] qa,vb;
 reg[95:0] numerator,quotient,rounded;reg[64:0] remainder;reg[63:0] denominator;reg div_negative;
 wire[64:0] shifted_remainder={remainder[63:0],numerator[95]};
 localparam[95:0] POS_LIMIT=(96'd1<<(OUT_BITS-1))-1,NEG_LIMIT=96'd1<<(OUT_BITS-1);
 wire saturate=rounded>(div_negative?NEG_LIMIT:POS_LIMIT);
 reg signed[OUT_BITS-1:0] result;
 always @*begin
  qa=active_q[row*4+col];vb=vector[col];
  if(saturate)result=div_negative?{1'b1,{(OUT_BITS-1){1'b0}}}:{1'b0,{(OUT_BITS-1){1'b1}}};
  else result=div_negative?-$signed(rounded[OUT_BITS-1:0]):$signed(rounded[OUT_BITS-1:0]);
 end
 assign cfg_ready=rst_n&&ce&&state==IDLE&&!start_valid&&!cfg_commit_valid;
 assign cfg_commit_ready=rst_n&&ce&&state==IDLE&&!start_valid;
 assign start_ready=rst_n&&ce&&state==IDLE&&configured&&!cfg_valid&&!cfg_commit_valid;
 assign s_ready=rst_n&&ce&&state==INPUT;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&pixel==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_valid&&pixel==WIDTH*HEIGHT-1;
 assign done_valid=rst_n&&state==DONE;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536||DISP_BITS<2||DISP_BITS>24||DISP_FRAC<0||DISP_FRAC>12||Q_BITS<2||Q_BITS>32||Q_FRAC<0||Q_FRAC>28||OUT_BITS<2||OUT_BITS>32||OUT_FRAC<0||OUT_FRAC>16)$fatal(1,"disparity_reproject invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin state<=IDLE;configured<=0;written<=0;cfg_error<=0;pixel<=0;x<=0;y<=0;row<=0;col<=0;axis<=0;step<=0;done_error<=0;error_code<=0;m_x<=0;m_y<=0;m_z<=0;m_invalid<=0;m_wzero<=0;m_wnegative<=0;m_saturated<=0;end
  else if(ce)begin
   case(state)
    IDLE:begin
     if(cfg_commit_valid&&cfg_commit_ready)begin
      if(written!=16'hffff)cfg_error<=1;
      else begin for(i=0;i<16;i=i+1)active_q[i]<=shadow[i];configured<=1;written<=0;cfg_error<=0;end
     end else if(cfg_valid&&cfg_ready)begin shadow[cfg_index]<=cfg_value;written[cfg_index]<=1;cfg_error<=0;end
     else if(start_valid&&start_ready)begin pixel<=0;x<=0;y<=0;done_error<=0;error_code<=0;state<=INPUT;end
    end
    INPUT:if(s_valid)begin
     if(s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==WIDTH*HEIGHT-1))begin done_error<=1;error_code<=1;state<=DONE;end
     else begin
      m_x<=0;m_y<=0;m_z<=0;m_saturated<=0;m_wzero<=0;m_wnegative<=0;m_invalid<=s_invalid;
      if(s_invalid)state<=HOLD;
      else begin vector[0]<=x<<DISP_FRAC;vector[1]<=y<<DISP_FRAC;vector[2]<=s_disparity;vector[3]<=32'd1<<DISP_FRAC;row<=0;col<=0;accumulator<=0;state<=MUL_INIT;end
     end
    end
    MUL_INIT:begin
     multiplier<=vb<0?-$signed(vb):vb;multiplicand<={32'd0,(qa<0?-$signed(qa):qa)};mul_sum<=0;mul_negative<=qa[31]^vb[31];step<=0;state<=MUL_STEP;
    end
    MUL_STEP:begin
     mul_sum<=mul_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
     if(step==31)state<=MUL_SAVE;else step<=step+1;
    end
    MUL_SAVE:begin
     if(col==3)begin homogeneous[row]<=accumulator+(mul_negative?-$signed(mul_sum):$signed(mul_sum));accumulator<=0;col<=0;
      if(row==3)state<=H_DONE;else begin row<=row+1;state<=MUL_INIT;end
     end else begin accumulator<=accumulator+(mul_negative?-$signed(mul_sum):$signed(mul_sum));col<=col+1;state<=MUL_INIT;end
    end
    H_DONE:begin
     m_wnegative<=homogeneous[3]<0;
     if(homogeneous[3]==0)begin m_invalid<=1;m_wzero<=1;state<=HOLD;end
     else begin axis<=0;state<=DIV_INIT;end
    end
    DIV_INIT:begin
     numerator<={32'd0,(homogeneous[axis]<0?-$signed(homogeneous[axis]):homogeneous[axis])}<<OUT_FRAC;
     denominator<=homogeneous[3]<0?-$signed(homogeneous[3]):homogeneous[3];
     div_negative<=homogeneous[axis][63]^homogeneous[3][63];quotient<=0;remainder<=0;step<=0;state<=DIV_STEP;
    end
    DIV_STEP:begin
     numerator<=numerator<<1;quotient<=quotient<<1;
     if(shifted_remainder>={1'b0,denominator})begin remainder<=shifted_remainder-{1'b0,denominator};quotient[0]<=1;end
     else remainder<=shifted_remainder;
     if(step==95)state<=DIV_ROUND;else step<=step+1;
    end
    DIV_ROUND:begin rounded<=quotient+(({remainder,1'b0}>={2'b0,denominator})?96'd1:96'd0);state<=DIV_SAVE;end
    DIV_SAVE:begin
     case(axis)0:m_x<=result;1:m_y<=result;2:m_z<=result;endcase
     if(saturate)begin m_saturated[axis]<=1;m_invalid<=1;end
     if(axis==2)state<=HOLD;else begin axis<=axis+1;state<=DIV_INIT;end
    end
    HOLD:if(m_ready)begin
     if(pixel==WIDTH*HEIGHT-1)state<=DONE;
     else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=INPUT;end
    end
    DONE:if(done_ready)state<=IDLE;
    default:begin state<=DONE;done_error<=1;error_code<=2;end
   endcase
  end
 end
endmodule
