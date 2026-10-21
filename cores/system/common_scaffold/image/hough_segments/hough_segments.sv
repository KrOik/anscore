// Finite supported segments for one polar candidate; no infinite-line clipping.
module hough_segments #(parameter WIDTH=16,HEIGHT=16,TRIG_FILE="trig.mem")(
 input clk,rst_n,ce,start_valid,output start_ready,
 input [7:0] cfg_theta,input signed [7:0] cfg_rho,
 input [1:0] cfg_rho_tolerance,input [5:0] cfg_max_gap,cfg_min_length,
 input [5:0] cfg_min_support,cfg_max_segments,
 input s_valid,s_edge,s_sof,s_eol,s_last,output s_ready,
 output reg m_valid,input m_ready,
 output reg [5:0] m_x1,m_y1,m_x2,m_y2,m_support,m_index,
 output reg [11:0] m_length_squared,
 output done_valid,input done_ready,output reg done_error,
 output reg [3:0] error_code,output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,CAPTURE=1,TRIG_ADDR=2,TRIG_READ=3,ADDRESS=4,READ=5,PIXEL=6,
 X_RET=7,Y_RET=8,GROUP=9,ADVANCE=10,LENGTH=11,LX_RET=12,LY_RET=13,
 CHECK_LENGTH=14,OUTPUT=15,DONE=16,MULTIPLY=17,MIN_RET=18;
 reg [4:0]state,return_state;
 reg edges[0:N-1];reg edge_q;reg [10:0] address,pos;
 reg [31:0]trig[0:179],trig_q;reg [7:0]theta;
 initial $readmemh(TRIG_FILE,trig);
 reg signed [7:0]rho;
 reg [1:0]tolerance;
 reg [5:0]max_gap,min_support,limit;
 reg [11:0]min_length_squared,length_x,length_squared;
 reg [5:0]capture_x,major,minor,gap,support_count;
 reg major_x,point_valid,segment_active;
 reg [5:0]point_x,point_y,first_x,first_y,last_x,last_y;
 reg [23:0]point_distance;
 reg signed [15:0]cosine,sine;
 wire [15:0]cos_abs=cosine[15]?(~cosine+16'd1):cosine;
 wire [15:0]sin_abs=sine[15]?(~sine+16'd1):sine;
 wire [15:0]table_cos_abs=trig_q[31]?(~trig_q[31:16]+16'd1):trig_q[31:16];
 wire [5:0]px=major_x?major:minor,py=major_x?minor:major;
 wire [5:0]major_limit=major_x?WIDTH:HEIGHT,minor_limit=major_x?HEIGHT:WIDTH;
 reg [21:0]multiplicand,acc,product;reg [5:0]multiplier;reg [2:0]bit_count;
 wire [21:0]mul_next=acc+(multiplier[0]?multiplicand:22'b0);
 reg signed [22:0]x_term;
 wire signed [22:0]y_term=sine[15]?-$signed({1'b0,product}):$signed({1'b0,product});
 wire signed [23:0]dot=$signed(x_term)+$signed(y_term);
 wire [23:0]dot_abs=dot[23]?-dot:dot;
 wire [23:0]rounded=(dot_abs+24'd8192)>>14;
 wire signed [8:0]pixel_rho=dot[23]?-$signed({1'b0,rounded[7:0]}):$signed({1'b0,rounded[7:0]});
 wire signed [9:0]rho_difference=$signed(pixel_rho)-$signed(rho);
 wire [9:0]rho_distance=rho_difference<0?-rho_difference:rho_difference;
 wire signed [23:0]rho_q14=$signed(rho)*24'sd16384;
 wire signed [24:0]residual=$signed(dot)-$signed(rho_q14);
 wire [24:0]distance=residual<0?-residual:residual;
 wire [5:0]dx=last_x>first_x?last_x-first_x:first_x-last_x;
 wire [5:0]dy=last_y>first_y?last_y-first_y:first_y-last_y;
 function [10:0]row_base(input[5:0]row);
 integer k;begin row_base=0;for(k=0;k<6;k=k+1)if((WIDTH>>k)&1)row_base=row_base+({5'b0,row}<<k);end endfunction
 always @(posedge clk)if(ce)begin
  edge_q<=edges[address];trig_q<=trig[theta];
  if(state==CAPTURE&&s_valid)edges[pos]<=s_edge;
 end
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=state==DONE;
 assign busy=state!=IDLE;
 task mul(input [15:0]a,input[5:0]b,input[4:0]ret);
 begin multiplicand<={6'b0,a};multiplier<=b;acc<=0;bit_count<=0;return_state<=ret;state<=MULTIPLY;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_valid<=0;m_x1<=0;m_y1<=0;m_x2<=0;m_y2<=0;m_support<=0;m_index<=0;m_length_squared<=0;done_error<=0;error_code<=0;address<=0;theta<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin
  done_error<=0;error_code<=0;m_valid<=0;m_x1<=0;m_y1<=0;m_x2<=0;m_y2<=0;m_support<=0;m_index<=0;m_length_squared<=0;
  if(WIDTH<1||WIDTH>32||HEIGHT<1||HEIGHT>32||cfg_theta>179||cfg_rho< -45||cfg_rho>45||cfg_max_gap>31||cfg_min_length<1||cfg_min_length>44||cfg_min_support<2||cfg_min_support>32||cfg_max_segments<1||cfg_max_segments>32)begin state<=DONE;done_error<=1;error_code<=1;end
  else begin theta<=cfg_theta;rho<=cfg_rho;tolerance<=cfg_rho_tolerance;max_gap<=cfg_max_gap;min_support<=cfg_min_support;limit<=cfg_max_segments;pos<=0;capture_x<=0;mul({10'b0,cfg_min_length},cfg_min_length,MIN_RET);end
 end
 MIN_RET:begin min_length_squared<=product[11:0];state<=CAPTURE;end
 CAPTURE:if(s_valid)begin
  if(s_sof!=(pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(pos==N-1))begin done_error<=1;error_code<=2;end
  if(pos==N-1)begin if(done_error||s_sof!=(pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(pos==N-1))state<=DONE;else state<=TRIG_ADDR;end
  else begin pos<=pos+1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1;end
 end
 TRIG_ADDR:state<=TRIG_READ;
 TRIG_READ:begin cosine<=trig_q[31:16];sine<=trig_q[15:0];major_x<=trig_q[15:0]>=table_cos_abs;major<=0;minor<=0;point_valid<=0;segment_active<=0;gap<=0;support_count<=0;state<=ADDRESS;end
 ADDRESS:begin address<=row_base(py)+px;state<=READ;end
 READ:state<=PIXEL;
 PIXEL:if(edge_q)mul(cos_abs,px,X_RET);else if(minor==minor_limit-1)state<=GROUP;else begin minor<=minor+1;state<=ADDRESS;end
 X_RET:begin x_term<=cosine[15]?-$signed({1'b0,product}):$signed({1'b0,product});mul(sin_abs,py,Y_RET);end
 Y_RET:begin
  if(rho_distance<=tolerance&&(!point_valid||distance<point_distance))begin point_valid<=1;point_x<=px;point_y<=py;point_distance<=distance[23:0];end
  if(minor==minor_limit-1)state<=GROUP;else begin minor<=minor+1;state<=ADDRESS;end
 end
 GROUP:begin
  if(point_valid)begin
   if(!segment_active)begin first_x<=point_x;first_y<=point_y;support_count<=1;segment_active<=1;end else support_count<=support_count+1;
   last_x<=point_x;last_y<=point_y;gap<=0;state<=ADVANCE;
  end else if(segment_active&&gap==max_gap)state<=LENGTH;
  else begin if(segment_active)gap<=gap+1;state<=ADVANCE;end
 end
 ADVANCE:if(major==major_limit-1)begin if(segment_active)state<=LENGTH;else state<=DONE;end
 else begin major<=major+1;minor<=0;point_valid<=0;state<=ADDRESS;end
 LENGTH:begin segment_active<=0;mul({10'b0,dx},dx,LX_RET);end
 LX_RET:begin length_x<=product[11:0];mul({10'b0,dy},dy,LY_RET);end
 LY_RET:begin length_squared<=length_x+product[11:0];state<=CHECK_LENGTH;end
 CHECK_LENGTH:if(support_count>=min_support&&length_squared>=min_length_squared)begin m_x1<=first_x;m_y1<=first_y;m_x2<=last_x;m_y2<=last_y;m_support<=support_count;m_length_squared<=length_squared;m_valid<=1;state<=OUTPUT;end else state<=ADVANCE;
 OUTPUT:if(m_ready)begin m_valid<=0;if(m_index==limit-1)state<=DONE;else begin m_index<=m_index+1;state<=ADVANCE;end end
 DONE:if(done_ready)state<=IDLE;
 MULTIPLY:begin acc<=mul_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;if(bit_count==5)begin product<=mul_next;state<=return_state;end else bit_count<=bit_count+1;end
 default:begin state<=DONE;m_valid<=0;done_error<=1;error_code<=4;end
 endcase
 end
endmodule
