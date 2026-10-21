// Rectified left-reference Census matching: right coordinate = left x - disparity.
module stereo_census_match_frame #(
 parameter WIDTH=16,HEIGHT=8,DESC_BITS=24,MAX_DISPARITY=7,
 parameter COST_BITS=$clog2(DESC_BITS+2),DISP_BITS=(MAX_DISPARITY<1?1:$clog2(MAX_DISPARITY+1))
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,
 input wire [COST_BITS-1:0] cfg_max_cost,cfg_uniqueness,
 input wire [DESC_BITS-1:0] s_left,s_right,
 input wire s_left_border,s_right_border,s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [DISP_BITS-1:0] m_disparity,output reg [COST_BITS-1:0] m_cost,
 output reg m_invalid,output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,output reg frame_error
);
 localparam CAPTURE=0,LEFT_READ=1,LEFT=2,RIGHT_READ=3,COMPARE=4,RESULT=5,HOLD=6,DONE=7;
 localparam PIXELS=WIDTH*HEIGHT,INF=DESC_BITS+1;
 reg [2:0] state;
 reg [DESC_BITS:0] left_memory[0:PIXELS-1],right_memory[0:PIXELS-1];
 reg [DESC_BITS:0] left_q,right_q;
 reg [COST_BITS-1:0] maximum_cost,uniqueness,best_cost,second_cost;
 reg [DISP_BITS-1:0] candidate,best_disparity;
 integer index,x,y;
 reg [COST_BITS-1:0] distance;
 integer k;
 always @*begin
  distance=0;
  for(k=0;k<DESC_BITS;k=k+1)distance=distance+(left_q[k]^right_q[k]);
 end
 assign cfg_ready=rst_n&&state==CAPTURE&&index==0;
 assign s_ready=rst_n&&state==CAPTURE&&!cfg_valid;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&index==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=rst_n&&state==DONE;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||PIXELS>65536||DESC_BITS<1||DESC_BITS>64||
     MAX_DISPARITY<0||MAX_DISPARITY>4095||COST_BITS<$clog2(DESC_BITS+2)||DISP_BITS<(MAX_DISPARITY<1?1:$clog2(MAX_DISPARITY+1)))
   $fatal(1,"stereo_census_match_frame invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;index<=0;x<=0;y<=0;maximum_cost<=DESC_BITS;uniqueness<=0;
   m_disparity<=0;m_cost<=INF;m_invalid<=1;frame_error<=0;
   best_cost<=INF;second_cost<=INF;candidate<=0;best_disparity<=0;
  end else if(ce)begin
   case(state)
    CAPTURE:begin
     if(cfg_valid&&cfg_ready)begin maximum_cost<=cfg_max_cost;uniqueness<=cfg_uniqueness;end
     if(s_valid&&s_ready)begin
      if(s_sof!=(index==0)||s_eol!=(x==WIDTH-1))begin state<=DONE;frame_error<=1;end
      else begin
       left_memory[index]<={s_left_border,s_left};right_memory[index]<={s_right_border,s_right};
       if(index==PIXELS-1)begin index<=0;x<=0;y<=0;state<=LEFT_READ;end
       else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
      end
     end
    end
    LEFT_READ:begin left_q<=left_memory[index];state<=LEFT;end
    LEFT:begin
     best_cost<=INF;second_cost<=INF;best_disparity<=0;candidate<=0;
     if(left_q[DESC_BITS])state<=RESULT;else state<=RIGHT_READ;
    end
    RIGHT_READ:begin right_q<=right_memory[index-candidate];state<=COMPARE;end
    COMPARE:begin
     if(!right_q[DESC_BITS])begin
      if(distance<best_cost)begin second_cost<=best_cost;best_cost<=distance;best_disparity<=candidate;end
      else if(distance<second_cost)second_cost<=distance;
     end
     if(candidate==MAX_DISPARITY||candidate==x)state<=RESULT;
     else begin candidate<=candidate+1;state<=RIGHT_READ;end
    end
    RESULT:begin
     m_disparity<=best_disparity;m_cost<=best_cost;
     m_invalid<=best_cost==INF||best_cost>maximum_cost||
       (uniqueness!=0&&second_cost!=INF&&second_cost-best_cost<uniqueness);
     state<=HOLD;
    end
    HOLD:if(m_ready)begin
     if(index==PIXELS-1)state<=DONE;
     else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=LEFT_READ;end
    end
    DONE:if(done_ready)begin state<=CAPTURE;index<=0;x<=0;y<=0;frame_error<=0;end
    default:begin state<=DONE;frame_error<=1;end
   endcase
  end
 end
endmodule
