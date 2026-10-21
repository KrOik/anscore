// Directed mean squared Euclidean Chamfer matching, Q8 score (smaller is better).
module chamfer_match #(parameter WIDTH=16,HEIGHT=16)(
 input clk,rst_n,ce,start_valid,output start_ready,
 input[3:0]cfg_template_width,cfg_template_height,
 input t_valid,t_edge,t_sof,t_eol,t_last,output t_ready,
 input s_valid,s_edge,s_sof,s_eol,s_last,output s_ready,
 output reg m_valid,input m_ready,output reg[31:0]m_score,m_sum_squared,
 output reg[5:0]m_x,m_y,output reg m_invalid,m_sof,m_eol,m_last,
 output reg best_valid,output reg[31:0]best_score,best_sum_squared,
 output reg[5:0]best_x,best_y,output[6:0]template_edges,
 output done_valid,input done_ready,output reg done_error,
 output reg[3:0]error_code,output busy
);
 localparam GOOD=WIDTH>=1&&WIDTH<=32&&HEIGHT>=1&&HEIGHT<=32;
 localparam N=GOOD?WIDTH*HEIGHT:1;
 localparam IDLE=0,TEMPLATE=1,FRAME=2,DISTANCE=3,CLEAR=4,ADDRESS=5,READ=6,
 LOAD=7,ADVANCE=8,NORMALIZE=9,DIVIDE=10,RESULT=11,OUTPUT=12,DONE=13,FAILED=14;
 reg[3:0]state;
 reg mask[0:63],mask_q;reg[10:0]distances[0:N-1],distance_q;
 reg[10:0]capture_pos,distance_count;reg[5:0]capture_x;
 reg[3:0]tw,th,tx,ty;reg[6:0]template_count,edge_count;
 reg[5:0]wx,wy,mask_address;reg[9:0]distance_address;
 reg bad_markers,image_invalid;
 reg[17:0]sum_squared;
 reg[31:0]dividend,quotient;reg[7:0]remainder;reg[4:0]bit_index;
 wire[8:0]trial={remainder,dividend[31]};
 wire div_take=trial>={2'b0,edge_count};
 wire[31:0]quotient_next={quotient[30:0],div_take};
 wire dt_s_ready,dt_valid,dt_invalid,dt_done,dt_error;
 wire[31:0]dt_squared;
 wire dt_active=state==FRAME||state==DISTANCE;
 wire dt_failure=dt_active&&dt_done&&dt_error;
 wire dt_accept=rst_n&&ce&&state==DISTANCE&&dt_valid&&!dt_failure;
 wire marker_bad=s_sof!=(capture_pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(capture_pos==N-1);
 wire template_bad=t_sof!=(capture_pos==0)||t_eol!=(capture_x==tw-1)||t_last!=(capture_pos==template_count-1);
 function[9:0]row_base(input[5:0]row);
 integer k;begin row_base=0;for(k=0;k<6;k=k+1)if((WIDTH>>k)&1)row_base=row_base+({4'b0,row}<<k);end endfunction
 euclidean_distance #(.WIDTH(GOOD?WIDTH:1),.HEIGHT(GOOD?HEIGHT:1)) edt(
 .clk(clk),.rst_n(rst_n&&dt_active),.ce(ce),.s_pixel(!s_edge),
 .s_valid(s_valid&&state==FRAME),.s_sof(capture_pos==0),.s_eol(capture_x==WIDTH-1),.s_ready(dt_s_ready),
 .m_valid(dt_valid),.m_ready(rst_n&&state==DISTANCE&&!dt_failure),.m_distance_squared(dt_squared),
 .m_nearest_x(),.m_nearest_y(),.m_invalid(dt_invalid),.m_x(),.m_y(),.m_sof(),.m_eol(),.m_last(),
 .done_valid(dt_done),.done_ready(state==DISTANCE&&!dt_error),.done_error(dt_error));
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign t_ready=rst_n&&ce&&state==TEMPLATE;
 assign s_ready=rst_n&&state==FRAME&&dt_s_ready;
 assign template_edges=edge_count;
 assign done_valid=rst_n&&(state==DONE||state==FAILED);
 assign busy=state!=IDLE;
 always @(posedge clk)if(ce)begin
  mask_q<=mask[mask_address];distance_q<=distances[distance_address];
  if(rst_n&&state==TEMPLATE&&t_valid)mask[capture_pos[5:0]]<=t_edge;
  if(dt_accept&&distance_count<N)distances[distance_count]<=dt_invalid?11'b0:dt_squared[10:0];
 end
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_valid<=0;m_score<=0;m_sum_squared<=0;m_x<=0;m_y<=0;m_invalid<=0;m_sof<=0;m_eol<=0;m_last<=0;
 best_valid<=0;best_score<=0;best_sum_squared<=0;best_x<=0;best_y<=0;edge_count<=0;done_error<=0;error_code<=0;mask_address<=0;distance_address<=0;end
 else if(ce)begin
 if(dt_failure)begin state<=FAILED;done_error<=1;error_code<=4;m_valid<=0;end
 else case(state)
 IDLE:if(start_valid)begin
  m_valid<=0;m_score<=0;m_sum_squared<=0;m_x<=0;m_y<=0;m_invalid<=0;m_sof<=0;m_eol<=0;m_last<=0;
  best_valid<=0;best_score<=0;best_sum_squared<=0;best_x<=0;best_y<=0;edge_count<=0;done_error<=0;error_code<=0;
  if(!GOOD||cfg_template_width<1||cfg_template_width>8||cfg_template_height<1||cfg_template_height>8||cfg_template_width>WIDTH||cfg_template_height>HEIGHT)begin state<=FAILED;done_error<=1;error_code<=1;end
  else begin tw<=cfg_template_width;th<=cfg_template_height;template_count<=cfg_template_width*cfg_template_height;capture_pos<=0;capture_x<=0;bad_markers<=0;image_invalid<=0;state<=TEMPLATE;end
 end
 TEMPLATE:if(t_valid)begin
  if(t_edge)edge_count<=edge_count+1;
  if(template_bad)bad_markers<=1;
  if(capture_pos==template_count-1)begin
   if(bad_markers||template_bad)begin state<=FAILED;done_error<=1;error_code<=2;end
   else begin capture_pos<=0;capture_x<=0;distance_count<=0;bad_markers<=0;state<=FRAME;end
  end else begin capture_pos<=capture_pos+1;if(capture_x==tw-1)capture_x<=0;else capture_x<=capture_x+1;end
 end
 FRAME:if(s_valid&&dt_s_ready)begin
  if(marker_bad)bad_markers<=1;
  if(capture_pos==N-1)begin
   if(bad_markers||marker_bad)begin state<=FAILED;done_error<=1;error_code<=3;end else state<=DISTANCE;
  end else begin capture_pos<=capture_pos+1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1;end
 end
 DISTANCE:begin
  if(dt_valid)begin distance_count<=distance_count+1;if(dt_invalid)image_invalid<=1;end
  if(dt_done)begin
   if(distance_count+(dt_valid?1:0)!=N)begin state<=FAILED;done_error<=1;error_code<=4;end
   else begin wx<=0;wy<=0;state<=CLEAR;end
  end
 end
 CLEAR:begin sum_squared<=0;tx<=0;ty<=0;mask_address<=0;
  if(edge_count==0||image_invalid)state<=RESULT;else state<=ADDRESS;
 end
 ADDRESS:begin distance_address<=row_base(wy+ty)+wx+tx;state<=READ;end
 READ:state<=LOAD;
 LOAD:begin if(mask_q)sum_squared<=sum_squared+distance_q;state<=ADVANCE;end
 ADVANCE:if(tx==tw-1)begin tx<=0;if(ty==th-1)state<=NORMALIZE;else begin ty<=ty+1;mask_address<=mask_address+1;state<=ADDRESS;end end
 else begin tx<=tx+1;mask_address<=mask_address+1;state<=ADDRESS;end
 NORMALIZE:begin dividend<=({14'b0,sum_squared}<<8)+(edge_count>>1);quotient<=0;remainder<=0;bit_index<=0;state<=DIVIDE;end
 DIVIDE:begin dividend<=dividend<<1;quotient<=quotient_next;remainder<=div_take?trial-edge_count:trial;
  if(bit_index==31)state<=RESULT;else bit_index<=bit_index+1;end
 RESULT:begin
  m_x<=wx;m_y<=wy;m_score<=edge_count==0||image_invalid?32'hffffffff:quotient;
  m_sum_squared<=edge_count==0||image_invalid?32'hffffffff:{14'b0,sum_squared};m_invalid<=edge_count==0||image_invalid;
  m_valid<=1;m_sof<=wx==0&&wy==0;m_eol<=wx==WIDTH-tw;m_last<=wx==WIDTH-tw&&wy==HEIGHT-th;
  if(edge_count!=0&&!image_invalid&&(!best_valid||quotient<best_score))begin best_valid<=1;best_score<=quotient;best_sum_squared<=sum_squared;best_x<=wx;best_y<=wy;end
  state<=OUTPUT;
 end
 OUTPUT:if(m_ready)begin m_valid<=0;if(m_last)state<=DONE;else begin if(wx==WIDTH-tw)begin wx<=0;wy<=wy+1;end else wx<=wx+1;state<=CLEAR;end end
 DONE,FAILED:if(done_ready)state<=IDLE;
 default:begin state<=FAILED;done_error<=1;error_code<=5;m_valid<=0;end
 endcase
 end
 end
endmodule
