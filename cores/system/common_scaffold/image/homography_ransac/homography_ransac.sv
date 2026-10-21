// Bounded perspective RANSAC. Q24 normalized solve, shared serial arithmetic.
module homography_ransac(
 input wire clk,rst_n,ce,
 input wire signed [15:0] s_x,s_y,s_u,s_v,
 input wire s_first,s_last,s_valid,output wire s_ready,
 input wire [6:0] cfg_count,input wire [15:0] cfg_iterations,
 input wire [31:0] cfg_seed,cfg_threshold,
 output reg signed [63:0] h00,h01,h02,h10,h11,h12,h20,h21,h22,
 output reg [63:0] inlier_mask,output wire [63:0] refit_mask,output reg [6:0] best_count,
 output reg [63:0] best_residual,
 output reg [15:0] hypotheses,degenerate_count,overflow_count,
 output reg model_valid,m_valid,input wire m_ready,
 output wire busy,done,output reg [3:0] error_code
);
 localparam signed [63:0] ONE=64'sd16777216;
 localparam CAP=0,PICK=1,CLEAR=2,POINT=3,PR=4,PV=5,PREP=6,
  ROW=7,ACC=8,AR=9,AV=10,AS=11,AN=12,
  PIV=13,PIREAD=14,PIVAL=15,PSCAN=16,SWAP=17,SWR=18,SWV=19,SWR2=20,SWV2=21,SWW=22,
  NORM=23,NR=24,NV=25,NS=26,ELROW=27,ER=28,EV=29,ELCOL=30,ECR=31,ECV=32,ECR2=33,ECV2=34,ECS=35,
  SOL=36,SR=37,SV=38,SCORE0=39,SCORE1=40,SCORE2=41,PROJECT=42,PROJRET=43,
  SCOREPOINT=44,NEXTMODEL=45,FINISH=46,OUT=47,MUL=48,DIV=49,ALUDONE=50,
  DEG0=51,DEG1=52,DEG2=53;
 reg [5:0] state,ret_state;
 reg [63:0] points[0:63],point_q;
 reg [5:0] point_addr;
 reg signed [63:0] matrix[0:71],matrix_q;
 reg [6:0] matrix_addr;
 reg signed [63:0] vec[0:8],model[0:7];
 reg [5:0] selected[0:3];
 reg [63:0] sample_point[0:3];
 reg [1:0] triplet;
 reg destination_check;
 wire [1:0] da=triplet==3?2'd1:2'd0;
 wire [1:0] db=triplet<2?2'd1:2'd2;
 wire [1:0] dc=triplet==0?2'd2:2'd3;
 wire signed [15:0] ax=destination_check?sample_point[da][31:16]:sample_point[da][63:48];
 wire signed [15:0] ay=destination_check?sample_point[da][15:0]:sample_point[da][47:32];
 wire signed [15:0] bx=destination_check?sample_point[db][31:16]:sample_point[db][63:48];
 wire signed [15:0] by=destination_check?sample_point[db][15:0]:sample_point[db][47:32];
 wire signed [15:0] cx=destination_check?sample_point[dc][31:16]:sample_point[dc][63:48];
 wire signed [15:0] cy=destination_check?sample_point[dc][15:0]:sample_point[dc][47:32];
 wire signed [16:0] dx1=$signed({bx[15],bx})-$signed({ax[15],ax});
 wire signed [16:0] dy1=$signed({by[15],by})-$signed({ay[15],ay});
 wire signed [16:0] dx2=$signed({cx[15],cx})-$signed({ax[15],ax});
 wire signed [16:0] dy2=$signed({cy[15],cy})-$signed({ay[15],ay});
 reg [6:0] count_q,loaded,pindex;
 reg [15:0] budget;
 reg [31:0] rng,threshold_q;
 reg [2:0] pick,prep_step;
 reg refit,equation;
 reg [63:0] chosen,best_mask,score_mask;
 reg [6:0] score_count;
 reg [63:0] score_sum;
 reg signed [63:0] x,y,u,v,ux,uy,vx,vy;
 reg [3:0] i,j,k,pivot_row,search_row,elim_row;
 reg signed [63:0] pivot,pivot_max,cell_value,swap_value,factor,pivot_value;
 reg [3:0] project_step;
 reg signed [63:0] nx,ny,den,pu,pv;
 reg [127:0] mul_acc,mul_shift;
 reg [63:0] mul_factor;
 reg [6:0] alu_step;
 reg alu_negative,alu_bad;
 reg [127:0] quotient;
 reg [63:0] divisor;
 reg [64:0] remainder;
 reg signed [63:0] alu_result;
 wire [127:0] mul_next=mul_acc+(mul_factor[0]?mul_shift:128'd0);
 wire signed [127:0] mul_signed=alu_negative?-$signed(mul_next):$signed(mul_next);
 wire signed [127:0] mul_scaled=mul_signed>>>24;
 wire [64:0] trial={remainder[63:0],quotient[127]};
 wire take=trial>={1'b0,divisor};
 wire [127:0] div_next={quotient[126:0],take};
 wire signed [127:0] div_signed=alu_negative?-$signed(div_next):$signed(div_next);
 wire signed [63:0] abs_q=matrix_q<0?-matrix_q:matrix_q;
 wire [63:0] abs_du=pu-u<0?-(pu-u):pu-u;
 wire [63:0] abs_dv=pv-v<0?-(pv-v):pv-v;
 wire [64:0] residual={1'b0,abs_du}+{1'b0,abs_dv};
 wire [32:0] normalized_threshold={threshold_q,1'b0};
 assign s_ready=rst_n&&ce&&state==CAP;
 assign busy=state!=CAP&&state!=OUT;
 assign done=m_valid;
 assign refit_mask=best_mask;
 function [31:0] random_next;
 input [31:0] a;reg [31:0] b;
 begin b=a^(a<<13);b=b^(b>>17);random_next=b^(b<<5);end
 endfunction
 function coord_ok;
 input signed [15:0] a;
 begin coord_ok=a>=-127&&a<=127;end
 endfunction
 function add_ok;
 input signed [63:0] a,b;
 reg signed [64:0] c;
 begin c={a[63],a}+{b[63],b};add_ok=c[64]==c[63];end
 endfunction
 task multiply;
 input signed [63:0] a,b;input [5:0] target;
 begin
  mul_acc<=0;mul_shift<={64'd0,(a<0?-$unsigned(a):$unsigned(a))};
  mul_factor<=b<0?-$unsigned(b):$unsigned(b);
  alu_negative<=a[63]^b[63];alu_step<=0;alu_bad<=0;ret_state<=target;state<=MUL;
 end endtask
 task divide;
 input signed [63:0] a,b;input [5:0] target;
 begin
  quotient<=({64'd0,(a<0?-$unsigned(a):$unsigned(a))}<<24);
  divisor<=b<0?-$unsigned(b):$unsigned(b);remainder<=0;
  alu_negative<=a[63]^b[63];alu_step<=0;alu_bad<=b==0;ret_state<=target;state<=DIV;
 end endtask
 task reject;
 input overflowed;
 begin
  if(overflowed)overflow_count<=overflow_count+1'b1;
  else degenerate_count<=degenerate_count+1'b1;
  if(refit)begin error_code<=4;model_valid<=0;state<=FINISH;end
  else begin score_count<=0;score_sum<=64'hffffffffffffffff;state<=NEXTMODEL;end
 end endtask
 always @(posedge clk)if(ce)begin
  point_q<=points[point_addr];matrix_q<=matrix[matrix_addr];
 end
 integer n;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAP;loaded<=0;m_valid<=0;model_valid<=0;error_code<=0;
   inlier_mask<=0;best_count<=0;best_residual<=0;
   hypotheses<=0;degenerate_count<=0;overflow_count<=0;
   h00<=0;h01<=0;h02<=0;h10<=0;h11<=0;h12<=0;h20<=0;h21<=0;h22<=0;
   count_q<=0;point_addr<=0;matrix_addr<=0;refit<=0;chosen<=0;best_mask<=0;
  end else if(ce)case(state)
   CAP:if(s_valid)begin
    if((loaded==0&&!s_first)||(loaded!=0&&s_first)||!coord_ok(s_x)||!coord_ok(s_y)||!coord_ok(s_u)||!coord_ok(s_v))begin
     error_code<=2;model_valid<=0;state<=FINISH;
    end else if(loaded==0&&(cfg_count<4||cfg_count>64||cfg_iterations==0))begin
     error_code<=1;model_valid<=0;state<=FINISH;
    end else if(s_last!=((loaded==0?cfg_count:count_q)==loaded+1))begin
     error_code<=2;model_valid<=0;state<=FINISH;
    end else begin
     points[loaded[5:0]]<={s_x,s_y,s_u,s_v};loaded<=loaded+1'b1;
     if(loaded==0)begin
      count_q<=cfg_count;budget<=cfg_iterations;rng<=cfg_seed==0?32'd1:cfg_seed;
      threshold_q<=cfg_threshold;hypotheses<=0;degenerate_count<=0;overflow_count<=0;
      best_count<=0;best_residual<=64'hffffffffffffffff;best_mask<=0;error_code<=0;model_valid<=0;refit<=0;
     end
     if(s_last)begin pick<=0;state<=PICK;end
    end
   end
   PICK:begin
    rng<=random_next(rng);
    if({1'b0,rng[5:0]}<count_q && (pick==0||rng[5:0]!=selected[0]) &&
       (pick<2||rng[5:0]!=selected[1]) &&(pick<3||rng[5:0]!=selected[2]))begin
     selected[pick]<=rng[5:0];
     if(pick==3)begin hypotheses<=hypotheses+1'b1;i<=0;j<=0;state<=CLEAR;end else pick<=pick+1'b1;
    end
   end
   CLEAR:begin
    matrix[i*9+j]<=0;
    if(j==8)begin j<=0;if(i==7)begin pindex<=0;state<=POINT;end else i<=i+1'b1;end else j<=j+1'b1;
   end
   POINT:begin
    if(pindex==(refit?count_q:7'd4))begin
     k<=0;if(refit)state<=PIV;else begin triplet<=0;destination_check<=0;state<=DEG0;end
    end
    else if(refit&&!best_mask[pindex])pindex<=pindex+1'b1;
    else begin point_addr<=refit?pindex[5:0]:selected[pindex[1:0]];state<=PR;end
   end
   PR:state<=PV;
   PV:begin
    if(!refit)sample_point[pindex[1:0]]<=point_q;
    x<=$signed(point_q[63:48])*64'sd131072;y<=$signed(point_q[47:32])*64'sd131072;
    u<=$signed(point_q[31:16])*64'sd131072;v<=$signed(point_q[15:0])*64'sd131072;
    prep_step<=0;state<=PREP;
   end
   PREP:case(prep_step)
    0:begin multiply(u,x,PREP);prep_step<=1;end
    1:begin ux<=alu_result;multiply(u,y,PREP);prep_step<=2;end
    2:begin uy<=alu_result;multiply(v,x,PREP);prep_step<=3;end
    3:begin vx<=alu_result;multiply(v,y,PREP);prep_step<=4;end
    4:begin vy<=alu_result;equation<=0;state<=ROW;end
   endcase
   ROW:begin
    vec[0]<=equation?0:x;vec[1]<=equation?0:y;vec[2]<=equation?0:ONE;
    vec[3]<=equation?x:0;vec[4]<=equation?y:0;vec[5]<=equation?ONE:0;
    vec[6]<=equation?-vx:-ux;vec[7]<=equation?-vy:-uy;vec[8]<=equation?v:u;
    i<=0;j<=0;state<=ACC;
   end
   ACC:begin matrix_addr<=i*9+j;state<=AR;end
   AR:state<=AV;
   AV:begin cell_value<=matrix_q;multiply(vec[i],vec[j],AS);end
   AS:if(alu_bad||!add_ok(cell_value,alu_result))reject(1);else begin matrix[i*9+j]<=cell_value+alu_result;state<=AN;end
   AN:if(j==8)begin j<=0;if(i==7)begin
    if(!equation)begin equation<=1;state<=ROW;end else begin pindex<=pindex+1'b1;state<=POINT;end
   end else begin i<=i+1'b1;state<=ACC;end end else begin j<=j+1'b1;state<=ACC;end
   PIV:begin search_row<=k;pivot_max<=0;pivot_row<=k;matrix_addr<=k*9+k;state<=PIREAD;end
   PIREAD:state<=PIVAL;
   PIVAL:begin
    if(abs_q>pivot_max)begin pivot_max<=abs_q;pivot_row<=search_row;end
    state<=PSCAN;
   end
   PSCAN:if(search_row==7)begin
    if(pivot_max<64'sd16)reject(0);else begin j<=k;state<=SWAP;end
   end else begin search_row<=search_row+1'b1;matrix_addr<=(search_row+1)*9+k;state<=PIREAD;end
   SWAP:begin matrix_addr<=k*9+j;state<=SWR;end
   SWR:state<=SWV;
   SWV:begin swap_value<=matrix_q;matrix_addr<=pivot_row*9+j;state<=SWR2;end
   SWR2:state<=SWV2;
   SWV2:begin cell_value<=matrix_q;matrix[k*9+j]<=matrix_q;if(j==k)pivot<=matrix_q;state<=SWW;end
   SWW:begin
    if(pivot_row!=k)matrix[pivot_row*9+j]<=swap_value;
    if(j==8)begin j<=k+1'b1;state<=NORM;end else begin j<=j+1'b1;state<=SWAP;end
   end
   NORM:if(j==9)begin matrix[k*9+k]<=ONE;elim_row<=0;state<=ELROW;end
    else begin matrix_addr<=k*9+j;state<=NR;end
   NR:state<=NV;
   NV:divide(matrix_q,pivot,NS);
   NS:if(alu_bad)reject(1);else begin matrix[k*9+j]<=alu_result;j<=j+1'b1;state<=NORM;end
   ELROW:if(elim_row==8)begin
    if(k==7)begin i<=0;state<=SOL;end else begin k<=k+1'b1;state<=PIV;end
   end else if(elim_row==k)elim_row<=elim_row+1'b1;
   else begin matrix_addr<=elim_row*9+k;state<=ER;end
   ER:state<=EV;
   EV:begin factor<=matrix_q;j<=k+1'b1;state<=ELCOL;end
   ELCOL:if(j==9)begin matrix[elim_row*9+k]<=0;elim_row<=elim_row+1'b1;state<=ELROW;end
    else begin matrix_addr<=k*9+j;state<=ECR;end
   ECR:state<=ECV;
   ECV:begin pivot_value<=matrix_q;matrix_addr<=elim_row*9+j;state<=ECR2;end
   ECR2:state<=ECV2;
   ECV2:begin cell_value<=matrix_q;multiply(factor,pivot_value,ECS);end
   ECS:if(alu_bad||alu_result==64'sh8000000000000000||!add_ok(cell_value,-alu_result))reject(1);
    else begin matrix[elim_row*9+j]<=cell_value-alu_result;j<=j+1'b1;state<=ELCOL;end
   SOL:begin matrix_addr<=i*9+8;state<=SR;end
   SR:state<=SV;
   SV:if(matrix_q>64'sd1099511627775||matrix_q< -64'sd1099511627775)reject(1);
    else begin model[i]<=matrix_q;if(i==7)begin pindex<=0;score_count<=0;score_sum<=0;score_mask<=0;state<=SCORE0;end else begin i<=i+1'b1;state<=SOL;end end
   SCORE0:if(pindex==count_q)state<=NEXTMODEL;
    else begin point_addr<=pindex[5:0];state<=SCORE1;end
   SCORE1:state<=SCORE2;
   SCORE2:begin
    x<=$signed(point_q[63:48])*64'sd131072;y<=$signed(point_q[47:32])*64'sd131072;
    u<=$signed(point_q[31:16])*64'sd131072;v<=$signed(point_q[15:0])*64'sd131072;
    project_step<=0;state<=PROJECT;
   end
   PROJECT:case(project_step)
    0:begin multiply(model[0],x,PROJRET);project_step<=1;end
    1:begin multiply(model[1],y,PROJRET);project_step<=2;end
    2:begin multiply(model[3],x,PROJRET);project_step<=3;end
    3:begin multiply(model[4],y,PROJRET);project_step<=4;end
    4:begin multiply(model[6],x,PROJRET);project_step<=5;end
    5:begin multiply(model[7],y,PROJRET);project_step<=6;end
    6:if(den<256&&den>-256)begin pindex<=pindex+1'b1;state<=SCORE0;end
      else begin divide(nx,den,PROJRET);project_step<=7;end
    7:begin divide(ny,den,PROJRET);project_step<=8;end
    8:state<=SCOREPOINT;
   endcase
   PROJRET:if(alu_bad)reject(1);else begin
    case(project_step)
     1:nx<=alu_result+model[2];2:nx<=nx+alu_result;
     3:ny<=alu_result+model[5];4:ny<=ny+alu_result;
     5:den<=alu_result+ONE;6:den<=den+alu_result;7:pu<=alu_result;8:pv<=alu_result;
    endcase
    state<=PROJECT;
   end
   SCOREPOINT:begin
    if(residual<={32'd0,normalized_threshold})begin
     score_count<=score_count+1'b1;score_mask[pindex]<=1;score_sum<=score_sum+residual[63:0];
    end
    pindex<=pindex+1'b1;state<=SCORE0;
   end
   DEG0:multiply($signed(dx1)*ONE,$signed(dy2)*ONE,DEG1);
   DEG1:begin cell_value<=alu_result;multiply($signed(dy1)*ONE,$signed(dx2)*ONE,DEG2);end
   DEG2:if(alu_result==cell_value)reject(0);
    else if(triplet==3)begin
     if(destination_check)state<=PIV;else begin destination_check<=1;triplet<=0;state<=DEG0;end
    end else begin triplet<=triplet+1'b1;state<=DEG0;end
   NEXTMODEL:if(refit)begin
    if(score_count<4)begin error_code<=5;model_valid<=0;end
    else begin
     h00<=model[0];h01<=model[1];h02<=model[2]<<<7;h10<=model[3];h11<=model[4];h12<=model[5]<<<7;
     h20<=model[6]>>>7;h21<=model[7]>>>7;h22<=ONE;
     inlier_mask<=score_mask;best_count<=score_count;best_residual<=score_sum>>1;model_valid<=1;
    end
    state<=FINISH;
   end else begin
    if(score_count>=4&&(score_count>best_count||(score_count==best_count&&score_sum<best_residual)))begin
     best_count<=score_count;best_residual<=score_sum;best_mask<=score_mask;
    end
    if(hypotheses==budget)begin state<=FINISH;end
    else begin pick<=0;state<=PICK;end
   end
   FINISH:if(!refit&&error_code==0&&best_count>=4)begin
    refit<=1;i<=0;j<=0;state<=CLEAR;
   end else begin
    if(!refit&&error_code==0)error_code<=3;
    m_valid<=1;state<=OUT;
   end
   OUT:if(m_ready)begin
    m_valid<=0;loaded<=0;model_valid<=0;error_code<=0;state<=CAP;
   end
   MUL:begin
    mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
    if(alu_step==63)begin
     alu_result<=mul_scaled[63:0];alu_bad<=mul_scaled[127:63]!={65{mul_scaled[63]}};state<=ret_state;
    end else alu_step<=alu_step+1'b1;
   end
   DIV:begin
    quotient<=div_next;remainder<=take?trial-{1'b0,divisor}:trial;
    if(alu_step==127)begin
     alu_result<=div_signed[63:0];alu_bad<=alu_bad||div_signed[127:63]!={65{div_signed[63]}};state<=ret_state;
    end else alu_step<=alu_step+1'b1;
   end
   default:begin error_code<=6;model_valid<=0;state<=FINISH;end
  endcase
 end
endmodule
