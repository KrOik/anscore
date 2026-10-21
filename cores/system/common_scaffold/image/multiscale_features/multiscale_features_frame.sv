// Resource-shared multiscale FAST9/NMS/centroid/rotated-BRIEF front end.
module multiscale_features_frame #(
 parameter WIDTH=65,HEIGHT=65,BITS=8,LEVELS=3,RADIUS=3,
 parameter PATTERN_FILE=RADIUS==1?"cores/system/common_scaffold/image/oriented_brief/pattern_r1.mem":RADIUS==2?"cores/system/common_scaffold/image/oriented_brief/pattern_r2.mem":RADIUS==3?"cores/system/common_scaffold/image/oriented_brief/pattern_r3.mem":RADIUS==4?"cores/system/common_scaffold/image/oriented_brief/pattern_r4.mem":RADIUS==5?"cores/system/common_scaffold/image/oriented_brief/pattern_r5.mem":RADIUS==6?"cores/system/common_scaffold/image/oriented_brief/pattern_r6.mem":RADIUS==7?"cores/system/common_scaffold/image/oriented_brief/pattern_r7.mem":RADIUS==8?"cores/system/common_scaffold/image/oriented_brief/pattern_r8.mem":RADIUS==9?"cores/system/common_scaffold/image/oriented_brief/pattern_r9.mem":RADIUS==10?"cores/system/common_scaffold/image/oriented_brief/pattern_r10.mem":RADIUS==11?"cores/system/common_scaffold/image/oriented_brief/pattern_r11.mem":RADIUS==12?"cores/system/common_scaffold/image/oriented_brief/pattern_r12.mem":RADIUS==13?"cores/system/common_scaffold/image/oriented_brief/pattern_r13.mem":RADIUS==14?"cores/system/common_scaffold/image/oriented_brief/pattern_r14.mem":"cores/system/common_scaffold/image/oriented_brief/pattern_r15.mem"
)(input clk,rst_n,ce,input cfg_valid,output cfg_ready,input [BITS-1:0] cfg_threshold,
 input [BITS-1:0] s_pixel,input s_valid,output s_ready,input s_sof,s_eol,
 output reg [255:0] m_descriptor,output reg [3:0] m_angle,output reg m_orientation_valid,
 output reg [15:0] m_x,m_y,m_original_x,m_original_y,output reg [1:0] m_level,
 output reg [BITS-1:0] m_score,output reg m_valid,input m_ready,
 output done_valid,input done_ready,output reg frame_error,output reg [3:0] error_code);
 localparam W1=(WIDTH+1)/2,H1=(HEIGHT+1)/2,W2=(W1+1)/2,H2=(H1+1)/2;
 localparam N=WIDTH*HEIGHT,N1=W1*H1,N2=W2*H2,TOTAL=N+(LEVELS>1?N1:0)+(LEVELS>2?N2:0);
 localparam CAP=0,GREAD=1,GACC=2,GSTORE=3,FREAD=4,FCENTER=5,RREAD=6,RSTORE=7,ARC=8,SSTORE=9,
 NREAD=10,NCENTER=11,NEIGH_READ=12,NEIGH_USE=13,OREAD=14,OUSE=15,DOT=16,ANGLE=17,PREAD=18,ACQ=19,BREAD=20,CMP=21,OUT=22,NEXT=23,DONE=24;
 reg [4:0] state;
 reg [BITS-1:0] image[0:TOTAL-1],scores[0:N-1];
 reg [23:0] pattern[0:4095];
 initial begin
 if(WIDTH<1||HEIGHT<1||WIDTH>256||HEIGHT>256||N>65536||LEVELS<1||LEVELS>3||(BITS!=8&&BITS!=10&&BITS!=12)||RADIUS<1||RADIUS>15)$fatal(1,"parameters");
 $readmemh(PATTERN_FILE,pattern);
 end
 integer capture,x,y,level,lw,lh,build_level,bw,bh,gx,gy,read_addr,score_addr,idx,dir,bitno,ox,oy,nx,ny;
 reg [BITS-1:0] pixel_q,score_q,threshold,frame_threshold,center_q,center_score,a_q;
 reg signed [BITS:0] difference[0:15];
 reg [3:0] ring_i,arc_start,arc_tap;
 reg [BITS-1:0] min_b,min_d,best_strength;
 wire [3:0] selected=arc_start+arc_tap;
 wire signed [BITS:0] diff=difference[selected];
 wire [BITS-1:0] bright=diff>0?diff:0,dark=diff<0?-diff:0;
 wire [BITS-1:0] nb=bright<min_b?bright:min_b,nd=dark<min_d?dark:min_d;
 wire [BITS-1:0] strength=nb>nd?nb:nd,nbs=strength>best_strength?strength:best_strength;
 reg [BITS+8:0] gsum;
 reg signed [31:0] mx,my;
 reg signed [47:0] dot,best,termx,termy;
 reg [3:0] best_dir;reg [6:0] cm,sm;reg cn,sn;
 reg [23:0] pair_q;
 wire signed [5:0] ax=pair_q[23:18],ay=pair_q[17:12],bx=pair_q[11:6],by=pair_q[5:0];
 function integer width_at;input integer l;begin case(l)0:width_at=WIDTH;1:width_at=W1;default:width_at=W2;endcase end endfunction
 function integer height_at;input integer l;begin case(l)0:height_at=HEIGHT;1:height_at=H1;default:height_at=H2;endcase end endfunction
 function integer address;input integer l,xx,yy;begin case(l)0:address=yy*WIDTH+xx;1:address=N+yy*W1+xx;default:address=N+N1+yy*W2+xx;endcase end endfunction
 function integer score_address;input integer l,xx,yy;begin case(l)0:score_address=yy*WIDTH+xx;1:score_address=yy*W1+xx;default:score_address=yy*W2+xx;endcase end endfunction
 function integer reflect;input integer v,size;begin if(size==1)reflect=0;else begin if(v<0)v=-v;if(v>=size)v=2*size-2-v;if(v<0)v=-v;reflect=v;end end endfunction
 function integer weight;input integer t;begin case(t)0,4:weight=1;1,3:weight=4;default:weight=6;endcase end endfunction
 function integer dx;input [3:0] i;begin case(i)0,8:dx=0;1,7:dx=1;2,6:dx=2;3,4,5:dx=3;9,15:dx=-1;10,14:dx=-2;default:dx=-3;endcase end endfunction
 function integer dy;input [3:0] i;begin case(i)0,1,15:dy=-3;2,14:dy=-2;3,13:dy=-1;4,12:dy=0;5,11:dy=1;6,10:dy=2;default:dy=3;endcase end endfunction
 function signed [7:0] cosine;input integer d;begin case(d)0:cosine=127;1:cosine=117;2:cosine=90;3:cosine=49;4:cosine=0;5:cosine=-49;6:cosine=-90;7:cosine=-117;8:cosine=-127;9:cosine=-117;10:cosine=-90;11:cosine=-49;12:cosine=0;13:cosine=49;14:cosine=90;default:cosine=117;endcase end endfunction
 assign cfg_ready=rst_n&&ce&&state==CAP&&capture==0;
 assign s_ready=rst_n&&ce&&state==CAP&&!(cfg_valid&&cfg_ready);
 assign done_valid=state==DONE;
 always @* begin
 read_addr=0;
 case(state)
 GREAD:read_addr=address(build_level-1,reflect(2*x+gx-2,width_at(build_level-1)),reflect(2*y+gy-2,height_at(build_level-1)));
 FREAD:read_addr=address(level,x,y);
 RREAD:read_addr=address(level,x+dx(ring_i),y+dy(ring_i));
 OREAD:read_addr=address(level,x+ox,y+oy);
 ACQ:if(ax>=-RADIUS-1&&ax<=RADIUS+1&&ay>=-RADIUS-1&&ay<=RADIUS+1)read_addr=address(level,x+$signed(ax),y+$signed(ay));
 BREAD:read_addr=address(level,x+$signed(bx),y+$signed(by));
 default:read_addr=0;
 endcase
 score_addr=score_address(level,x,y);
 if(state==NEIGH_READ)score_addr=score_address(level,x+nx,y+ny);
 termx=0;termy=0;
 if(cm[bitno])termx=cn?-($signed(mx)<<<bitno):($signed(mx)<<<bitno);
 if(sm[bitno])termy=sn?-($signed(my)<<<bitno):($signed(my)<<<bitno);
 end
 always @(posedge clk)if(ce)begin pixel_q<=image[read_addr];score_q<=scores[score_addr];end
 task begin_level;input integer ll;begin level<=ll;lw<=width_at(ll);lh<=height_at(ll);x<=0;y<=0;state<=FREAD;end endtask
 task next_xy;input [4:0] target;begin if(x==lw-1)begin x<=0;y<=y+1;end else x<=x+1;state<=target;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=CAP;capture<=0;x<=0;y<=0;level<=0;lw<=WIDTH;lh<=HEIGHT;threshold<=20;frame_threshold<=20;frame_error<=0;error_code<=0;m_valid<=0;m_descriptor<=0;m_angle<=0;m_orientation_valid<=0;m_x<=0;m_y<=0;m_original_x<=0;m_original_y<=0;m_level<=0;m_score<=0;end
 else if(ce)case(state)
 CAP:begin
 if(cfg_valid&&cfg_ready)threshold<=cfg_threshold;
 else if(s_valid&&s_ready)begin
 if(s_sof!=(capture==0)||s_eol!=(capture%WIDTH==WIDTH-1))begin frame_error<=1;error_code<=1;state<=DONE;end
 else begin image[capture]<=s_pixel;if(capture==0)begin frame_error<=0;error_code<=0;frame_threshold<=threshold;end
 if(capture==N-1)begin capture<=0;x<=0;y<=0;if(LEVELS==1)begin_level(0);else begin build_level<=1;bw<=W1;bh<=H1;gx<=0;gy<=0;gsum<=0;state<=GREAD;end end else capture<=capture+1;end end end
 GREAD:state<=GACC;
 GACC:begin gsum<=gsum+pixel_q*weight(gx)*weight(gy);if(gx==4)begin gx<=0;if(gy==4)state<=GSTORE;else begin gy<=gy+1;state<=GREAD;end end else begin gx<=gx+1;state<=GREAD;end end
 GSTORE:begin image[address(build_level,x,y)]<=(gsum+128)>>8;gsum<=0;gx<=0;gy<=0;
 if(x==bw-1)begin x<=0;if(y==bh-1)begin y<=0;if(build_level==LEVELS-1)begin_level(0);else begin build_level<=build_level+1;bw<=width_at(build_level+1);bh<=height_at(build_level+1);state<=GREAD;end end else begin y<=y+1;state<=GREAD;end end else begin x<=x+1;state<=GREAD;end end
 FREAD:state<=FCENTER;
 FCENTER:begin center_q<=pixel_q;best_strength<=0;if(x<3||y<3||x>=lw-3||y>=lh-3)state<=SSTORE;else begin ring_i<=0;state<=RREAD;end end
 RREAD:state<=RSTORE;
 RSTORE:begin difference[ring_i]<=$signed({1'b0,pixel_q})-$signed({1'b0,center_q});if(ring_i==15)begin arc_start<=0;arc_tap<=0;min_b<={BITS{1'b1}};min_d<={BITS{1'b1}};state<=ARC;end else begin ring_i<=ring_i+1;state<=RREAD;end end
 ARC:if(arc_tap==8)begin best_strength<=nbs;if(arc_start==15)state<=SSTORE;else begin arc_start<=arc_start+1;arc_tap<=0;min_b<={BITS{1'b1}};min_d<={BITS{1'b1}};end end else begin arc_tap<=arc_tap+1;min_b<=nb;min_d<=nd;end
 SSTORE:begin scores[score_address(level,x,y)]<=best_strength>frame_threshold?best_strength-1:0;if(x==lw-1&&y==lh-1)begin x<=0;y<=0;state<=NREAD;end else next_xy(FREAD);end
 NREAD:state<=NCENTER;
 NCENTER:begin center_score<=score_q;if(score_q==0||x<RADIUS+1||y<RADIUS+1||x+RADIUS+1>=lw||y+RADIUS+1>=lh||x==0||y==0||x==lw-1||y==lh-1)state<=NEXT;else begin nx<=-1;ny<=-1;state<=NEIGH_READ;end end
 NEIGH_READ:state<=NEIGH_USE;
 NEIGH_USE:begin
 if((nx!=0||ny!=0)&&(score_q>center_score||(score_q==center_score&&(ny<0||(ny==0&&nx<0)))))state<=NEXT;
 else if(nx==1&&ny==1)begin ox<=-RADIUS;oy<=-RADIUS;mx<=0;my<=0;m_descriptor<=0;state<=OREAD;end
 else begin if(nx==1)begin nx<=-1;ny<=ny+1;end else nx<=nx+1;state<=NEIGH_READ;end end
 OREAD:state<=OUSE;
 OUSE:begin if(ox*ox+oy*oy<=RADIUS*RADIUS)begin mx<=mx+ox*$signed({1'b0,pixel_q});my<=my+oy*$signed({1'b0,pixel_q});end
 if(ox==RADIUS)begin ox<=-RADIUS;if(oy==RADIUS)begin dir<=0;dot<=0;bitno<=0;cm<=127;sm<=0;cn<=0;sn<=0;best<=-48'sh7fffffffffff;best_dir<=0;state<=DOT;end else begin oy<=oy+1;state<=OREAD;end end else begin ox<=ox+1;state<=OREAD;end end
 DOT:begin dot<=dot+termx+termy;if(bitno==6)state<=ANGLE;else bitno<=bitno+1;end
 ANGLE:begin if(dot>best)begin best<=dot;best_dir<=dir;end
 if(dir==15)begin m_angle<=dot>best?dir:best_dir;m_orientation_valid<=mx!=0||my!=0;idx<=0;state<=PREAD;end
 else begin dir<=dir+1;cm<=cosine(dir+1)<0?-cosine(dir+1):cosine(dir+1);sm<=cosine((dir+13)%16)<0?-cosine((dir+13)%16):cosine((dir+13)%16);cn<=cosine(dir+1)<0;sn<=cosine((dir+13)%16)<0;bitno<=0;dot<=0;state<=DOT;end end
 PREAD:begin pair_q<=pattern[{m_angle,8'b0}+idx];state<=ACQ;end
 ACQ:if(ax< -RADIUS-1||ax>RADIUS+1||ay< -RADIUS-1||ay>RADIUS+1||bx< -RADIUS-1||bx>RADIUS+1||by< -RADIUS-1||by>RADIUS+1)begin frame_error<=1;error_code<=3;state<=DONE;end else state<=BREAD;
 BREAD:begin a_q<=pixel_q;state<=CMP;end
 CMP:begin m_descriptor[idx]<=a_q<pixel_q;if(idx==255)begin m_x<=x;m_y<=y;m_original_x<=x<<level;m_original_y<=y<<level;m_level<=level;m_score<=center_score;m_valid<=1;state<=OUT;end else begin idx<=idx+1;state<=PREAD;end end
 OUT:if(m_ready)begin m_valid<=0;state<=NEXT;end
 NEXT:if(x==lw-1&&y==lh-1)begin if(level==LEVELS-1)state<=DONE;else begin_level(level+1);end else next_xy(NREAD);
 DONE:if(done_ready)begin state<=CAP;capture<=0;level<=0;lw<=WIDTH;lh<=HEIGHT;x<=0;y<=0;end
 default:begin state<=DONE;m_valid<=0;frame_error<=1;error_code<=2;end
 endcase
 end
endmodule
