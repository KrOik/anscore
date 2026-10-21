// Marker watershed: raw elevation priority, FIFO discovery age, label on push.
module watershed_priority_frame #(parameter BITS=8,LABEL_BITS=8,WIDTH=32,HEIGHT=32)(
 input wire clk,rst,ce,cfg_connect8,
 input wire[BITS-1:0] s_elevation,input wire[LABEL_BITS-1:0] s_seed,
 input wire s_domain,s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg[LABEL_BITS-1:0] m_label,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire m_sof,m_eol,m_last,output reg m_domain,m_invalid,
 output wire done_valid,input wire done_ready,output reg[3:0] error_code,
 output reg[$clog2(WIDTH*HEIGHT+1)-1:0] seed_count,assigned_count,popped_count,
 output wire busy
);
 localparam N=WIDTH*HEIGHT,AW=N<2?1:$clog2(N),CW=$clog2(N+1),GW=$clog2(2*N+1);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 localparam FW=1+GW+LABEL_BITS;
 localparam CAP=0,EVAL=1,ADDR=2,READ=3,SCAN=4,CHOOSE=5,POP=6,NA=7,NR=8,NC=9,PUSH=10,OA=11,OR=12,OC=13,OUT=14,DONE=15;
 reg[3:0] state;
 reg[BITS:0] terrain[0:N-1],tq;
 reg[FW-1:0] flood[0:N-1],fq;
 reg[AW-1:0] ca,sa,ra,ba,oa;
 reg[XW-1:0] cx,x,bx;reg[YW-1:0] cy,y,by;
 reg conn,found;reg[BITS-1:0] best_height;reg[GW-1:0] best_age,next_age;
 reg[LABEL_BITS-1:0] best_label;reg[CW-1:0] frontier;
 reg[2:0] ni;integer nx,ny;
 wire qopen=fq[FW-1];wire[GW-1:0] qage=fq[LABEL_BITS+:GW];
 wire[LABEL_BITS-1:0] qlabel=fq[LABEL_BITS-1:0];
 wire neighbor_ok=nx>=0&&nx<WIDTH&&ny>=0&&ny<HEIGHT&&(conn||ni<4);
 assign s_ready=!rst&&ce&&state==CAP;assign m_valid=!rst&&state==OUT;
 assign m_x=x;assign m_y=y;assign m_sof=m_valid&&x==0&&y==0;
 assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;assign busy=state!=CAP||ca!=0;
 initial if(BITS<8||BITS>12||LABEL_BITS<1||LABEL_BITS>16||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>4096)$fatal(1,"invalid watershed geometry");
 always @* begin
 nx=$signed({1'b0,bx});ny=$signed({1'b0,by});
 case(ni)
 0:ny=ny-1;1:nx=nx-1;2:nx=nx+1;3:ny=ny+1;
 4:begin nx=nx-1;ny=ny-1;end 5:begin nx=nx+1;ny=ny-1;end
 6:begin nx=nx-1;ny=ny+1;end 7:begin nx=nx+1;ny=ny+1;end
 endcase end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAP&&s_valid)begin terrain[ca]<={s_domain,s_elevation};flood[ca]<={s_domain&&s_seed!=0,{{(GW-AW){1'b0}},ca},s_seed};end
 if(state==READ||state==NR||state==OR)begin tq<=terrain[ra];fq<=flood[ra];end
 if(state==POP)flood[ba]<={1'b0,best_age,best_label};
 if(state==PUSH)flood[ra]<={1'b1,next_age,best_label};
 end
 task advance_neighbor;begin if(ni==7)begin sa<=0;x<=0;y<=0;found<=0;state<=ADDR;end else begin ni<=ni+1'b1;state<=NA;end end endtask
 always @(posedge clk)begin
 if(rst)begin state<=CAP;ca<=0;cx<=0;cy<=0;sa<=0;ra<=0;ba<=0;oa<=0;x<=0;y<=0;bx<=0;by<=0;conn<=0;found<=0;best_height<=0;best_age<=0;best_label<=0;next_age<=N;frontier<=0;ni<=0;error_code<=0;seed_count<=0;assigned_count<=0;popped_count<=0;m_label<=0;m_domain<=0;m_invalid<=0;end
 else if(ce)case(state)
 CAP:if(s_valid)begin
 if(ca==0)begin conn<=cfg_connect8;error_code<={2'b0,(!s_domain&&s_seed!=0),(s_sof!=1||s_eol!=(WIDTH==1))};seed_count<=s_domain&&s_seed!=0;popped_count<=0;end
 else begin if(s_sof||s_eol!=(cx==WIDTH-1))error_code[0]<=1;if(!s_domain&&s_seed!=0)error_code[1]<=1;if(s_domain&&s_seed!=0)seed_count<=seed_count+1'b1;end
 if(ca==N-1)state<=EVAL;else begin ca<=ca+1'b1;if(cx==WIDTH-1)begin cx<=0;cy<=cy+1'b1;end else cx<=cx+1'b1;end
 end
 EVAL:begin assigned_count<=seed_count;frontier<=seed_count;next_age<=N;sa<=0;x<=0;y<=0;oa<=0;found<=0;
 if(seed_count==0)begin error_code[2]<=1;state<=OA;end else if(error_code!=0)state<=OA;else state<=ADDR;end
 ADDR:if(frontier==0)begin oa<=0;x<=0;y<=0;state<=OA;end else begin ra<=sa;state<=READ;end
 READ:state<=SCAN;
 SCAN:begin
 if(qopen&&(!found||tq[BITS-1:0]<best_height||(tq[BITS-1:0]==best_height&&qage<best_age)))begin found<=1;ba<=sa;bx<=x;by<=y;best_height<=tq[BITS-1:0];best_age<=qage;best_label<=qlabel;end
 if(sa==N-1)state<=CHOOSE;else begin sa<=sa+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=ADDR;end end
 CHOOSE:if(found)state<=POP;else begin error_code[3]<=1;oa<=0;x<=0;y<=0;state<=OA;end
 POP:begin frontier<=frontier-1'b1;popped_count<=popped_count+1'b1;ni<=0;state<=NA;end
 NA:if(neighbor_ok)begin ra<=ny*WIDTH+nx;state<=NR;end else advance_neighbor;
 NR:state<=NC;
 NC:if(tq[BITS]&&qlabel==0)begin if(assigned_count==N)begin error_code[3]<=1;oa<=0;x<=0;y<=0;state<=OA;end else state<=PUSH;end else advance_neighbor;
 PUSH:begin frontier<=frontier+1'b1;assigned_count<=assigned_count+1'b1;next_age<=next_age+1'b1;advance_neighbor;end
 OA:begin ra<=oa;state<=OR;end OR:state<=OC;
 OC:begin m_label<=qlabel;m_domain<=tq[BITS];m_invalid<=error_code!=0||!tq[BITS]||qlabel==0;state<=OUT;end
 OUT:if(m_ready)begin if(oa==N-1)state<=DONE;else begin oa<=oa+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=OA;end end
 DONE:if(done_ready)begin state<=CAP;ca<=0;cx<=0;cy<=0;end
 endcase end
endmodule
