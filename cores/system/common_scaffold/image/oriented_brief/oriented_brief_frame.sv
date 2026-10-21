// Serial centroid orientation + rotated BRIEF. Not an OpenCV ORB implementation.
module oriented_brief_frame #(
 parameter WIDTH=40, HEIGHT=40, BITS=8, RADIUS=15,
 parameter PATTERN_FILE=RADIUS==1?"cores/system/common_scaffold/image/oriented_brief/pattern_r1.mem":
 RADIUS==2?"cores/system/common_scaffold/image/oriented_brief/pattern_r2.mem":
 RADIUS==3?"cores/system/common_scaffold/image/oriented_brief/pattern_r3.mem":
 RADIUS==4?"cores/system/common_scaffold/image/oriented_brief/pattern_r4.mem":
 RADIUS==5?"cores/system/common_scaffold/image/oriented_brief/pattern_r5.mem":
 RADIUS==6?"cores/system/common_scaffold/image/oriented_brief/pattern_r6.mem":
 RADIUS==7?"cores/system/common_scaffold/image/oriented_brief/pattern_r7.mem":
 RADIUS==8?"cores/system/common_scaffold/image/oriented_brief/pattern_r8.mem":
 RADIUS==9?"cores/system/common_scaffold/image/oriented_brief/pattern_r9.mem":
 RADIUS==10?"cores/system/common_scaffold/image/oriented_brief/pattern_r10.mem":
 RADIUS==11?"cores/system/common_scaffold/image/oriented_brief/pattern_r11.mem":
 RADIUS==12?"cores/system/common_scaffold/image/oriented_brief/pattern_r12.mem":
 RADIUS==13?"cores/system/common_scaffold/image/oriented_brief/pattern_r13.mem":
 RADIUS==14?"cores/system/common_scaffold/image/oriented_brief/pattern_r14.mem":
 "cores/system/common_scaffold/image/oriented_brief/pattern_r15.mem"
)(input clk,input rst_n,input ce,
 input [BITS-1:0] s_pixel,input s_valid,input s_sof,input s_eol,output s_ready,
 input kp_valid,output kp_ready,input [15:0] kp_x,kp_y,kp_id,
 input release_valid,output release_ready,output reg frame_available,
 output reg [255:0] m_descriptor,output reg [3:0] m_angle,
 output reg m_orientation_valid,output reg m_invalid,output reg m_valid,
 output reg [15:0] m_x,m_y,m_id,input m_ready,output reg [3:0] error_code);
 localparam N=WIDTH*HEIGHT;
 reg [BITS-1:0] frame[0:N-1];
 reg [23:0] pattern[0:4095];
 initial begin
 if(WIDTH<1||HEIGHT<1||N>65536||BITS<8||BITS>12||RADIUS<1||RADIUS>15) $fatal(1,"invalid parameters");
 $readmemh(PATTERN_FILE,pattern);
 end
 localparam IDLE=0,OREAD=1,OUSE=2,DOT=3,ANGLE=4,PREAD=5,ACQ=6,BREAD=7,CMP=8,OUT=9;
 reg [3:0] state;
 integer capture,x,y,ox,oy,addr,idx,dir,bitno;
 reg [BITS-1:0] pixel_q,a_q;
 integer read_addr;
 reg [23:0] pair_q;
 reg signed [31:0] mx,my;
 reg signed [47:0] dot,best;
 reg [3:0] best_dir;
 reg [6:0] cm,sm;
 reg cn,sn;
 reg signed [47:0] termx,termy;
 function signed [7:0] cosine;input integer d;begin
 case(d) 0:cosine=127;1:cosine=117;2:cosine=90;3:cosine=49;4:cosine=0;5:cosine=-49;6:cosine=-90;7:cosine=-117;8:cosine=-127;9:cosine=-117;10:cosine=-90;11:cosine=-49;12:cosine=0;13:cosine=49;14:cosine=90;default:cosine=117;endcase end endfunction
 wire signed [7:0] cv=cosine(dir),sv=cosine((dir+12)%16);
 wire signed [5:0] ax=pair_q[23:18],ay=pair_q[17:12],bx=pair_q[11:6],by=pair_q[5:0];
 assign s_ready=rst_n&&!frame_available&&state==IDLE;
 assign kp_ready=rst_n&&frame_available&&state==IDLE&&!release_valid;
 assign release_ready=rst_n&&frame_available&&state==IDLE;
 always @* begin
 termx=0;termy=0;
 if(cm[bitno]) termx=cn? -($signed(mx) <<< bitno):($signed(mx) <<< bitno);
 if(sm[bitno]) termy=sn? -($signed(my) <<< bitno):($signed(my) <<< bitno);
 end
 always @* begin
 read_addr=0;
 if(state==OREAD) read_addr=(y+oy)*WIDTH+x+ox;
 else if(state==ACQ && ax >= -RADIUS-1 && ax <= RADIUS+1 && ay >= -RADIUS-1 && ay <= RADIUS+1) read_addr=(y+$signed(ay))*WIDTH+x+$signed(ax);
 else if(state==BREAD) read_addr=(y+$signed(by))*WIDTH+x+$signed(bx);
 end
 always @(posedge clk) if(ce) pixel_q<=frame[read_addr];
 always @(posedge clk) begin
 if(!rst_n) begin state<=IDLE;capture<=0;frame_available<=0;m_valid<=0;error_code<=0;m_descriptor<=0;m_angle<=0;m_orientation_valid<=0;m_invalid<=0;m_x<=0;m_y<=0;m_id<=0;end
 else if(ce) begin
 case(state)
 IDLE:begin
 if(release_valid&&release_ready) begin frame_available<=0;capture<=0;end
 else if(s_valid&&s_ready) begin
 if(s_sof!=(capture==0)||s_eol!=(capture%WIDTH==WIDTH-1)) begin capture<=0;frame_available<=0;error_code<=1;end
 else begin frame[capture]<=s_pixel;error_code<=0;if(capture==N-1) begin capture<=0;frame_available<=1;end else capture<=capture+1;end
 end else if(kp_valid&&kp_ready) begin
 m_x<=kp_x;m_y<=kp_y;m_id<=kp_id;m_descriptor<=0;m_angle<=0;m_orientation_valid<=0;
 if(kp_x<RADIUS+1||kp_y<RADIUS+1||kp_x+RADIUS+1>=WIDTH||kp_y+RADIUS+1>=HEIGHT) begin m_invalid<=1;m_valid<=1;state<=OUT;end
 else begin m_invalid<=0;x<=kp_x;y<=kp_y;ox<=-RADIUS;oy<=-RADIUS;mx<=0;my<=0;state<=OREAD;end
 end end
 OREAD:begin state<=OUSE;end
 OUSE:begin
 if(ox*ox+oy*oy<=RADIUS*RADIUS) begin mx<=mx+ox*$signed({1'b0,pixel_q});my<=my+oy*$signed({1'b0,pixel_q});end
 if(ox==RADIUS) begin ox<=-RADIUS;if(oy==RADIUS) begin dir<=0;dot<=0;bitno<=0;cm<=127;sm<=0;cn<=0;sn<=0;best<=-48'sh7fffffffffff;best_dir<=0;state<=DOT;end else begin oy<=oy+1;state<=OREAD;end end
 else begin ox<=ox+1;state<=OREAD;end end
 DOT:begin dot<=dot+termx+termy;if(bitno==6) state<=ANGLE;else bitno<=bitno+1;end
 ANGLE:begin
 if(dot>best) begin best<=dot;best_dir<=dir;end
 if(dir==15) begin m_angle<=(dot>best)?dir:best_dir;m_orientation_valid<=mx!=0||my!=0;idx<=0;state<=PREAD;end
 else begin dir<=dir+1;cm<=cosine(dir+1)<0?-cosine(dir+1):cosine(dir+1);sm<=cosine((dir+13)%16)<0?-cosine((dir+13)%16):cosine((dir+13)%16);cn<=cosine(dir+1)<0;sn<=cosine((dir+13)%16)<0;bitno<=0;dot<=0;state<=DOT;end end
 PREAD:begin pair_q<=pattern[{m_angle,8'b0}+idx];state<=ACQ;end
 ACQ:begin
 if(ax < -RADIUS-1 || ax > RADIUS+1 || ay < -RADIUS-1 || ay > RADIUS+1 || bx < -RADIUS-1 || bx > RADIUS+1 || by < -RADIUS-1 || by > RADIUS+1) begin
 m_invalid<=1;m_descriptor<=0;m_valid<=1;error_code<=3;state<=OUT;end
 else begin state<=BREAD;end end
 BREAD:begin a_q<=pixel_q;state<=CMP;end
 CMP:begin m_descriptor[idx]<=a_q<pixel_q;if(idx==255) begin m_valid<=1;state<=OUT;end else begin idx<=idx+1;state<=PREAD;end end
 OUT:if(m_valid&&m_ready) begin m_valid<=0;state<=IDLE;end
 default:begin state<=IDLE;frame_available<=0;capture<=0;m_valid<=0;error_code<=2;end
 endcase
 end
 end
endmodule
