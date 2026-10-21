// Complete disparity-axis cost-stream WTA + exact quadratic subpixel interpolation.
module stereo_subpixel #(
 parameter WIDTH=16,HEIGHT=8,DISPARITIES=16,COST_BITS=16,FRAC_BITS=4
)(input clk,rst_n,ce,input abort,
 input cfg_valid,output cfg_ready,input [COST_BITS-1:0] cfg_min_gap,
 input [COST_BITS-1:0] s_cost,input s_cost_invalid,input [15:0] s_disp,
 input s_valid,output s_ready,input s_sof,s_eol,s_last,
 output reg signed [31:0] m_disparity_q,output reg [15:0] m_integer,
 output reg signed [FRAC_BITS:0] m_offset,output reg [COST_BITS-1:0] m_confidence,
 output reg m_invalid,output reg [7:0] m_status,
 output m_valid,input m_ready,output m_sof,m_eol,m_last,
 output done_valid,input done_ready,output reg frame_error,output reg [3:0] error_code);
 localparam INPUT=0,FINAL=1,DIVIDE=2,ROUND=3,APPLY=4,HOLD=5,DONE=6;
 reg [2:0] state;
 integer x,y,pixel,d;
 reg [COST_BITS-1:0] min_gap,frame_gap,best_cost,second_cost,left_cost,right_cost,previous_cost;
 reg have_best,have_second,left_valid,right_valid,previous_valid;
 reg [15:0] best_index;
 reg signed [COST_BITS+2:0] curvature,numerator_signed;
 always @* begin
 curvature=$signed({3'b0,left_cost})+$signed({3'b0,right_cost})-($signed({3'b0,best_cost})<<<1);
 numerator_signed=$signed({3'b0,left_cost})-$signed({3'b0,right_cost});
 end
 reg [63:0] numerator,quotient,rounded;
 reg [32:0] remainder;
 reg [31:0] denominator;
 reg negative;
 reg [6:0] step;
 wire [32:0] shifted={remainder[31:0],numerator[63]};
 localparam [63:0] HALF=64'd1<<(FRAC_BITS-1);
 wire [63:0] limited=rounded>HALF?HALF:rounded;
 wire signed [31:0] signed_offset=negative?-$signed(limited[31:0]):$signed(limited[31:0]);
 assign cfg_ready=rst_n&&ce&&!abort&&state==INPUT&&pixel==0&&d==0;
 assign s_ready=rst_n&&ce&&!abort&&state==INPUT&&!(cfg_valid&&cfg_ready);
 assign m_valid=rst_n&&state==HOLD&&!abort;
 assign m_sof=m_valid&&pixel==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_valid&&pixel==WIDTH*HEIGHT-1;
 assign done_valid=rst_n&&state==DONE;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536||DISPARITIES<3||DISPARITIES>256||COST_BITS<2||COST_BITS>24||FRAC_BITS<1||FRAC_BITS>12)$fatal(1,"stereo_subpixel parameters");
 task clear_axis;begin d<=0;have_best<=0;have_second<=0;left_valid<=0;right_valid<=0;previous_valid<=0;best_cost<=0;second_cost<=0;left_cost<=0;right_cost<=0;previous_cost<=0;best_index<=0;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=INPUT;x<=0;y<=0;pixel<=0;clear_axis;min_gap<=1;frame_gap<=1;frame_error<=0;error_code<=0;m_disparity_q<=0;m_integer<=0;m_offset<=0;m_confidence<=0;m_invalid<=0;m_status<=0;end
 else if(ce)begin
 if(abort&&state!=DONE)begin state<=DONE;frame_error<=1;error_code<=3;end
 else case(state)
 INPUT:begin
 if(cfg_valid&&cfg_ready)min_gap<=cfg_min_gap;
 else if(s_valid&&s_ready)begin
 if(s_disp!=d||s_sof!=(pixel==0)||s_eol!=(x==WIDTH-1)||s_last!=(pixel==WIDTH*HEIGHT-1))begin state<=DONE;frame_error<=1;error_code<=1;end
 else begin
 if(pixel==0&&d==0)begin frame_gap<=min_gap;frame_error<=0;error_code<=0;end
 if(have_best&&d==best_index+1)begin right_cost<=s_cost;right_valid<=!s_cost_invalid;end
 if(!s_cost_invalid)begin
 if(!have_best||s_cost<best_cost)begin
 if(have_best)begin second_cost<=best_cost;have_second<=1;end
 best_cost<=s_cost;best_index<=d;have_best<=1;left_cost<=previous_cost;left_valid<=previous_valid;right_valid<=0;
 end else if(!have_second||s_cost<second_cost)begin second_cost<=s_cost;have_second<=1;end
 end
 previous_cost<=s_cost;previous_valid<=!s_cost_invalid;
 if(d==DISPARITIES-1)state<=FINAL;else d<=d+1;
 end end end
 FINAL:begin
 m_integer<=best_index;m_disparity_q<=best_index<<FRAC_BITS;m_offset<=0;
 m_confidence<=have_second?second_cost-best_cost:0;
 m_status<=0;m_invalid<=!have_best||!have_second||(have_second&&(second_cost-best_cost)<frame_gap);
 if(!have_best)begin m_status[6]<=1;m_status[5]<=1;state<=HOLD;end
 else if(!have_second)begin m_status[5]<=1;state<=HOLD;end
 else begin
 if(second_cost-best_cost<frame_gap)m_status[4]<=1;
 if(best_index==0||best_index==DISPARITIES-1)begin m_status[1]<=1;state<=HOLD;end
 else if(!left_valid||!right_valid)begin m_status[2]<=1;state<=HOLD;end
 else if(curvature<=0)begin m_status[3]<=1;state<=HOLD;end
 else begin
 numerator<=(numerator_signed<0?-$signed(numerator_signed):numerator_signed)<<FRAC_BITS;
 denominator<=curvature<<1;negative<=numerator_signed<0;quotient<=0;remainder<=0;step<=0;state<=DIVIDE;
 end end end
 DIVIDE:begin numerator<=numerator<<1;quotient<=quotient<<1;
 if(shifted>={1'b0,denominator})begin remainder<=shifted-{1'b0,denominator};quotient[0]<=1;end else remainder<=shifted;
 if(step==63)state<=ROUND;else step<=step+1;end
 ROUND:begin rounded<=quotient+(({remainder,1'b0}>={2'b0,denominator})?64'd1:64'd0);state<=APPLY;end
 APPLY:begin m_offset<=signed_offset;m_disparity_q<=(best_index<<FRAC_BITS)+signed_offset;m_status[0]<=1;m_status[7]<=rounded>HALF;state<=HOLD;end
 HOLD:if(m_ready)begin
 if(pixel==WIDTH*HEIGHT-1)state<=DONE;
 else begin pixel<=pixel+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;clear_axis;state<=INPUT;end end
 DONE:if(done_ready)begin state<=INPUT;x<=0;y<=0;pixel<=0;clear_axis;end
 default:begin state<=DONE;frame_error<=1;error_code<=2;end
 endcase
 end
 end
endmodule
