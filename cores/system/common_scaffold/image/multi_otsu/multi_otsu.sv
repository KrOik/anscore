// Three-class Otsu, exhaustive nonempty-class optimization with exact rationals.
module multi_otsu #(parameter MAX_SIDE=32)(
 input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire[5:0]cfg_width,cfg_height,input wire[7:0]cfg_level0,cfg_level1,cfg_level2,input wire abort,
 input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]m_data,output reg[1:0]m_class,output wire m_valid,
 output reg m_sof,m_eol,m_last,input wire m_ready,
 output reg[7:0]threshold0,threshold1,
 output wire done_valid,input wire done_ready,output wire done_error,output reg[7:0]error_code,output wire busy
);
 localparam IDLE=0,CLEAR=1,CAPTURE=2,HWAIT=3,HWRITE=4,PADDR=5,PWAIT=6,PSAMPLE=7,PFIN=8,
 OADDR=9,OWAIT=10,OLOAD=11,IADDR=12,IWAIT=13,ILOAD=14,COEFF=15,C0=16,C1=17,C2=18,DRET=19,
 SQR0=20,TERM0=21,SQR1=22,TERM1=23,SQR2=24,TERM2=25,LEFTRET=26,RIGHTRET=27,NEXT=28,
 EMIT=29,FADDR=30,FWAIT=31,FVALUE=32,OUTPUT=33,COMPLETE=34,FAILED=35,MSTART=36,MSTEP=37;
 localparam DEPTH=(MAX_SIDE>=1&&MAX_SIDE<=32)?MAX_SIDE*MAX_SIDE:1;
 reg[5:0]state,ret;
 reg[7:0]frame[0:DEPTH-1];reg[7:0]frame_q;reg[9:0]frame_addr,wr_idx,out_idx;
 reg[10:0]hist[0:255];reg[10:0]hist_q;reg[7:0]hist_addr,clear_idx,bin;
 reg[36:0]prefix[0:255];reg[36:0]prefix_q;reg[7:0]prefix_addr;
 reg[5:0]width,height,cx,cy,ox,oy;reg[7:0]level0,level1,level2;
 reg[10:0]total_count,run_count;reg[17:0]total_sum,run_sum;reg capture_last;
 reg[8:0]levels;reg[7:0]i0,i1,t0,t1;
 wire[10:0]next_count=run_count+hist_q;
 wire[17:0]next_sum=run_sum+hist_q*bin;
 reg[10:0]n0,n1,n2;reg[17:0]s0,s1,s2;
 reg[31:0]w0,w1,w2,den,best_den;reg[63:0]candidate_a,running_a,best_a;
 reg best_valid;reg[7:0]best_t0,best_t1;reg[95:0]left_product;
 reg[63:0]mul_a;reg[31:0]mul_b;reg[95:0]mul_acc,mul_shift;reg[5:0]mul_count,mul_steps;
 wire marker_bad=(s_sof!=(cx==0&&cy==0))||(s_eol!=(cx==width-1))||(s_last!=(cx==width-1&&cy==height-1));
 assign start_ready=rst_n&&ce&&state==IDLE&&!abort;
 assign s_ready=rst_n&&ce&&state==CAPTURE&&!abort;
 assign m_valid=rst_n&&state==OUTPUT&&!abort;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE&&state!=COMPLETE&&state!=FAILED;
 task multiply(input[63:0]a,input[31:0]b,input[5:0]steps,input[5:0]return_state);
 begin mul_a<=a;mul_b<=b;mul_steps<=steps;ret<=return_state;state<=MSTART;end endtask
 always @(posedge clk)if(ce)begin
  frame_q<=frame[frame_addr];hist_q<=hist[hist_addr];prefix_q<=prefix[prefix_addr];
  if(state==CAPTURE&&s_valid&&s_ready&&!marker_bad)frame[wr_idx]<=s_data;
  if(state==CLEAR)hist[clear_idx]<=0;
  else if(state==HWRITE)hist[hist_addr]<=hist_q+1;
  if(state==PSAMPLE&&hist_q!=0)prefix[levels[7:0]]<={bin,next_count,next_sum};
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;ret<=0;error_code<=0;frame_addr<=0;wr_idx<=0;out_idx<=0;hist_addr<=0;clear_idx<=0;bin<=0;prefix_addr<=0;
   width<=0;height<=0;cx<=0;cy<=0;ox<=0;oy<=0;level0<=0;level1<=0;level2<=0;
   total_count<=0;total_sum<=0;run_count<=0;run_sum<=0;capture_last<=0;levels<=0;i0<=0;i1<=0;t0<=0;t1<=0;
   n0<=0;n1<=0;n2<=0;s0<=0;s1<=0;s2<=0;w0<=0;w1<=0;w2<=0;den<=0;best_den<=0;
   candidate_a<=0;running_a<=0;best_a<=0;best_valid<=0;best_t0<=0;best_t1<=0;left_product<=0;
   mul_a<=0;mul_b<=0;mul_acc<=0;mul_shift<=0;mul_count<=0;mul_steps<=0;
   m_data<=0;m_class<=0;m_sof<=0;m_eol<=0;m_last<=0;threshold0<=0;threshold1<=0;
  end else if(ce)begin
   if(abort&&busy)begin state<=FAILED;error_code<=8'h93;end
   else case(state)
    IDLE:if(start_valid&&start_ready)begin
     error_code<=0;threshold0<=0;threshold1<=0;m_data<=0;m_class<=0;m_sof<=0;m_eol<=0;m_last<=0;best_valid<=0;
     if(MAX_SIDE<1||MAX_SIDE>32||cfg_width==0||cfg_height==0||cfg_width>MAX_SIDE||cfg_height>MAX_SIDE)begin state<=FAILED;error_code<=8'h80;end
     else if(cfg_level0>=cfg_level1||cfg_level1>=cfg_level2)begin state<=FAILED;error_code<=8'h82;end
     else begin
      width<=cfg_width;height<=cfg_height;level0<=cfg_level0;level1<=cfg_level1;level2<=cfg_level2;
      clear_idx<=0;wr_idx<=0;cx<=0;cy<=0;total_count<=0;total_sum<=0;state<=CLEAR;
     end
    end
    CLEAR:if(clear_idx==255)state<=CAPTURE;else clear_idx<=clear_idx+1;
    CAPTURE:if(s_valid&&s_ready)begin
     if(marker_bad)begin state<=FAILED;error_code<=8'h81;end
     else begin
      total_count<=total_count+1;total_sum<=total_sum+s_data;hist_addr<=s_data;
      capture_last<=cx==width-1&&cy==height-1;state<=HWAIT;
      if(cx==width-1)begin cx<=0;cy<=cy+1;end else cx<=cx+1;
     end
    end
    HWAIT:state<=HWRITE;
    HWRITE:if(capture_last)begin bin<=0;run_count<=0;run_sum<=0;levels<=0;state<=PADDR;end
      else begin wr_idx<=wr_idx+1;state<=CAPTURE;end
    PADDR:begin hist_addr<=bin;state<=PWAIT;end
    PWAIT:state<=PSAMPLE;
    PSAMPLE:begin
     run_count<=next_count;run_sum<=next_sum;if(hist_q!=0)levels<=levels+1;
     if(bin==255)state<=PFIN;else begin bin<=bin+1;state<=PADDR;end
    end
    PFIN:if(levels<3)begin state<=FAILED;error_code<=8'h90;end
      else begin i0<=0;state<=OADDR;end
    OADDR:begin prefix_addr<=i0;state<=OWAIT;end
    OWAIT:state<=OLOAD;
    OLOAD:begin t0<=prefix_q[36:29];n0<=prefix_q[28:18];s0<=prefix_q[17:0];i1<=i0+1;state<=IADDR;end
    IADDR:begin prefix_addr<=i1;state<=IWAIT;end
    IWAIT:state<=ILOAD;
    ILOAD:begin t1<=prefix_q[36:29];n1<=prefix_q[28:18]-n0;s1<=prefix_q[17:0]-s0;n2<=total_count-prefix_q[28:18];s2<=total_sum-prefix_q[17:0];state<=COEFF;end
    COEFF:multiply({53'b0,n1},{21'b0,n2},11,C0);
    C0:begin w0<=mul_acc[31:0];multiply({53'b0,n0},{21'b0,n2},11,C1);end
    C1:begin w1<=mul_acc[31:0];multiply({53'b0,n0},{21'b0,n1},11,C2);end
    C2:begin w2<=mul_acc[31:0];multiply(mul_acc[63:0],{21'b0,n2},11,DRET);end
    DRET:begin den<=mul_acc[31:0];multiply({46'b0,s0},{14'b0,s0},18,SQR0);end
    SQR0:multiply(mul_acc[63:0],w0,20,TERM0);
    TERM0:begin running_a<=mul_acc[63:0];multiply({46'b0,s1},{14'b0,s1},18,SQR1);end
    SQR1:multiply(mul_acc[63:0],w1,20,TERM1);
    TERM1:begin running_a<=running_a+mul_acc[63:0];multiply({46'b0,s2},{14'b0,s2},18,SQR2);end
    SQR2:multiply(mul_acc[63:0],w2,20,TERM2);
    TERM2:begin
     candidate_a<=running_a+mul_acc[63:0];
     if(!best_valid)begin best_a<=running_a+mul_acc[63:0];best_den<=den;best_t0<=t0;best_t1<=t1;best_valid<=1;state<=NEXT;end
     else multiply(running_a+mul_acc[63:0],best_den,32,LEFTRET);
    end
    LEFTRET:begin left_product<=mul_acc;multiply(best_a,den,32,RIGHTRET);end
    RIGHTRET:begin
     if(left_product>mul_acc)begin best_a<=candidate_a;best_den<=den;best_t0<=t0;best_t1<=t1;end
     state<=NEXT;
    end
    NEXT:if(i1==levels-2)begin if(i0==levels-3)state<=EMIT;else begin i0<=i0+1;state<=OADDR;end end
      else begin i1<=i1+1;state<=IADDR;end
    EMIT:begin threshold0<=best_t0;threshold1<=best_t1;out_idx<=0;ox<=0;oy<=0;state<=FADDR;end
    FADDR:begin frame_addr<=out_idx;state<=FWAIT;end
    FWAIT:state<=FVALUE;
    FVALUE:begin
     if(frame_q<=threshold0)begin m_data<=level0;m_class<=0;end
     else if(frame_q<=threshold1)begin m_data<=level1;m_class<=1;end
     else begin m_data<=level2;m_class<=2;end
     m_sof<=out_idx==0;m_eol<=ox==width-1;m_last<=out_idx==total_count-1;state<=OUTPUT;
    end
    OUTPUT:if(m_ready)begin
     if(out_idx==total_count-1)state<=COMPLETE;
     else begin out_idx<=out_idx+1;if(ox==width-1)begin ox<=0;oy<=oy+1;end else ox<=ox+1;state<=FADDR;end
    end
    COMPLETE,FAILED:if(done_ready)begin state<=IDLE;error_code<=0;end
    MSTART:begin mul_shift<={32'b0,mul_a};mul_acc<=0;mul_count<=0;state<=MSTEP;end
    MSTEP:begin
     if(mul_b[0])mul_acc<=mul_acc+mul_shift;
     mul_shift<=mul_shift<<1;mul_b<=mul_b>>1;mul_count<=mul_count+1;
     if(mul_count==mul_steps-1)state<=ret;
    end
    default:begin state<=FAILED;error_code<=8'h94;end
   endcase
  end
 end
endmodule
