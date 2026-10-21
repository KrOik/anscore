// Quantized Sauvola, exact integer contract documented in README.md.
// Full-frame synchronous RAM; one shared bit-serial multiplier and divider.
module sauvola_frame #(
 parameter BITS=8,WIDTH=32,HEIGHT=32,RADIUS=1,K_Q8=51,R=(1<<(BITS-1))
)(
 input wire clk,rst,ce,
 input wire[BITS-1:0] s_gray,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg m_binary,
 output reg[2*BITS-1:0] m_threshold,output reg[BITS-1:0] m_mean,m_stddev,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg marker_error,arithmetic_error,
 output wire busy
);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 localparam PIXELS=WIDTH*HEIGHT,AW=PIXELS<2?1:$clog2(PIXELS);
 localparam SIDE=2*RADIUS+1,N=SIDE*SIDE,CW=$clog2(N+1);
 localparam SW=BITS+CW,QW=2*BITS+CW,MW=2*BITS+18,BCW=$clog2(MW+1);
 localparam CAPTURE=0,ADDR=1,READ=2,SAMPLE=3,MULTIPLY=4,ACCUM=5,STATS=6,
 DIVIDE=7,MEAN_DONE=8,SS_DONE=9,NS_DONE=10,VAR_DONE=11,SQRT=12,
 FACTOR=13,THRESH_DONE=14,RESULT=15,OUTPUT=16,DONE=17;
 reg[4:0] state,mul_return,div_return;
 reg[BITS-1:0] frame_mem[0:PIXELS-1],frame_q,center_pixel;
 reg[AW-1:0] capture_addr,read_addr;
 reg[XW-1:0] capture_x,x;reg[YW-1:0] capture_y,y;
 reg[3:0] wx,wy;
 reg[SW-1:0] sum;
 reg[QW-1:0] sum_sq;
 reg[MW-1:0] multiplicand,multiplier,product,product_result,squared_sum;
 reg[BCW-1:0] mul_bit,div_bit;
 reg[MW-1:0] dividend,divisor,quotient,division_result;
 reg[MW:0] remainder;
 reg[2*BITS-1:0] sqrt_source;
 reg[BITS-1:0] sqrt_root;
 reg[BITS+1:0] sqrt_remainder;
 reg[$clog2(BITS+1)-1:0] sqrt_bit;
 integer sample_x,sample_y;
 wire[MW-1:0] product_next=product+(multiplier[0]?multiplicand:0);
 wire[MW:0] div_trial={remainder[MW-1:0],dividend[MW-1]};
 wire div_subtract=div_trial>={1'b0,divisor};
 wire[MW-1:0] quotient_next={quotient[MW-2:0],div_subtract};
 wire[BITS+1:0] sqrt_trial={sqrt_remainder[BITS-1:0],sqrt_source[2*BITS-1:2*BITS-2]};
 wire[BITS+1:0] sqrt_test=({2'b0,sqrt_root}<<2)|1;
 wire sqrt_subtract=sqrt_trial>=sqrt_test;
 wire[BITS-1:0] root_next=(sqrt_root<<1)|sqrt_subtract;
 function[MW-1:0] scaled_stddev;
 input[BITS-1:0] value;integer bit_index;
 begin
 scaled_stddev=0;
 for(bit_index=0;bit_index<9;bit_index=bit_index+1)
 if((K_Q8>>bit_index)&1)scaled_stddev=scaled_stddev+({{(MW-BITS){1'b0}},value}<<bit_index);
 end
 endfunction
 assign s_ready=!rst&&ce&&state==CAPTURE;
 assign m_valid=!rst&&state==OUTPUT;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_eol&&y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=CAPTURE||capture_addr!=0;
 always @* begin
 sample_x=$signed({1'b0,x})+wx-RADIUS;
 sample_y=$signed({1'b0,y})+wy-RADIUS;
 if(sample_x<0)sample_x=0;else if(sample_x>=WIDTH)sample_x=WIDTH-1;
 if(sample_y<0)sample_y=0;else if(sample_y>=HEIGHT)sample_y=HEIGHT-1;
 end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAPTURE&&s_valid&&s_ready)frame_mem[capture_addr]<=s_gray;
 if(state==READ)frame_q<=frame_mem[read_addr];
 end
 initial if(BITS<8||BITS>12||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||RADIUS<1||RADIUS>7||K_Q8<0||K_Q8>256||R<1||R>((1<<BITS)-1))$fatal(1,"invalid Sauvola parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=CAPTURE;capture_addr<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;wx<=0;wy<=0;read_addr<=0;
 center_pixel<=0;sum<=0;sum_sq<=0;m_binary<=0;m_threshold<=0;m_mean<=0;m_stddev<=0;
 marker_error<=0;arithmetic_error<=0;multiplicand<=0;multiplier<=0;product<=0;product_result<=0;squared_sum<=0;mul_bit<=0;mul_return<=0;
 dividend<=0;divisor<=0;quotient<=0;division_result<=0;remainder<=0;div_bit<=0;div_return<=0;
 sqrt_source<=0;sqrt_root<=0;sqrt_remainder<=0;sqrt_bit<=0;
 end else if(ce)case(state)
 CAPTURE:if(s_valid&&s_ready)begin
 if(capture_addr==0)begin marker_error<=0;arithmetic_error<=0;end
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))marker_error<=1;
 if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
 if(capture_addr==PIXELS-1)begin
 capture_addr<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;wx<=0;wy<=0;sum<=0;sum_sq<=0;state<=ADDR;
 end else capture_addr<=capture_addr+1'b1;
 end
 ADDR:begin read_addr<=sample_y*WIDTH+sample_x;state<=READ;end
 READ:state<=SAMPLE;
 SAMPLE:begin
 if(wx==RADIUS&&wy==RADIUS)center_pixel<=frame_q;
 sum<=sum+frame_q;
 multiplicand<=frame_q;multiplier<=frame_q;product<=0;mul_bit<=0;mul_return<=ACCUM;state<=MULTIPLY;
 end
 MULTIPLY:begin
 product<=product_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(mul_bit==MW-1)begin product_result<=product_next;state<=mul_return;end else mul_bit<=mul_bit+1'b1;
 end
 ACCUM:begin
 sum_sq<=sum_sq+product_result;
 if(wx==SIDE-1&&wy==SIDE-1)state<=STATS;
 else begin if(wx==SIDE-1)begin wx<=0;wy<=wy+1'b1;end else wx<=wx+1'b1;state<=ADDR;end
 end
 STATS:begin dividend<=sum;divisor<=N;quotient<=0;remainder<=0;div_bit<=0;div_return<=MEAN_DONE;state<=DIVIDE;end
 DIVIDE:begin
 dividend<=dividend<<1;quotient<=quotient_next;
 remainder<=div_subtract?div_trial-{1'b0,divisor}:div_trial;
 if(div_bit==MW-1)begin division_result<=quotient_next;state<=div_return;end else div_bit<=div_bit+1'b1;
 end
 MEAN_DONE:begin
 m_mean<=division_result;
 multiplicand<=sum;multiplier<=sum;product<=0;mul_bit<=0;mul_return<=SS_DONE;state<=MULTIPLY;
 end
 SS_DONE:begin
 squared_sum<=product_result;
 multiplicand<=sum_sq;multiplier<=N;product<=0;mul_bit<=0;mul_return<=NS_DONE;state<=MULTIPLY;
 end
 NS_DONE:begin
 if(product_result<squared_sum)begin arithmetic_error<=1;dividend<=0;end
 else dividend<=product_result-squared_sum;
 divisor<=N*N;quotient<=0;remainder<=0;div_bit<=0;div_return<=VAR_DONE;state<=DIVIDE;
 end
 VAR_DONE:begin sqrt_source<=division_result;sqrt_root<=0;sqrt_remainder<=0;sqrt_bit<=0;state<=SQRT;end
 SQRT:begin
 sqrt_source<=sqrt_source<<2;sqrt_root<=root_next;
 sqrt_remainder<=sqrt_subtract?sqrt_trial-sqrt_test:sqrt_trial;
 if(sqrt_bit==BITS-1)begin m_stddev<=root_next;state<=FACTOR;end else sqrt_bit<=sqrt_bit+1'b1;
 end
 FACTOR:begin
 // Constant K and R multiplication is shifts/adds in synthesis; no variable '*'.
 multiplicand<=m_mean;multiplier<=(256-K_Q8)*R+scaled_stddev(m_stddev);
 product<=0;mul_bit<=0;mul_return<=THRESH_DONE;state<=MULTIPLY;
 end
 THRESH_DONE:begin dividend<=product_result;divisor<=256*R;quotient<=0;remainder<=0;div_bit<=0;div_return<=RESULT;state<=DIVIDE;end
 RESULT:begin m_threshold<=division_result;m_binary<=center_pixel>division_result;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
 else begin
 if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
 wx<=0;wy<=0;sum<=0;sum_sq<=0;state<=ADDR;
 end
 end
 DONE:if(done_ready)state<=CAPTURE;
 default:state<=CAPTURE;
 endcase
 end
endmodule
