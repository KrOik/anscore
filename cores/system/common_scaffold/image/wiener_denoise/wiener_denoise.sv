// Integer local adaptive Wiener, exact central moment and one final rounding.
module wiener_denoise #(parameter MAX_SIDE=32)(
 input wire clk,rst_n,ce,start_valid, output wire start_ready,
 input wire[5:0]cfg_width,cfg_height,input wire cfg_window5,
 input wire[15:0]cfg_noise_variance,input wire abort,
 input wire[7:0]s_data,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]m_data,output wire m_valid,output reg m_sof,m_eol,m_last,
 input wire m_ready,output wire done_valid,input wire done_ready,
 output wire done_error,output reg[7:0]error_code,output wire busy
);
 localparam IDLE=0,CAPTURE=1,INIT=2,ADDR=3,WAITRAM=4,SAMPLE=5,
  MOMENT=6,VARIANCE=7,DECIDE=8,FIRST=9,SECOND=10,NUMERATOR=11,
  OUTPUT=12,NEXT=13,COMPLETE=14,FAILED=15,MSTART=16,MSTEP=17,DSTART=18,DSTEP=19,RESULT=20;
 reg[4:0]state,ret;
 localparam DEPTH=(MAX_SIDE>=1&&MAX_SIDE<=32)?MAX_SIDE*MAX_SIDE:1;
 reg[7:0]mem[0:DEPTH-1];reg[9:0]rd_addr,wr_addr;reg[7:0]rd;
 reg[5:0]width,height,cx,cy,ox,oy;reg window5;reg[15:0]noise;
 reg[2:0]nx,ny;wire[2:0]radius=window5?2:1;wire[2:0]lastn=window5?4:2;
 wire[4:0]count=window5?25:9;
 reg[12:0]sum;reg[20:0]sumsq;reg[7:0]center;
 reg[31:0]variance,scaled_noise,denominator;
 reg[47:0]partial;
 reg[31:0]mul_a;reg[15:0]mul_b;reg[47:0]mul_acc,mul_shift;reg[4:0]mul_count;
 reg[47:0]div_n,div_q;reg[32:0]div_r;reg[31:0]div_d;reg[5:0]div_count;
 wire[32:0]trial={div_r[31:0],div_n[47]};
 integer ax,ay;
 always @* begin
  ax=$signed({1'b0,ox})+$signed({1'b0,nx})-$signed({1'b0,radius});
  ay=$signed({1'b0,oy})+$signed({1'b0,ny})-$signed({1'b0,radius});
  if(ax<0)ax=0;else if(ax>=width)ax=width-1;
  if(ay<0)ay=0;else if(ay>=height)ay=height-1;
 end
 wire marker_bad=(s_sof!=(cx==0&&cy==0)) || (s_eol!=(cx==width-1)) || (s_last!=(cx==width-1&&cy==height-1));
 assign start_ready=rst_n&&ce&&state==IDLE&&!abort;
 assign s_ready=rst_n&&ce&&state==CAPTURE&&!abort;
 assign m_valid=rst_n&&state==OUTPUT&&!abort;
 assign done_valid=rst_n&&(state==COMPLETE||state==FAILED);
 assign done_error=state==FAILED;
 assign busy=state!=IDLE&&state!=COMPLETE&&state!=FAILED;
 // No asynchronous frame reads or frame-wide reset.
 always @(posedge clk)if(ce)begin
  rd<=mem[rd_addr];
  if(state==CAPTURE&&s_valid&&s_ready&&!marker_bad)mem[wr_addr]<=s_data;
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;error_code<=0;rd_addr<=0;wr_addr<=0;m_data<=0;m_sof<=0;m_eol<=0;m_last<=0;
   width<=0;height<=0;window5<=0;noise<=0;cx<=0;cy<=0;ox<=0;oy<=0;
   nx<=0;ny<=0;sum<=0;sumsq<=0;center<=0;variance<=0;scaled_noise<=0;denominator<=0;
   partial<=0;mul_a<=0;mul_b<=0;mul_acc<=0;mul_shift<=0;mul_count<=0;ret<=0;
   div_n<=0;div_q<=0;div_r<=0;div_d<=1;div_count<=0;
  end else if(ce)begin
   if(abort&&busy)begin state<=FAILED;error_code<=8'h93;end
   else case(state)
    IDLE:if(start_valid&&start_ready)begin
     error_code<=0;m_data<=0;m_sof<=0;m_eol<=0;m_last<=0;
     if(MAX_SIDE<1||MAX_SIDE>32||cfg_width==0||cfg_height==0||cfg_width>MAX_SIDE||cfg_height>MAX_SIDE)begin state<=FAILED;error_code<=8'h80;end
     else begin width<=cfg_width;height<=cfg_height;window5<=cfg_window5;noise<=cfg_noise_variance;
      wr_addr<=0;cx<=0;cy<=0;state<=CAPTURE;end
    end
    CAPTURE:if(s_valid&&s_ready)begin
     if(marker_bad)begin state<=FAILED;error_code<=8'h81;end
     else if(cx==width-1&&cy==height-1)begin ox<=0;oy<=0;state<=INIT;end
     else begin wr_addr<=wr_addr+1;if(cx==width-1)begin cx<=0;cy<=cy+1;end else cx<=cx+1;end
    end
    INIT:begin nx<=0;ny<=0;sum<=0;sumsq<=0;state<=ADDR;end
    ADDR:begin rd_addr<=ay*width+ax;state<=WAITRAM;end
    WAITRAM:state<=SAMPLE;
    SAMPLE:begin
     sum<=sum+rd;sumsq<=sumsq+rd*rd;
     if(nx==radius&&ny==radius)center<=rd;
     if(nx==lastn&&ny==lastn)state<=MOMENT;
     else begin if(nx==lastn)begin nx<=0;ny<=ny+1;end else nx<=nx+1;state<=ADDR;end
    end
    MOMENT:begin mul_a<=sum;mul_b<=sum;ret<=VARIANCE;state<=MSTART;end
    VARIANCE:begin
     variance<=(window5?({11'b0,sumsq}<<4)+({11'b0,sumsq}<<3)+sumsq:({11'b0,sumsq}<<3)+sumsq)-mul_acc;
     scaled_noise<=window5?({16'b0,noise}<<9)+({16'b0,noise}<<6)+({16'b0,noise}<<5)+({16'b0,noise}<<4)+noise:({16'b0,noise}<<6)+({16'b0,noise}<<4)+noise;
     state<=DECIDE;
    end
    DECIDE:begin
     if(variance<=scaled_noise)begin div_n<=sum+(count>>1);div_d<=count;ret<=RESULT;state<=DSTART;end
     else begin mul_a<=scaled_noise;mul_b<=sum;ret<=FIRST;state<=MSTART;
      denominator<=window5?(variance<<4)+(variance<<3)+variance:(variance<<3)+variance;end
    end
    FIRST:begin partial<=mul_acc;mul_a<=variance-scaled_noise;mul_b<=count*center;ret<=SECOND;state<=MSTART;end
    SECOND:begin div_n<=partial+mul_acc+(denominator>>1);div_d<=denominator;ret<=RESULT;state<=DSTART;end
    MSTART:begin mul_shift<={16'b0,mul_a};mul_acc<=0;mul_count<=0;state<=MSTEP;end
    MSTEP:begin
     if(mul_b[0])mul_acc<=mul_acc+mul_shift;
     mul_shift<=mul_shift<<1;mul_b<=mul_b>>1;mul_count<=mul_count+1;
     if(mul_count==15)state<=ret;
    end
    DSTART:begin div_r<=0;div_q<=0;div_count<=0;state<=DSTEP;end
    DSTEP:begin
     div_n<=div_n<<1;div_q<={div_q[46:0],trial>={1'b0,div_d}};
     div_r<=trial>={1'b0,div_d}?trial-{1'b0,div_d}:trial;
     div_count<=div_count+1;if(div_count==47)state<=ret;
    end
    RESULT:begin
     m_data<=div_q>255?255:div_q[7:0];m_sof<=ox==0&&oy==0;m_eol<=ox==width-1;m_last<=ox==width-1&&oy==height-1;state<=OUTPUT;
    end
    OUTPUT:if(m_ready)begin if(ox==width-1&&oy==height-1)state<=COMPLETE;
     else begin if(ox==width-1)begin ox<=0;oy<=oy+1;end else ox<=ox+1;state<=INIT;end end
    COMPLETE,FAILED:if(done_ready)begin state<=IDLE;error_code<=0;end
    default:begin state<=FAILED;error_code<=8'h94;end
   endcase
  end
 end
endmodule
