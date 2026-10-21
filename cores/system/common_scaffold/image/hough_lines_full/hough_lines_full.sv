// Full polar Hough transform. Prototype image IP; no security claims.
module hough_lines_full #(parameter WIDTH=16,HEIGHT=16,THETA_STEP=1,
 parameter TRIG_FILE="trig.mem")(
 input clk,rst_n,ce,start_valid,output start_ready,
 input [10:0] cfg_threshold,input [4:0] cfg_max_lines,
 input [6:0] cfg_theta_nms,cfg_rho_nms,
 input s_valid,s_edge,s_sof,s_eol,s_last,output s_ready,
 output reg m_valid,input m_ready,output reg [7:0] m_theta,
 output reg signed [7:0] m_rho,output reg [10:0] m_score,
 output reg [4:0] m_index,
 output done_valid,input done_ready,output reg done_error,
 output reg [3:0] error_code,output busy
);
 localparam N=WIDTH*HEIGHT,T=THETA_STEP>0?180/THETA_STEP:1,R=91,BINS=T*R;
 localparam IDLE=0,CAPTURE=1,CLEAR=2,PIX_ADDR=3,PIX_READ=4,PIX_USE=5,
 TRIG_ADDR=6,TRIG_READ=7,MUL_X=8,MUL_Y=9,RHO=10,VADDR=11,VREAD=12,VWRITE=13,
 NEXT=14,SCAN_INIT=15,SADDR=16,SREAD=17,SUSE=18,SELECT=19,OUTPUT=20,
 NADDR=21,NREAD=22,NWRITE=23,DONE=24;
 reg [4:0] state;
 reg edges[0:N-1];reg edge_q;reg [10:0] pixel_addr,pos;
 reg [5:0] capture_x,x,y;
 reg [31:0] trig[0:179];reg [31:0] trig_q;reg [7:0] trig_addr,theta;
 initial $readmemh(TRIG_FILE,trig);
 reg [10:0] votes[0:BINS-1];reg [10:0] vote_q;
 reg [14:0] addr,scan;
 reg [10:0] threshold,best;
 reg [4:0] limit;
 reg [6:0] theta_nms,rho_nms;
 reg [7:0] best_theta,scan_theta;
 reg signed [7:0] best_rho,scan_rho;
 reg [5:0] multiplier;reg [21:0] multiplicand,acc;
 reg [2:0] bit_count;
 reg signed [22:0] x_term;
 reg signed [15:0] cosine,sine;
 wire [15:0] cos_abs=trig_q[31]?(~trig_q[31:16]+16'd1):trig_q[31:16];
 wire [15:0] sin_abs=sine[15]?(~sine+16'd1):sine;
 reg signed [7:0] rho;
 wire signed [8:0] rho_offset=$signed(rho)+9'sd45;
 wire [14:0] theta_index=theta/(THETA_STEP>0?THETA_STEP:1);
 wire [14:0] theta_base=(theta_index<<6)+(theta_index<<4)+(theta_index<<3)+(theta_index<<1)+theta_index;
 wire [21:0] mul_next=acc+(multiplier[0]?multiplicand:22'b0);
 wire signed [22:0] y_term=sine[15]?-$signed({1'b0,mul_next}):$signed({1'b0,mul_next});
 wire signed [23:0] dot=$signed(x_term)+$signed(y_term);
 wire [23:0] dot_abs=dot[23]?-dot:dot;
 wire [23:0] rounded=(dot_abs+24'd8192)>>14;
 wire signed [7:0] rounded_rho=dot[23]?-$signed(rounded[7:0]):$signed(rounded[7:0]);
 wire [7:0] angular_delta=scan_theta>m_theta?scan_theta-m_theta:m_theta-scan_theta;
 wire wrap_angle=angular_delta>90;
 wire [7:0] angle_distance=wrap_angle?180-angular_delta:angular_delta;
 wire signed [8:0] rho_delta=wrap_angle?($signed(scan_rho)+$signed(m_rho)):($signed(scan_rho)-$signed(m_rho));
 wire [8:0] rho_distance=rho_delta<0?-rho_delta:rho_delta;
 wire suppress=angle_distance<=theta_nms&&rho_distance<=rho_nms;
 wire vote_we=ce&&(state==CLEAR||state==VWRITE||state==NWRITE&&suppress);
 wire [10:0] vote_d=state==VWRITE?vote_q+11'd1:11'b0;
 always @(posedge clk) if(ce)begin
  edge_q<=edges[pixel_addr];trig_q<=trig[trig_addr];vote_q<=votes[addr];
  if(vote_we)votes[addr]<=vote_d;
  if(state==CAPTURE&&s_valid)edges[pos]<=s_edge;
 end
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=state==DONE;
 assign busy=state!=IDLE;
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_valid<=0;m_theta<=0;m_rho<=0;m_score<=0;m_index<=0;done_error<=0;error_code<=0;addr<=0;pixel_addr<=0;trig_addr<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin
  done_error<=0;error_code<=0;m_valid<=0;m_index<=0;m_theta<=0;m_rho<=0;m_score<=0;
  if(WIDTH<1||WIDTH>32||HEIGHT<1||HEIGHT>32||THETA_STEP<1||THETA_STEP>90||180%THETA_STEP!=0||cfg_threshold<1||cfg_threshold>1024||cfg_max_lines<1||cfg_max_lines>16||cfg_theta_nms>90||cfg_rho_nms>90)begin done_error<=1;error_code<=1;state<=DONE;end
  else begin threshold<=cfg_threshold;limit<=cfg_max_lines;theta_nms<=cfg_theta_nms;rho_nms<=cfg_rho_nms;pos<=0;capture_x<=0;state<=CAPTURE;end
 end
 CAPTURE:if(s_valid)begin
  if(s_sof!=(pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(pos==N-1))begin done_error<=1;error_code<=2;end
  if(pos==N-1)begin if(done_error||s_sof!=(pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(pos==N-1))state<=DONE;else begin addr<=0;state<=CLEAR;end end
  else begin pos<=pos+1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1;end
 end
 CLEAR:if(addr==BINS-1)begin pixel_addr<=0;x<=0;y<=0;state<=PIX_ADDR;end else addr<=addr+1;
 PIX_ADDR:state<=PIX_READ;
 PIX_READ:state<=PIX_USE;
 PIX_USE:if(edge_q)begin theta<=0;trig_addr<=0;state<=TRIG_ADDR;end else state<=NEXT;
 TRIG_ADDR:state<=TRIG_READ;
 TRIG_READ:begin cosine<=trig_q[31:16];sine<=trig_q[15:0];multiplier<=x;multiplicand<={6'b0,cos_abs};acc<=0;bit_count<=0;state<=MUL_X;end
 MUL_X:begin acc<=mul_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
  if(bit_count==5)begin x_term<=cosine[15]?-$signed({1'b0,mul_next}):$signed({1'b0,mul_next});multiplier<=y;multiplicand<={6'b0,sin_abs};acc<=0;bit_count<=0;state<=MUL_Y;end else bit_count<=bit_count+1;
 end
 MUL_Y:begin acc<=mul_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
  if(bit_count==5)begin rho<=rounded_rho;state<=RHO;end else bit_count<=bit_count+1;
 end
 RHO:begin addr<=theta_base+rho_offset[6:0];state<=VADDR;end
 VADDR:state<=VREAD;
 VREAD:state<=VWRITE;
 VWRITE:if(theta==180-THETA_STEP)state<=NEXT;else begin theta<=theta+THETA_STEP;trig_addr<=theta+THETA_STEP;state<=TRIG_ADDR;end
 NEXT:if(pixel_addr==N-1)state<=SCAN_INIT;else begin pixel_addr<=pixel_addr+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=PIX_ADDR;end
 SCAN_INIT:begin scan<=0;scan_theta<=0;scan_rho<=-45;best<=0;best_theta<=0;best_rho<=0;state<=SADDR;end
 SADDR:begin addr<=scan;state<=SREAD;end
 SREAD:state<=SUSE;
 SUSE:begin if(vote_q>best)begin best<=vote_q;best_theta<=scan_theta;best_rho<=scan_rho;end
  if(scan==BINS-1)state<=SELECT;
  else begin scan<=scan+1;if(scan_rho==45)begin scan_rho<=-45;scan_theta<=scan_theta+THETA_STEP;end else scan_rho<=scan_rho+1;state<=SADDR;end
 end
 SELECT:if(best<threshold)state<=DONE;else begin m_valid<=1;m_theta<=best_theta;m_rho<=best_rho;m_score<=best;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin m_valid<=0;if(m_index==limit-1)state<=DONE;else begin m_index<=m_index+1;scan<=0;scan_theta<=0;scan_rho<=-45;state<=NADDR;end end
 NADDR:begin addr<=scan;state<=NREAD;end
 NREAD:state<=NWRITE;
 NWRITE:if(scan==BINS-1)state<=SCAN_INIT;else begin scan<=scan+1;if(scan_rho==45)begin scan_rho<=-45;scan_theta<=scan_theta+THETA_STEP;end else scan_rho<=scan_rho+1;state<=NADDR;end
 DONE:if(done_ready)state<=IDLE;
 default:begin state<=DONE;m_valid<=0;done_error<=1;error_code<=4;end
 endcase
 end
endmodule
