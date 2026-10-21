// Bounded full-frame integer Lloyd clustering; no external model state.
module kmeans_rgb_frame #(parameter WIDTH=7,HEIGHT=5)(
 input clk,rst_n,ce,
 input start_valid,output start_ready,
 input [2:0] cfg_k,input [7:0] cfg_max_iterations,cfg_tolerance,
 input [31:0] cfg_seed,
 input [23:0] s_rgb,input s_valid,s_sof,s_eol,output s_ready,
 output reg [23:0] m_rgb,output reg [1:0] m_label,
 output reg m_valid,input m_ready,output reg m_sof,m_eol,m_last,
 output reg [95:0] initial_centers,output [95:0] final_centers,
 output [43:0] cluster_counts,output reg [7:0] iterations,
 output reg converged,output reg [31:0] inertia,
 output done_valid,input done_ready,output reg done_error,
 output reg [3:0] error_code,output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,CAP=1,SEED=2,SEEDREAD=3,SEEDLOAD=4,CLEAR=5,
 READ=6,LOAD=7,DIST=8,SQUARE=9,ADD=10,NEXTCENTER=11,ASSIGN=12,
 UPDATE=13,QUOT=14,ITEREND=15,OUT=16,DONE=17,DIVIDE=18;
 reg [4:0] state,ret;
 reg [23:0] frame_mem[0:N-1];
 reg [23:0] center[0:3];
 reg [17:0] sums[0:11];reg [10:0] counts[0:3];
 reg [23:0] pixel,ram_q;
 reg [10:0] pos;reg [10:0] x;
 reg [2:0] kval,ci,ui;reg [1:0] ch,uch,best;
 reg [7:0] maxiter,tol,movement;
 reg [31:0] rng;
 reg final_pass;
 reg [17:0] distance_sum,best_distance;
 reg [7:0] mul_a,mul_b;reg [15:0] mul_acc,mul_shift;
 reg [3:0] mul_step;
 reg [31:0] div_num,div_quot;reg [11:0] div_rem,div_den;
 reg [5:0] div_step;
 wire [12:0] trial={div_rem,div_num[31]};
 wire [7:0] pv=(pixel>>(ch*8));
 wire [7:0] cv=(center[ci]>>(ch*8));
 wire [7:0] oldv=(center[ui]>>(uch*8));
 wire [7:0] newv=div_quot[7:0];
 wire [7:0] delta=(newv>oldv)?newv-oldv:oldv-newv;
 assign start_ready=ce&&(state==IDLE);
 assign s_ready=ce&&(state==CAP);
 assign done_valid=(state==DONE);
 assign busy=(state!=IDLE);
 assign final_centers={center[3],center[2],center[1],center[0]};
 assign cluster_counts={counts[3],counts[2],counts[1],counts[0]};
 function [31:0] next_rng(input [31:0] a);
 reg [31:0] b;begin b=a^(a<<13);b=b^(b>>17);next_rng=b^(b<<5);end endfunction
 task divide(input [31:0] a,input [11:0] b,input [4:0] r);
 begin div_num<=a;div_den<=b;div_rem<=0;div_quot<=0;div_step<=0;ret<=r;state<=DIVIDE;end endtask
 integer j;
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=IDLE;m_valid<=0;m_rgb<=0;m_label<=0;m_sof<=0;m_eol<=0;m_last<=0;
 initial_centers<=0;iterations<=0;converged<=0;inertia<=0;done_error<=0;error_code<=0;
 for(j=0;j<4;j=j+1)begin center[j]<=0;counts[j]<=0;end
 end else if(ce) begin
 case(state)
 IDLE:if(start_valid)begin
 done_error<=0;error_code<=0;
 if(cfg_k<2||cfg_k>4||cfg_max_iterations==0||N<1||N>1024||WIDTH<1||WIDTH>1024||HEIGHT<1||HEIGHT>1024)begin
 done_error<=1;error_code<=1;state<=DONE;
 end else begin kval<=cfg_k;maxiter<=cfg_max_iterations;tol<=cfg_tolerance;rng<=cfg_seed==0?1:cfg_seed;
 pos<=0;x<=0;iterations<=0;converged<=0;inertia<=0;initial_centers<=0;
 for(j=0;j<4;j=j+1)begin center[j]<=0;counts[j]<=0;end state<=CAP;end end
 CAP:if(s_valid)begin frame_mem[pos]<=s_rgb;
 if(s_sof!=(pos==0)||s_eol!=(x==WIDTH-1))begin done_error<=1;error_code<=2;end
 if(x==WIDTH-1)x<=0;else x<=x+1;
 if(pos==N-1)begin ci<=0;state<=SEED;end else pos<=pos+1;end
 SEED:divide(rng,N,SEEDREAD);
 SEEDREAD:begin ram_q<=frame_mem[div_rem];state<=SEEDLOAD;end
 SEEDLOAD:begin center[ci]<=ram_q;initial_centers[ci*24+:24]<=ram_q;rng<=next_rng(rng);
 if(ci==kval-1)begin final_pass<=0;state<=CLEAR;end else begin ci<=ci+1;state<=SEED;end end
 CLEAR:begin for(j=0;j<12;j=j+1)sums[j]<=0;for(j=0;j<4;j=j+1)counts[j]<=0;
 pos<=0;x<=0;inertia<=0;state<=READ;end
 READ:begin ram_q<=frame_mem[pos];state<=LOAD;end
 LOAD:begin pixel<=ram_q;ci<=0;ch<=0;distance_sum<=0;best_distance<=18'h3ffff;best<=0;state<=DIST;end
 DIST:begin mul_a<=pv>cv?pv-cv:cv-pv;mul_b<=pv>cv?pv-cv:cv-pv;
 mul_acc<=0;mul_step<=0;mul_shift<={8'b0,(pv>cv?pv-cv:cv-pv)};state<=SQUARE;end
 SQUARE:begin if(mul_b[0])mul_acc<=mul_acc+mul_shift;mul_shift<=mul_shift<<1;mul_b<=mul_b>>1;
 if(mul_step==7)state<=ADD;else mul_step<=mul_step+1;end
 ADD:begin distance_sum<=distance_sum+mul_acc;
 if(ch==2)state<=NEXTCENTER;else begin ch<=ch+1;state<=DIST;end end
 NEXTCENTER:begin if(distance_sum<best_distance)begin best_distance<=distance_sum;best<=ci[1:0];end
 if(ci==kval-1)state<=ASSIGN;else begin ci<=ci+1;ch<=0;distance_sum<=0;state<=DIST;end end
 ASSIGN:begin counts[best]<=counts[best]+1;
 if(final_pass)begin inertia<=inertia+best_distance;m_rgb<=center[best];m_label<=best;
 m_valid<=1;m_sof<=pos==0;m_eol<=x==WIDTH-1;m_last<=pos==N-1;state<=OUT;end
 else begin sums[best*3]<=sums[best*3]+pixel[7:0];sums[best*3+1]<=sums[best*3+1]+pixel[15:8];sums[best*3+2]<=sums[best*3+2]+pixel[23:16];
 if(pos==N-1)begin ui<=0;uch<=0;movement<=0;state<=UPDATE;end else begin pos<=pos+1;state<=READ;end end end
 UPDATE:if(counts[ui]==0)begin
 if(ui==kval-1)state<=ITEREND;else begin ui<=ui+1;uch<=0;end
 end else divide({14'b0,sums[ui*3+uch]}+(counts[ui]>>1),{1'b0,counts[ui]},QUOT);
 QUOT:begin center[ui][uch*8+:8]<=newv;if(delta>movement)movement<=delta;
 if(uch==2)begin if(ui==kval-1)state<=ITEREND;else begin ui<=ui+1;uch<=0;state<=UPDATE;end end
 else begin uch<=uch+1;state<=UPDATE;end end
 ITEREND:begin iterations<=iterations+1;
 if(movement<=tol||iterations+1==maxiter)begin converged<=movement<=tol;final_pass<=1;end
 state<=CLEAR;end
 OUT:if(m_ready)begin m_valid<=0;if(pos==N-1)state<=DONE;else begin pos<=pos+1;if(x==WIDTH-1)x<=0;else x<=x+1;state<=READ;end end
 DONE:if(done_ready)state<=IDLE;
 DIVIDE:begin div_num<=div_num<<1;
 if(trial>={1'b0,div_den})begin div_rem<=trial-div_den;div_quot<={div_quot[30:0],1'b1};end
 else begin div_rem<=trial[11:0];div_quot<={div_quot[30:0],1'b0};end
 if(div_step==31)state<=ret;else div_step<=div_step+1;end
 default:state<=IDLE;
 endcase end end
endmodule
