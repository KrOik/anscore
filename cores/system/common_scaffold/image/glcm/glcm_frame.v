// Four exact integer-offset GLCMs and raw normalized-feature numerators.
module glcm_frame #(
 parameter BITS=8,WIDTH=32,HEIGHT=32,LEVELS=16,
 parameter LB=(LEVELS==16?4:5),CW=$clog2(2*WIDTH*HEIGHT+1),FW=2*CW+2*LB+1
)(
 input wire clk,rst,ce,
 input wire[11:0] cfg_distance,input wire cfg_symmetric,
 input wire[BITS-1:0] s_gray,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg[CW-1:0] m_count,
 output wire[LB-1:0] m_row,m_column,output wire[1:0] m_direction,
 output wire[CW-1:0] m_pair_total,output wire m_direction_last,m_last,
 output wire feature_valid,input wire feature_ready,
 output reg[FW-1:0] contrast_numerator,dissimilarity_numerator,energy_numerator,energy_denominator,
 output wire[CW-1:0] feature_pair_total,output wire[1:0] feature_direction,
 output wire zero_pairs,feature_last,
 output wire done_valid,input wire done_ready,
 output reg marker_error,config_error,arithmetic_error,output wire busy
);
 localparam PIXELS=WIDTH*HEIGHT,AW=PIXELS<2?1:$clog2(PIXELS),MW=$clog2(FW+1);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),DEPTH=LEVELS*LEVELS;
 localparam CAPTURE=0,CLEAR=1,SCAN=2,AREAD=3,ACAP=4,BREAD=5,BCAP=6,HREAD=7,HWRITE=8,
 MADDR=9,MREAD=10,MVALUE=11,MULTIPLY=12,ENERGY_DONE=13,DISSIM_DONE=14,CONTRAST_DONE=15,
 OUTPUT=16,DENOM=17,DENOM_DONE=18,FEATURE=19,DONE=20;
 reg[4:0] state,mul_return;
 reg[LB-1:0] frame_mem[0:PIXELS-1],frame_q,pair_a,pair_b;
 reg[CW-1:0] matrix_mem[0:DEPTH-1],matrix_q,pair_total;
 reg[AW-1:0] capture_addr,frame_addr,scan_addr;
 reg[XW-1:0] capture_x,x;reg[YW-1:0] capture_y,y;
 reg[11:0] distance;reg symmetric;
 reg[1:0] direction;
 reg[2*LB-1:0] clear_index,matrix_addr,matrix_index;
 reg second_vote;
 reg[FW-1:0] multiplicand,multiplier,product,product_result;
 reg[MW-1:0] mul_bit;
 integer neighbor_x,neighbor_y;
 wire in_bounds=neighbor_x>=0&&neighbor_x<WIDTH&&neighbor_y>=0&&neighbor_y<HEIGHT;
 wire[LB-1:0] row=matrix_index[2*LB-1:LB],column=matrix_index[LB-1:0];
 wire[LB-1:0] difference=row>=column?row-column:column-row;
 wire[FW-1:0] product_next=product+(multiplier[0]?multiplicand:0);
 function[2*LB-1:0] square_difference;
 input[LB-1:0] value;integer bit_index;
 begin
 square_difference=0;
 for(bit_index=0;bit_index<LB;bit_index=bit_index+1)
 if(value[bit_index])square_difference=square_difference+({{LB{1'b0}},value}<<bit_index);
 end
 endfunction
 assign s_ready=!rst&&ce&&state==CAPTURE;
 assign m_valid=!rst&&state==OUTPUT;
 assign m_row=row;assign m_column=column;assign m_direction=direction;assign m_pair_total=pair_total;
 assign m_direction_last=m_valid&&matrix_index==DEPTH-1;
 assign m_last=m_direction_last&&direction==3;
 assign feature_valid=!rst&&state==FEATURE;
 assign feature_pair_total=pair_total;assign feature_direction=direction;
 assign zero_pairs=pair_total==0;assign feature_last=direction==3;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=CAPTURE||capture_addr!=0;
 always @* begin
 neighbor_x=$signed({1'b0,x});neighbor_y=$signed({1'b0,y});
 case(direction)
 0:neighbor_x=neighbor_x+distance;
 1:begin neighbor_x=neighbor_x+distance;neighbor_y=neighbor_y+distance;end
 2:neighbor_y=neighbor_y+distance;
 3:begin neighbor_x=neighbor_x-distance;neighbor_y=neighbor_y+distance;end
 endcase
 end
 always @(posedge clk)if(ce&&!rst)begin
 if(state==CAPTURE&&s_valid&&s_ready)frame_mem[capture_addr]<=s_gray[BITS-1:BITS-LB];
 if(state==AREAD||state==BREAD)frame_q<=frame_mem[frame_addr];
 if(state==CLEAR)matrix_mem[clear_index]<=0;
 else if(state==HWRITE)matrix_mem[matrix_addr]<=matrix_q+1'b1;
 if(state==HREAD||state==MREAD)matrix_q<=matrix_mem[matrix_addr];
 end
 task next_pair;
 begin
 if(scan_addr==PIXELS-1)begin matrix_index<=0;state<=MADDR;end
 else begin
 scan_addr<=scan_addr+1'b1;
 if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
 state<=SCAN;
 end
 end
 endtask
 initial if(BITS<8||BITS>12||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||(LEVELS!=16&&LEVELS!=32)||LB!=(LEVELS==16?4:5)||CW!=$clog2(2*WIDTH*HEIGHT+1)||FW!=2*CW+2*LB+1)$fatal(1,"invalid GLCM parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=CAPTURE;mul_return<=0;capture_addr<=0;frame_addr<=0;scan_addr<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;
 distance<=0;symmetric<=0;direction<=0;clear_index<=0;matrix_addr<=0;matrix_index<=0;pair_a<=0;pair_b<=0;second_vote<=0;pair_total<=0;m_count<=0;
 contrast_numerator<=0;dissimilarity_numerator<=0;energy_numerator<=0;energy_denominator<=0;
 multiplicand<=0;multiplier<=0;product<=0;product_result<=0;mul_bit<=0;
 marker_error<=0;config_error<=0;arithmetic_error<=0;
 end else if(ce)case(state)
 CAPTURE:if(s_valid&&s_ready)begin
 if(capture_addr==0)begin marker_error<=0;arithmetic_error<=0;config_error<=cfg_distance==0;distance<=cfg_distance;symmetric<=cfg_symmetric;end
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))marker_error<=1;
 if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
 if(capture_addr==PIXELS-1)begin capture_addr<=0;capture_x<=0;capture_y<=0;direction<=0;clear_index<=0;pair_total<=0;contrast_numerator<=0;dissimilarity_numerator<=0;energy_numerator<=0;state<=CLEAR;end
 else capture_addr<=capture_addr+1'b1;
 end
 CLEAR:if(clear_index==DEPTH-1)begin scan_addr<=0;x<=0;y<=0;state<=SCAN;end else clear_index<=clear_index+1'b1;
 SCAN:if(config_error||!in_bounds)next_pair;
 else begin frame_addr<=scan_addr;state<=AREAD;end
 AREAD:state<=ACAP;
 ACAP:begin pair_a<=frame_q;frame_addr<=neighbor_y*WIDTH+neighbor_x;state<=BREAD;end
 BREAD:state<=BCAP;
 BCAP:begin pair_b<=frame_q;matrix_addr<={pair_a,frame_q};second_vote<=0;state<=HREAD;end
 HREAD:state<=HWRITE;
 HWRITE:begin
 if(&matrix_q)arithmetic_error<=1;
 pair_total<=pair_total+1'b1;
 if(symmetric&&!second_vote)begin matrix_addr<={pair_b,pair_a};second_vote<=1;state<=HREAD;end
 else next_pair;
 end
 MADDR:begin matrix_addr<=matrix_index;state<=MREAD;end
 MREAD:state<=MVALUE;
 MVALUE:begin
 m_count<=matrix_q;
 if(matrix_q==0)state<=OUTPUT;
 else begin multiplicand<=matrix_q;multiplier<=matrix_q;product<=0;mul_bit<=0;mul_return<=ENERGY_DONE;state<=MULTIPLY;end
 end
 MULTIPLY:begin
 product<=product_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(mul_bit==FW-1)begin product_result<=product_next;state<=mul_return;end else mul_bit<=mul_bit+1'b1;
 end
 ENERGY_DONE:begin
 energy_numerator<=energy_numerator+product_result;
 multiplicand<=m_count;multiplier<=difference;product<=0;mul_bit<=0;mul_return<=DISSIM_DONE;state<=MULTIPLY;
 end
 DISSIM_DONE:begin
 dissimilarity_numerator<=dissimilarity_numerator+product_result;
 multiplicand<=m_count;multiplier<=square_difference(difference);product<=0;mul_bit<=0;mul_return<=CONTRAST_DONE;state<=MULTIPLY;
 end
 CONTRAST_DONE:begin contrast_numerator<=contrast_numerator+product_result;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 if(matrix_index==DEPTH-1)state<=DENOM;
 else begin matrix_index<=matrix_index+1'b1;state<=MADDR;end
 end
 DENOM:if(pair_total==0)begin energy_denominator<=0;state<=FEATURE;end
 else begin multiplicand<=pair_total;multiplier<=pair_total;product<=0;mul_bit<=0;mul_return<=DENOM_DONE;state<=MULTIPLY;end
 DENOM_DONE:begin energy_denominator<=product_result;state<=FEATURE;end
 FEATURE:if(feature_ready)begin
 if(direction==3)state<=DONE;
 else begin direction<=direction+1'b1;clear_index<=0;pair_total<=0;contrast_numerator<=0;dissimilarity_numerator<=0;energy_numerator<=0;state<=CLEAR;end
 end
 DONE:if(done_ready)state<=CAPTURE;
 default:state<=CAPTURE;
 endcase
 end
endmodule
