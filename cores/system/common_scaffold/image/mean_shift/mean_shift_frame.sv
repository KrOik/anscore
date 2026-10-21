// Product-kernel joint spatial/RGB mean shift, integer centers, original frame.
module mean_shift_frame #(parameter WIDTH=7,HEIGHT=5)(
 input clk,rst_n,ce,input start_valid,output start_ready,
 input [3:0] cfg_spatial_radius,input [7:0] cfg_range_radius,cfg_max_iterations,cfg_epsilon,
 input [23:0] s_rgb,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output reg [23:0] m_rgb,output reg [7:0] m_iterations,output reg m_converged,m_empty,
 output reg [10:0] m_support,output reg [5:0] m_mode_x,m_mode_y,
 output reg m_valid,input m_ready,output reg m_sof,m_eol,m_last,
 output reg [10:0] converged_pixels,limited_pixels,empty_pixels,
 output done_valid,input done_ready,output reg done_error,output reg [3:0] error_code,output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,CAP=1,ORIG_READ=2,ORIG_LOAD=3,CLEAR=4,ADDR=5,READ=6,LOAD=7,
 DIST=8,MUL=9,ADD=10,SPACE=11,CHECK=12,ADVANCE=13,UPDATE=14,DIVIDE=15,
 QUOT=16,ITEREND=17,EMIT=18,OUT=19,DONE=20,RADIUS=21,RAD_MUL=22,RAD_SAVE=23;
 reg [4:0] state;
 reg [23:0] frame_mem[0:N-1],ram_q,candidate;
 reg [9:0] address;reg [10:0] pos;
 reg [5:0] x,y,sx,sy,xlo,xhi,yhi;
 reg [7:0] center[0:4];reg [17:0] sums[0:4];
 reg [3:0] hs;reg [7:0] hr,maxiter,epsilon,iteration,movement;
 reg [15:0] hs_squared,hr_squared;
 reg radius_select;
 reg [2:0] dim,update_dim;
 reg [17:0] spatial_distance,color_distance;
 reg [10:0] support;
 reg [15:0] mul_shift,mul_acc;reg [7:0] mul_factor;reg [3:0] bit_index;
 reg [31:0] div_num,div_quot;reg [11:0] div_rem;reg [5:0] div_bit;
 wire [12:0] div_trial={div_rem,div_num[31]};
 wire [7:0] sample_value=dim==0?{2'b0,sx}:dim==1?{2'b0,sy}:dim==2?candidate[23:16]:dim==3?candidate[15:8]:candidate[7:0];
 wire [7:0] difference=sample_value>center[dim]?sample_value-center[dim]:center[dim]-sample_value;
 wire [7:0] new_value=div_quot[7:0];
 wire [7:0] delta=new_value>center[update_dim]?new_value-center[update_dim]:center[update_dim]-new_value;
 wire [7:0] lower_x=center[0]>hs?center[0]-hs:0;
 wire [7:0] lower_y=center[1]>hs?center[1]-hs:0;
 wire [8:0] upper_x={1'b0,center[0]}+hs,upper_y={1'b0,center[1]}+hs;
 assign start_ready=rst_n&&ce&&state==IDLE;assign s_ready=rst_n&&ce&&state==CAP;
 assign done_valid=state==DONE;assign busy=state!=IDLE;
 always @(posedge clk)if(ce)ram_q<=frame_mem[address];
 integer j;
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;address<=0;m_valid<=0;m_rgb<=0;m_iterations<=0;m_converged<=0;m_empty<=0;m_support<=0;
 m_sof<=0;m_eol<=0;m_last<=0;m_mode_x<=0;m_mode_y<=0;converged_pixels<=0;limited_pixels<=0;empty_pixels<=0;done_error<=0;error_code<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin done_error<=0;error_code<=0;converged_pixels<=0;limited_pixels<=0;empty_pixels<=0;
 if(WIDTH<1||WIDTH>32||HEIGHT<1||HEIGHT>32||cfg_spatial_radius<1||cfg_spatial_radius>8||cfg_max_iterations==0)begin done_error<=1;error_code<=1;state<=DONE;end
 else begin hs<=cfg_spatial_radius;hr<=cfg_range_radius;maxiter<=cfg_max_iterations;epsilon<=cfg_epsilon;
 pos<=0;x<=0;y<=0;state<=CAP;end end
 CAP:if(s_valid)begin frame_mem[pos]<=s_rgb;
 if(s_sof!=(pos==0)||s_eol!=(x==WIDTH-1)||s_last!=(pos==N-1))begin done_error<=1;error_code<=2;end
 if(pos==N-1)begin pos<=0;x<=0;y<=0;radius_select<=0;state<=RADIUS;end
 else begin pos<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end end
 RADIUS:begin mul_shift<=radius_select?{8'b0,hr}:{12'b0,hs};mul_factor<=radius_select?hr:{4'b0,hs};mul_acc<=0;bit_index<=0;state<=RAD_MUL;end
 RAD_MUL:begin if(mul_factor[0])mul_acc<=mul_acc+mul_shift;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
 if(bit_index==7)state<=RAD_SAVE;else bit_index<=bit_index+1;end
 RAD_SAVE:if(!radius_select)begin hs_squared<=mul_acc;radius_select<=1;state<=RADIUS;end
 else begin hr_squared<=mul_acc;address<=0;state<=ORIG_READ;end
 ORIG_READ:state<=ORIG_LOAD;
 ORIG_LOAD:begin center[0]<=x;center[1]<=y;center[2]<=ram_q[23:16];center[3]<=ram_q[15:8];center[4]<=ram_q[7:0];iteration<=0;state<=CLEAR;end
 CLEAR:begin for(j=0;j<5;j=j+1)sums[j]<=0;support<=0;
 sx<=lower_x;sy<=lower_y;xlo<=lower_x;xhi<=upper_x>=WIDTH?WIDTH-1:upper_x[5:0];yhi<=upper_y>=HEIGHT?HEIGHT-1:upper_y[5:0];state<=ADDR;end
 ADDR:begin address<=sy*WIDTH+sx;state<=READ;end
 READ:state<=LOAD;
 LOAD:begin candidate<=ram_q;dim<=0;spatial_distance<=0;color_distance<=0;state<=DIST;end
 DIST:begin mul_shift<={8'b0,difference};mul_factor<=difference;mul_acc<=0;bit_index<=0;state<=MUL;end
 MUL:begin if(mul_factor[0])mul_acc<=mul_acc+mul_shift;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
 if(bit_index==7)state<=ADD;else bit_index<=bit_index+1;end
 ADD:begin if(dim<2)spatial_distance<=spatial_distance+mul_acc;else color_distance<=color_distance+mul_acc;
 if(dim==1)state<=SPACE;else if(dim==4)state<=CHECK;else begin dim<=dim+1;state<=DIST;end end
 SPACE:if(spatial_distance>hs_squared)state<=ADVANCE;else begin dim<=2;state<=DIST;end
 CHECK:begin if(color_distance<=hr_squared)begin support<=support+1;sums[0]<=sums[0]+sx;sums[1]<=sums[1]+sy;
 sums[2]<=sums[2]+candidate[23:16];sums[3]<=sums[3]+candidate[15:8];sums[4]<=sums[4]+candidate[7:0];end state<=ADVANCE;end
 ADVANCE:if(sx==xhi&&sy==yhi)begin update_dim<=0;movement<=0;state<=UPDATE;end
 else begin if(sx==xhi)begin sx<=xlo;sy<=sy+1;end else sx<=sx+1;state<=ADDR;end
 UPDATE:if(support==0)begin m_empty<=1;m_converged<=0;iteration<=iteration+1;state<=EMIT;end
 else begin div_num<={14'b0,sums[update_dim]}+(support>>1);div_quot<=0;div_rem<=0;div_bit<=0;state<=DIVIDE;end
 DIVIDE:begin div_num<=div_num<<1;
 if(div_trial>={2'b0,support})begin div_rem<=div_trial-support;div_quot<={div_quot[30:0],1'b1};end
 else begin div_rem<=div_trial[11:0];div_quot<={div_quot[30:0],1'b0};end
 if(div_bit==31)state<=QUOT;else div_bit<=div_bit+1;end
 QUOT:begin center[update_dim]<=new_value;if(delta>movement)movement<=delta;
 if(update_dim==4)state<=ITEREND;else begin update_dim<=update_dim+1;state<=UPDATE;end end
 ITEREND:begin iteration<=iteration+1;
 if(movement<=epsilon||iteration+1==maxiter)begin m_empty<=0;m_converged<=movement<=epsilon;state<=EMIT;end else state<=CLEAR;end
 EMIT:begin m_rgb<={center[2],center[3],center[4]};m_iterations<=iteration;m_support<=support;m_mode_x<=center[0];m_mode_y<=center[1];m_valid<=1;
 m_sof<=pos==0;m_eol<=x==WIDTH-1;m_last<=pos==N-1;
 if(m_empty)empty_pixels<=empty_pixels+1;else if(m_converged)converged_pixels<=converged_pixels+1;else limited_pixels<=limited_pixels+1;
 state<=OUT;end
 OUT:if(m_ready)begin m_valid<=0;if(pos==N-1)state<=DONE;
 else begin pos<=pos+1;address<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=ORIG_READ;end end
 DONE:if(done_ready)state<=IDLE;
 default:begin done_error<=1;error_code<=3;m_valid<=0;state<=DONE;end
 endcase end
endmodule
