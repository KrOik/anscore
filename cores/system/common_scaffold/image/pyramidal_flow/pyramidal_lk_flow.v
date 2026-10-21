// Bounded dense inverse-compositional local LK, Q4 flow, 2/3 Gaussian levels.
module pyramidal_lk_flow #(
 parameter WIDTH=16,HEIGHT=16,LEVELS=3,WINDOW=5,ITERATIONS=3,
 parameter DET_THRESHOLD=10000,MAX_STEP_Q=32,MAX_FLOW_Q=32767
)(
 input wire clk,rst,ce,input wire[7:0] s_ref,s_cur,
 input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg signed[15:0] m_flow_x,m_flow_y,
 output reg m_texture_invalid,m_oob,m_overflow,output wire m_invalid,
 output wire[$clog2(WIDTH)-1:0] m_x,output wire[$clog2(HEIGHT)-1:0] m_y,
 output wire m_sof,m_eol,m_last,done_valid,input wire done_ready,
 output reg[1:0] error_code,output wire busy
);
 localparam W1=(WIDTH+1)/2,H1=(HEIGHT+1)/2,W2=(W1+1)/2,H2=(H1+1)/2;
 localparam N=WIDTH*HEIGHT,N1=W1*H1,N2=W2*H2,TOTAL=N+N1+(LEVELS==3?N2:0);
 localparam AW=$clog2(TOTAL),XW=$clog2(WIDTH),YW=$clog2(HEIGHT),R=WINDOW/2;
 localparam CAP=0,GE=1,GA=2,GR=3,GC=4,GW=5,PINIT=6,FA=7,FR=8,FC=9,FI=10,CLAMP=11,
 IINIT=12,SA=13,RR=14,RC=15,WPREP=16,WA=17,WR=18,WC=19,ACC=20,
 SOLVE=21,MSTART=22,MRUN=23,MRESULT=24,DSTART=25,DRUN=26,DRESULT=27,UPDATE=28,
 STORE=29,OUT=30,NEXT=31,DONE=32;
 reg[5:0] state;
 reg[7:0] ref_mem[0:TOTAL-1],cur_mem[0:TOTAL-1],rq,cq;
 reg signed[15:0] flow_x[0:TOTAL-1],flow_y[0:TOTAL-1],fqx,fqy;
 reg[AW-1:0] capture_addr,read_addr,write_addr;
 reg[XW-1:0] cx,x;reg[YW-1:0] cy,y;
 reg[1:0] level,gauss_level,sample_no,flow_no;reg[4:0] tap;
 reg[17:0] gauss_r,gauss_c;
 reg signed[17:0] fx,fy,init_x,init_y;
 reg signed[15:0] f00x,f10x,f01x,f11x,f00y,f10y,f01y,f11y;
 reg texture_bad,oob_bad,overflow_bad;
 reg[2:0] iteration;integer wx,wy,lw,lh,bx,by,ax,ay,gdx,gdy,warp_x,warp_y,clamped_x,clamped_y;
 reg[3:0] frac_x,frac_y;
 reg[7:0] reference_center,left_pixel,right_pixel,up_pixel,down_pixel,p00,p10,p01,p11;
 reg signed[31:0] a11,a12,a22,b1,b2;
 wire signed[9:0] gx=$signed({1'b0,right_pixel})-$signed({1'b0,left_pixel});
 wire signed[9:0] gy=$signed({1'b0,down_pixel})-$signed({1'b0,up_pixel});
 wire signed[9:0] temporal=$signed({1'b0,warped(p00,p10,p01,p11,frac_x,frac_y)})-$signed({1'b0,reference_center});
 reg[2:0] mul_phase;
 reg signed[63:0] mul_left,mul_right,product,partial,determinant,num_x,num_y,delta_x,delta_y;
 reg[63:0] ma,mb,mp,dividend,divisor,quotient,remainder;
 reg[6:0] arithmetic_count;reg arithmetic_negative,divide_y;
 wire[64:0] trial={remainder,dividend[63]};
 wire[63:0] next_rem=trial>={1'b0,divisor}?trial-divisor:trial;
 wire[63:0] next_quot={quotient[62:0],trial>={1'b0,divisor}};
 reg signed[63:0] step_x,step_y,sum_x,sum_y;
 function integer width_at;input integer l;begin case(l)0:width_at=WIDTH;1:width_at=W1;default:width_at=W2;endcase end endfunction
 function integer height_at;input integer l;begin case(l)0:height_at=HEIGHT;1:height_at=H1;default:height_at=H2;endcase end endfunction
 function[AW-1:0] address;input integer l,xx,yy;integer row,b,w;begin
 w=width_at(l);row=0;for(b=0;b<6;b=b+1)if((w>>b)&1)row=row+(yy<<b);
 address=(l==0?0:(l==1?N:N+N1))+row+xx;end endfunction
 function integer bound;input integer a,maxi;begin bound=a<0?0:(a>=maxi?maxi-1:a);end endfunction
 function[17:0] weight;input[7:0] p;input integer tx,ty;reg[13:0] v;begin
 case(tx)0,4:v=p;1,3:v=p<<2;default:v=(p<<2)+(p<<1);endcase
 case(ty)0,4:weight=v;1,3:weight=v<<2;default:weight=(v<<2)+(v<<1);endcase end endfunction
 function signed[31:0] small_mul;input signed[9:0] a,b;reg[9:0] ua,ub;reg[19:0] v;integer k;begin
 ua=a<0?-a:a;ub=b<0?-b:b;v=0;for(k=0;k<10;k=k+1)if(ub[k])v=v+({10'b0,ua}<<k);
 small_mul=(a<0)^(b<0)?-$signed({1'b0,v}):$signed({1'b0,v});end endfunction
 function signed[18:0] frac_mul;input signed[13:0] a;input[3:0] b;integer k;begin
 frac_mul=0;for(k=0;k<4;k=k+1)if(b[k])frac_mul=frac_mul+($signed(a)<<k);end endfunction
 function[7:0] warped;input[7:0] a,b,c,d;input[3:0] u,v;reg signed[13:0] h0,h1;reg signed[18:0] z;begin
 h0=($signed({1'b0,a})<<<4)+frac_mul($signed({1'b0,b})-$signed({1'b0,a}),u);
 h1=($signed({1'b0,c})<<<4)+frac_mul($signed({1'b0,d})-$signed({1'b0,c}),u);
 z=($signed(h0)<<<4)+frac_mul(h1-h0,v);warped=z>>>8;end endfunction
 assign s_ready=!rst&&ce&&state==CAP;assign m_valid=!rst&&state==OUT;
 assign m_x=x;assign m_y=y;assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
 assign m_invalid=m_texture_invalid||m_oob||m_overflow;
 assign done_valid=!rst&&state==DONE;assign busy=state!=CAP||capture_addr!=0;
 initial if(WIDTH<8||HEIGHT<8||WIDTH>32||HEIGHT>32||N>1024||LEVELS<2||LEVELS>3||WINDOW!=3&&WINDOW!=5||ITERATIONS<1||ITERATIONS>4||DET_THRESHOLD<0||MAX_STEP_Q<1||MAX_STEP_Q>128||MAX_FLOW_Q<1||MAX_FLOW_Q>32767)$fatal(1,"invalid pyramidal LK parameters");
 always @* begin
 lw=width_at(level);lh=height_at(level);bx=bound($signed({1'b0,x})+wx,lw);by=bound($signed({1'b0,y})+wy,lh);
 ax=bx;ay=by;
 case(sample_no)1:ax=bound(bx-1,lw);2:ax=bound(bx+1,lw);3:ay=bound(by-1,lh);default:begin end endcase
 // The fifth gradient read uses a separate state flag encoded by flow_no.
 if(flow_no==1)begin ax=bx;ay=bound(by+1,lh);end
 gdx=(tap%5)-2;gdy=(tap/5)-2;
 warp_x=(bx<<4)+$signed(fx);warp_y=(by<<4)+$signed(fy);
 clamped_x=bound(warp_x,((lw-1)<<4)+1);clamped_y=bound(warp_y,((lh-1)<<4)+1);
 step_x=delta_x;step_y=delta_y;
 if(step_x>MAX_STEP_Q)step_x=MAX_STEP_Q;if(step_x< -MAX_STEP_Q)step_x= -MAX_STEP_Q;
 if(step_y>MAX_STEP_Q)step_y=MAX_STEP_Q;if(step_y< -MAX_STEP_Q)step_y= -MAX_STEP_Q;
 sum_x=$signed(fx)+step_x;sum_y=$signed(fy)+step_y;
 end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAP&&s_valid)begin ref_mem[capture_addr]<=s_ref;cur_mem[capture_addr]<=s_cur;end
 if(state==GR||state==RR||state==WR)begin rq<=ref_mem[read_addr];cq<=cur_mem[read_addr];end
 if(state==GW)begin ref_mem[write_addr]<=(gauss_r+128)>>8;cur_mem[write_addr]<=(gauss_c+128)>>8;end
 if(state==FR)begin fqx<=flow_x[read_addr];fqy<=flow_y[read_addr];end
 if(state==STORE)begin flow_x[write_addr]<=fx;flow_y[write_addr]<=fy;end
 end
 always @(posedge clk)begin
 if(rst)begin
 state<=CAP;capture_addr<=0;read_addr<=0;write_addr<=0;cx<=0;cy<=0;x<=0;y<=0;level<=0;gauss_level<=1;tap<=0;sample_no<=0;flow_no<=0;
 gauss_r<=0;gauss_c<=0;fx<=0;fy<=0;init_x<=0;init_y<=0;texture_bad<=0;oob_bad<=0;overflow_bad<=0;iteration<=0;wx<=0;wy<=0;
 frac_x<=0;frac_y<=0;reference_center<=0;left_pixel<=0;right_pixel<=0;up_pixel<=0;down_pixel<=0;p00<=0;p10<=0;p01<=0;p11<=0;
 f00x<=0;f10x<=0;f01x<=0;f11x<=0;f00y<=0;f10y<=0;f01y<=0;f11y<=0;
 a11<=0;a12<=0;a22<=0;b1<=0;b2<=0;mul_phase<=0;mul_left<=0;mul_right<=0;product<=0;partial<=0;determinant<=0;num_x<=0;num_y<=0;delta_x<=0;delta_y<=0;
 ma<=0;mb<=0;mp<=0;dividend<=0;divisor<=0;quotient<=0;remainder<=0;arithmetic_count<=0;arithmetic_negative<=0;divide_y<=0;
 m_flow_x<=0;m_flow_y<=0;m_texture_invalid<=0;m_oob<=0;m_overflow<=0;error_code<=0;
 end else if(ce)case(state)
 CAP:if(s_valid)begin
 if(capture_addr==0)error_code<={1'b0,(!s_sof||s_eol!=(WIDTH==1))};else if(s_sof||s_eol!=(cx==WIDTH-1))error_code[0]<=1;
 if(capture_addr==N-1)state<=GE;else begin capture_addr<=capture_addr+1'b1;if(cx==WIDTH-1)begin cx<=0;cy<=cy+1'b1;end else cx<=cx+1'b1;end end
 GE:if(error_code!=0)state<=DONE;else begin gauss_level<=1;level<=0;x<=0;y<=0;tap<=0;gauss_r<=0;gauss_c<=0;state<=GA;end
 GA:begin read_addr<=address(gauss_level-1,bound((x<<1)+gdx,width_at(gauss_level-1)),bound((y<<1)+gdy,height_at(gauss_level-1)));state<=GR;end
 GR:state<=GC;
 GC:begin gauss_r<=gauss_r+weight(rq,tap%5,tap/5);gauss_c<=gauss_c+weight(cq,tap%5,tap/5);
 if(tap==24)begin write_addr<=address(gauss_level,x,y);state<=GW;end else begin tap<=tap+1'b1;state<=GA;end end
 GW:begin tap<=0;gauss_r<=0;gauss_c<=0;
 if(x==width_at(gauss_level)-1)begin x<=0;if(y==height_at(gauss_level)-1)begin y<=0;if(gauss_level==LEVELS-1)begin level<=LEVELS-1;state<=PINIT;end else begin gauss_level<=gauss_level+1'b1;state<=GA;end end else begin y<=y+1'b1;state<=GA;end end else begin x<=x+1'b1;state<=GA;end end
 PINIT:begin texture_bad<=0;oob_bad<=0;overflow_bad<=0;iteration<=0;
 if(level==LEVELS-1)begin init_x<=0;init_y<=0;state<=CLAMP;end else begin flow_no<=0;state<=FA;end end
 FA:begin read_addr<=address(level+1,bound((x>>1)+(flow_no==1||flow_no==3),width_at(level+1)),bound((y>>1)+(flow_no>=2),height_at(level+1)));state<=FR;end
 FR:state<=FC;
 FC:begin case(flow_no)0:begin f00x<=fqx;f00y<=fqy;end 1:begin f10x<=fqx;f10y<=fqy;end 2:begin f01x<=fqx;f01y<=fqy;end 3:begin f11x<=fqx;f11y<=fqy;end endcase
 if(flow_no==3)state<=FI;else begin flow_no<=flow_no+1'b1;state<=FA;end end
 FI:begin
 case({y[0],x[0]})
 0:begin init_x<=$signed(f00x)*2;init_y<=$signed(f00y)*2;end
 1:begin init_x<=$signed(f00x)+$signed(f10x);init_y<=$signed(f00y)+$signed(f10y);end
 2:begin init_x<=$signed(f00x)+$signed(f01x);init_y<=$signed(f00y)+$signed(f01y);end
 3:begin init_x<=($signed({f00x[15],f00x})+$signed({f10x[15],f10x})+$signed({f01x[15],f01x})+$signed({f11x[15],f11x}))>>>1;init_y<=($signed({f00y[15],f00y})+$signed({f10y[15],f10y})+$signed({f01y[15],f01y})+$signed({f11y[15],f11y}))>>>1;end
 endcase state<=CLAMP;end
 CLAMP:begin fx<=init_x>MAX_FLOW_Q?MAX_FLOW_Q:(init_x< -MAX_FLOW_Q?-MAX_FLOW_Q:init_x);fy<=init_y>MAX_FLOW_Q?MAX_FLOW_Q:(init_y< -MAX_FLOW_Q?-MAX_FLOW_Q:init_y);
 if(init_x>MAX_FLOW_Q||init_x< -MAX_FLOW_Q||init_y>MAX_FLOW_Q||init_y< -MAX_FLOW_Q)overflow_bad<=1;state<=IINIT;end
 IINIT:begin a11<=0;a12<=0;a22<=0;b1<=0;b2<=0;wx<= -R;wy<= -R;sample_no<=0;flow_no<=0;state<=SA;end
 SA:begin read_addr<=address(level,ax,ay);state<=RR;end
 RR:state<=RC;
 RC:begin
 if(flow_no==1)begin down_pixel<=rq;flow_no<=0;state<=WPREP;end else begin
 case(sample_no)0:reference_center<=rq;1:left_pixel<=rq;2:right_pixel<=rq;3:up_pixel<=rq;endcase
 if(sample_no==3)flow_no<=1;else sample_no<=sample_no+1'b1;state<=SA;end end
 WPREP:begin
 if(warp_x<0||warp_y<0||warp_x>((lw-1)<<4)||warp_y>((lh-1)<<4))oob_bad<=1;
 frac_x<=clamped_x&15;frac_y<=clamped_y&15;sample_no<=0;state<=WA;end
 WA:begin read_addr<=address(level,bound((clamped_x>>4)+(sample_no==1||sample_no==3),lw),bound((clamped_y>>4)+(sample_no>=2),lh));state<=WR;end
 WR:state<=WC;
 WC:begin case(sample_no)0:p00<=cq;1:p10<=cq;2:p01<=cq;3:p11<=cq;endcase
 if(sample_no==3)state<=ACC;else begin sample_no<=sample_no+1'b1;state<=WA;end end
 ACC:begin a11<=a11+small_mul(gx,gx);a12<=a12+small_mul(gx,gy);a22<=a22+small_mul(gy,gy);b1<=b1+small_mul(gx,temporal);b2<=b2+small_mul(gy,temporal);
 sample_no<=0;flow_no<=0;if(wx==R)begin wx<= -R;if(wy==R)state<=SOLVE;else begin wy<=wy+1;state<=SA;end end else begin wx<=wx+1;state<=SA;end end
 SOLVE:begin mul_phase<=0;mul_left<=a11;mul_right<=a22;state<=MSTART;end
 MSTART:begin ma<=mul_left<0?-mul_left:mul_left;mb<=mul_right<0?-mul_right:mul_right;mp<=0;arithmetic_count<=0;arithmetic_negative<=(mul_left<0)^(mul_right<0);state<=MRUN;end
 MRUN:begin if(mb[0])mp<=mp+ma;ma<=ma<<1;mb<=mb>>1;if(arithmetic_count==63)begin product<=arithmetic_negative?-$signed(mp+(mb[0]?ma:0)):$signed(mp+(mb[0]?ma:0));state<=MRESULT;end else arithmetic_count<=arithmetic_count+1'b1;end
 MRESULT:case(mul_phase)
 0:begin partial<=product;mul_left<=a12;mul_right<=a12;mul_phase<=1;state<=MSTART;end
 1:begin determinant<=partial-product;if(partial-product<=DET_THRESHOLD)begin texture_bad<=1;delta_x<=0;delta_y<=0;state<=UPDATE;end else begin mul_left<=a12;mul_right<=b2;mul_phase<=2;state<=MSTART;end end
 2:begin partial<=product;mul_left<=a22;mul_right<=b1;mul_phase<=3;state<=MSTART;end
 3:begin num_x<=(partial-product)<<<5;mul_left<=a12;mul_right<=b1;mul_phase<=4;state<=MSTART;end
 4:begin partial<=product;mul_left<=a11;mul_right<=b2;mul_phase<=5;state<=MSTART;end
 5:begin num_y<=(partial-product)<<<5;divide_y<=0;state<=DSTART;end
 endcase
 DSTART:begin dividend<=divide_y?(num_y<0?-num_y:num_y):(num_x<0?-num_x:num_x);divisor<=determinant;quotient<=0;remainder<=0;arithmetic_count<=0;arithmetic_negative<=divide_y?num_y<0:num_x<0;state<=DRUN;end
 DRUN:begin remainder<=next_rem;quotient<=next_quot;dividend<=dividend<<1;if(arithmetic_count==63)begin if(divide_y)delta_y<=arithmetic_negative?-$signed(next_quot):$signed(next_quot);else delta_x<=arithmetic_negative?-$signed(next_quot):$signed(next_quot);state<=DRESULT;end else arithmetic_count<=arithmetic_count+1'b1;end
 DRESULT:if(divide_y)state<=UPDATE;else begin divide_y<=1;state<=DSTART;end
 UPDATE:begin fx<=sum_x>MAX_FLOW_Q?MAX_FLOW_Q:(sum_x< -MAX_FLOW_Q?-MAX_FLOW_Q:sum_x);fy<=sum_y>MAX_FLOW_Q?MAX_FLOW_Q:(sum_y< -MAX_FLOW_Q?-MAX_FLOW_Q:sum_y);
 if(sum_x>MAX_FLOW_Q||sum_x< -MAX_FLOW_Q||sum_y>MAX_FLOW_Q||sum_y< -MAX_FLOW_Q)overflow_bad<=1;
 if(iteration==ITERATIONS-1)begin write_addr<=address(level,x,y);state<=STORE;end else begin iteration<=iteration+1'b1;state<=IINIT;end end
 STORE:if(level==0)begin m_flow_x<=fx;m_flow_y<=fy;m_texture_invalid<=texture_bad;m_oob<=oob_bad;m_overflow<=overflow_bad;state<=OUT;end else state<=NEXT;
 OUT:if(m_ready)state<=NEXT;
 NEXT:if(x==lw-1)begin x<=0;if(y==lh-1)begin y<=0;if(level==0)state<=DONE;else begin level<=level-1'b1;state<=PINIT;end end else begin y<=y+1'b1;state<=PINIT;end end else begin x<=x+1'b1;state<=PINIT;end
 DONE:if(done_ready)begin capture_addr<=0;cx<=0;cy<=0;state<=CAP;end
 endcase end
endmodule
