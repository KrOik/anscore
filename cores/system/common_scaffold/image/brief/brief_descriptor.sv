// Plain, non-rotation-invariant BRIEF. Runtime pattern frozen for each frame.
module brief_descriptor #(parameter WIDTH=16,HEIGHT=16,BITS=8,DESC_BITS=128,RADIUS=3)(
 input wire clk,rst_n,ce,
 input wire pattern_valid,output wire pattern_ready,input wire [7:0] pattern_index,
 input wire signed [7:0] pattern_ax,pattern_ay,pattern_bx,pattern_by,
 input wire cfg_valid,output wire cfg_ready,output reg cfg_done,cfg_error,
 input wire [BITS-1:0] s_pixel,input wire s_valid,s_sof,s_eol,output wire s_ready,
 input wire kp_valid,output wire kp_ready,input wire [15:0] kp_x,kp_y,kp_id,
 input wire release_valid,output wire release_ready,output wire frame_available,
 output reg [DESC_BITS-1:0] m_descriptor,output reg m_invalid,m_valid,
 output reg [15:0] m_x,m_y,m_id,input wire m_ready,
 output reg [3:0] error_code
);
 localparam EMPTY=0,CAP=1,SCAN=2,CHECK=3,COPY_READ=4,COPY_WRITE=5,KEY=6,PATTERN=7,READ_A=8,READ_B=9,COMPARE=10,PRESENT=11,HOLD=12;
 localparam [63:0] TOTAL_PIXELS=64'd1*WIDTH*HEIGHT;
 // Clamp invalid elaborations before declaring RAM; initial guard rejects them.
 localparam FRAME_PIXELS=(TOTAL_PIXELS>=1&&TOTAL_PIXELS<=65536)?TOTAL_PIXELS:1;
 reg [3:0] state;reg configured,loaded,bad_pattern;
 reg [DESC_BITS-1:0] written,work;
 reg [31:0] staging[0:DESC_BITS-1],active[0:DESC_BITS-1],pq;
 reg [BITS-1:0] frame[0:FRAME_PIXELS-1],pixel_q,a;
 integer x,y,index,ax,ay,bx,by;
 wire idle=state==EMPTY;
 wire invalid_offset=$signed(pq[31:24]) < -RADIUS || $signed(pq[31:24]) > RADIUS ||
 $signed(pq[23:16]) < -RADIUS || $signed(pq[23:16]) > RADIUS ||
 $signed(pq[15:8]) < -RADIUS || $signed(pq[15:8]) > RADIUS ||
 $signed(pq[7:0]) < -RADIUS || $signed(pq[7:0]) > RADIUS;
 wire invalid_keypoint=kp_x<RADIUS||kp_y<RADIUS||{1'b0,kp_x}+RADIUS>=WIDTH||{1'b0,kp_y}+RADIUS>=HEIGHT;
 assign cfg_ready=ce&&idle;
 assign pattern_ready=ce&&idle&&!cfg_valid;
 assign s_ready=ce&&(state==CAP||(idle&&configured&&!cfg_valid&&!pattern_valid));
 assign kp_ready=ce&&state==KEY&&!release_valid;
 assign release_ready=ce&&state==KEY;
 assign frame_available=loaded;
 always @* begin
 ax=$signed({1'b0,m_x})+$signed(pq[31:24]);ay=$signed({1'b0,m_y})+$signed(pq[23:16]);
 bx=$signed({1'b0,m_x})+$signed(pq[15:8]);by=$signed({1'b0,m_y})+$signed(pq[7:0]);
 end
 initial if(WIDTH<1||WIDTH>65535||HEIGHT<1||HEIGHT>65535||TOTAL_PIXELS>65536||BITS<8||BITS>12||(DESC_BITS!=128&&DESC_BITS!=256)||RADIUS<0||RADIUS>31) $fatal(1,"invalid BRIEF parameters");
 always @(posedge clk) begin
 if(!rst_n) begin
 state<=EMPTY;configured<=0;loaded<=0;bad_pattern<=0;written<=0;work<=0;pq<=0;pixel_q<=0;a<=0;
 x<=0;y<=0;index<=0;cfg_done<=0;cfg_error<=0;error_code<=0;
 m_descriptor<=0;m_invalid<=0;m_valid<=0;m_x<=0;m_y<=0;m_id<=0;
 end else if(ce) begin
 cfg_done<=0;cfg_error<=0;
 if(pattern_valid&&pattern_ready) begin
 if(pattern_index>=DESC_BITS) begin cfg_error<=1;error_code<=4;end
 else begin staging[pattern_index]<={pattern_ax,pattern_ay,pattern_bx,pattern_by};written[pattern_index]<=1;end
 end
 if((state==EMPTY||state==CAP)&&s_valid&&s_ready) begin
 if(x==0&&y==0) error_code<=0;
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)) begin
 error_code<=3;loaded<=0;x<=0;y<=0;state<=EMPTY;
 end else begin
 frame[y*WIDTH+x]<=s_pixel;
 if(x==WIDTH-1) begin x<=0;
 if(y==HEIGHT-1) begin y<=0;loaded<=1;state<=KEY;end else begin y<=y+1;state<=CAP;end
 end else begin x<=x+1;state<=CAP;end
 end end
 case(state)
 EMPTY:if(cfg_valid&&cfg_ready) begin
 if(written!={DESC_BITS{1'b1}}) begin cfg_error<=1;error_code<=1;end
 else begin index<=0;bad_pattern<=0;state<=SCAN;end
 end
 SCAN:begin pq<=staging[index];state<=CHECK;end
 CHECK:begin if(invalid_offset) bad_pattern<=1;
 if(index==DESC_BITS-1) begin index<=0;
 if(bad_pattern||invalid_offset) begin cfg_error<=1;error_code<=2;state<=EMPTY;end else state<=COPY_READ;
 end else begin index<=index+1;state<=SCAN;end
 end
 COPY_READ:begin pq<=staging[index];state<=COPY_WRITE;end
 COPY_WRITE:begin active[index]<=pq;
 if(index==DESC_BITS-1) begin index<=0;configured<=1;cfg_done<=1;error_code<=0;state<=EMPTY;end
 else begin index<=index+1;state<=COPY_READ;end
 end
 KEY:if(release_valid&&release_ready) begin loaded<=0;x<=0;y<=0;state<=EMPTY;end
 else if(kp_valid&&kp_ready) begin
 m_x<=kp_x;m_y<=kp_y;m_id<=kp_id;m_invalid<=invalid_keypoint;work<=0;index<=0;
 if(invalid_keypoint) begin m_descriptor<=0;m_valid<=1;state<=HOLD;end else state<=PATTERN;
 end
 PATTERN:begin pq<=active[index];state<=READ_A;end
 READ_A:begin pixel_q<=frame[ay*WIDTH+ax];state<=READ_B;end
 READ_B:begin a<=pixel_q;pixel_q<=frame[by*WIDTH+bx];state<=COMPARE;end
 COMPARE:begin work[index]<=a<pixel_q;
 if(index==DESC_BITS-1) state<=PRESENT;else begin index<=index+1;state<=PATTERN;end
 end
 PRESENT:begin m_descriptor<=work;m_valid<=1;state<=HOLD;end
 HOLD:if(m_ready) begin m_valid<=0;state<=KEY;end
 endcase
 end end
endmodule
