// Exact centered integer moments; serial multiply, Euclidean sqrt and divide.
module template_match_zncc #(parameter WIDTH=7,HEIGHT=5)(
 input clk,rst_n,ce,input start_valid,output start_ready,
 input [3:0] cfg_template_width,cfg_template_height,
 input [7:0] t_pixel,input t_valid,t_sof,t_eol,t_last,output t_ready,
 input [7:0] s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output reg signed [16:0] m_score,output reg [5:0] m_x,m_y,
 output reg m_invalid,m_valid,input m_ready,output reg m_sof,m_eol,m_last,
 output reg signed [16:0] best_score,output reg [5:0] best_x,best_y,output reg best_valid,
 output done_valid,input done_ready,output reg done_error,output reg [3:0] error_code,
 output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,TEMPLATE=1,FRAME=2,CLEAR=3,ADDRESS=4,READ=5,LOAD=6,
 AA=7,AA_RET=8,BB=9,BB_RET=10,AB=11,AB_RET=12,NEXT_PAIR=13,
 NSAB=14,NSAB_RET=15,SASB=16,SASB_RET=17,NSAA=18,NSAA_RET=19,
 SASA=20,SASA_RET=21,NSBB=22,NSBB_RET=23,SBSB=24,SBSB_RET=25,
 VAR_PRODUCT=26,VAR_RET=27,SQRT=28,NORMALIZE=29,RESULT=30,OUTPUT=31,DONE=32,
 MULTIPLY=33,DIVIDE=34,ZERO=35;
 reg [5:0] state,return_state;
 reg [7:0] image_mem[0:N-1],template_mem[0:63],aq,bq;
 reg [9:0] image_address;reg [5:0] template_address;
 reg [10:0] capture_pos;reg [5:0] capture_x;
 reg [3:0] tw,th,tx,ty;reg [6:0] count;
 reg [5:0] wx,wy;
 reg [7:0] a,b;
 reg [13:0] sum_a,sum_b;
 reg [21:0] sum_aa,sum_bb,sum_ab;
 reg [31:0] moment_ab,moment_aa,moment_bb,var_a,var_b;
 reg signed [32:0] numerator;
 reg [63:0] product,accumulator,multiplicand;
 reg [31:0] multiplier;reg [5:0] bit_index;
 reg [87:0] radicand;reg [43:0] root;reg [89:0] sqrt_remainder;
 wire [89:0] sqrt_trial={44'b0,root,2'b01};
 wire [89:0] sqrt_next={sqrt_remainder[87:0],radicand[87:86]};
 wire sqrt_take=sqrt_next>=sqrt_trial;
 wire [43:0] root_next={root[42:0],sqrt_take};
 reg [63:0] dividend,quotient;reg [44:0] remainder;reg [43:0] divisor;
 wire [45:0] div_trial={remainder,dividend[63]};
 wire div_take=div_trial>={2'b0,divisor};
 wire [63:0] quotient_next={quotient[62:0],div_take};
 wire [32:0] numerator_abs=numerator<0?-numerator:numerator;
 wire signed [16:0] normalized=numerator<0?-$signed(quotient[16:0]):$signed(quotient[16:0]);
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign t_ready=rst_n&&ce&&state==TEMPLATE;
 assign s_ready=rst_n&&ce&&state==FRAME;
 assign done_valid=state==DONE;
 assign busy=state!=IDLE;
 always @(posedge clk)if(ce)begin aq<=image_mem[image_address];bq<=template_mem[template_address];end
 task mul(input [31:0] x,y,input [5:0] next_state);
 begin accumulator<=0;multiplicand<={32'b0,x};multiplier<=y;bit_index<=0;return_state<=next_state;state<=MULTIPLY;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_score<=0;m_x<=0;m_y<=0;m_invalid<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_last<=0;
 best_score<=0;best_x<=0;best_y<=0;best_valid<=0;done_error<=0;error_code<=0;image_address<=0;template_address<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin done_error<=0;error_code<=0;best_valid<=0;best_score<=0;best_x<=0;best_y<=0;
 if(WIDTH<1||WIDTH>32||HEIGHT<1||HEIGHT>32||cfg_template_width<1||cfg_template_width>8||cfg_template_height<1||cfg_template_height>8||cfg_template_width>WIDTH||cfg_template_height>HEIGHT)begin done_error<=1;error_code<=1;state<=DONE;end
 else begin tw<=cfg_template_width;th<=cfg_template_height;count<=cfg_template_width*cfg_template_height;
 capture_pos<=0;capture_x<=0;state<=TEMPLATE;end end
 TEMPLATE:if(t_valid)begin template_mem[capture_pos[5:0]]<=t_pixel;
 if(t_sof!=(capture_pos==0)||t_eol!=(capture_x==tw-1)||t_last!=(capture_pos==count-1))begin done_error<=1;error_code<=2;end
 if(capture_pos==count-1)begin capture_pos<=0;capture_x<=0;state<=FRAME;end
 else begin capture_pos<=capture_pos+1;if(capture_x==tw-1)capture_x<=0;else capture_x<=capture_x+1;end end
 FRAME:if(s_valid)begin image_mem[capture_pos]<=s_pixel;
 if(s_sof!=(capture_pos==0)||s_eol!=(capture_x==WIDTH-1)||s_last!=(capture_pos==N-1))begin done_error<=1;error_code<=3;end
 if(capture_pos==N-1)begin wx<=0;wy<=0;state<=CLEAR;end
 else begin capture_pos<=capture_pos+1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1;end end
 CLEAR:begin sum_a<=0;sum_b<=0;sum_aa<=0;sum_bb<=0;sum_ab<=0;tx<=0;ty<=0;state<=ADDRESS;end
 ADDRESS:begin image_address<=(wy+ty)*WIDTH+wx+tx;template_address<=ty*tw+tx;state<=READ;end
 READ:state<=LOAD;
 LOAD:begin a<=aq;b<=bq;sum_a<=sum_a+aq;sum_b<=sum_b+bq;state<=AA;end
 AA:mul({24'b0,a},{24'b0,a},AA_RET);
 AA_RET:begin sum_aa<=sum_aa+product[21:0];state<=BB;end
 BB:mul({24'b0,b},{24'b0,b},BB_RET);
 BB_RET:begin sum_bb<=sum_bb+product[21:0];state<=AB;end
 AB:mul({24'b0,a},{24'b0,b},AB_RET);
 AB_RET:begin sum_ab<=sum_ab+product[21:0];state<=NEXT_PAIR;end
 NEXT_PAIR:if(tx==tw-1)begin tx<=0;if(ty==th-1)state<=NSAB;else begin ty<=ty+1;state<=ADDRESS;end end
 else begin tx<=tx+1;state<=ADDRESS;end
 NSAB:mul({25'b0,count},{10'b0,sum_ab},NSAB_RET);
 NSAB_RET:begin moment_ab<=product[31:0];state<=SASB;end
 SASB:mul({18'b0,sum_a},{18'b0,sum_b},SASB_RET);
 SASB_RET:begin numerator<=$signed({1'b0,moment_ab})-$signed({1'b0,product[31:0]});state<=NSAA;end
 NSAA:mul({25'b0,count},{10'b0,sum_aa},NSAA_RET);
 NSAA_RET:begin moment_aa<=product[31:0];state<=SASA;end
 SASA:mul({18'b0,sum_a},{18'b0,sum_a},SASA_RET);
 SASA_RET:begin var_a<=moment_aa-product[31:0];state<=NSBB;end
 NSBB:mul({25'b0,count},{10'b0,sum_bb},NSBB_RET);
 NSBB_RET:begin moment_bb<=product[31:0];state<=SBSB;end
 SBSB:mul({18'b0,sum_b},{18'b0,sum_b},SBSB_RET);
 SBSB_RET:begin var_b<=moment_bb-product[31:0];state<=VAR_PRODUCT;end
 VAR_PRODUCT:if(var_a==0||var_b==0)state<=ZERO;else mul(var_a,var_b,VAR_RET);
 VAR_RET:begin radicand<={product[55:0],32'b0};root<=0;sqrt_remainder<=0;bit_index<=0;state<=SQRT;end
 SQRT:begin radicand<=radicand<<2;root<=root_next;sqrt_remainder<=sqrt_take?sqrt_next-sqrt_trial:sqrt_next;
 if(bit_index==43)state<=NORMALIZE;else bit_index<=bit_index+1;end
 NORMALIZE:begin dividend<=({31'b0,numerator_abs}<<31)+(root>>1);divisor<=root;quotient<=0;remainder<=0;bit_index<=0;state<=DIVIDE;end
 RESULT:begin m_score<=normalized;m_invalid<=done_error;m_x<=wx;m_y<=wy;m_valid<=1;
 m_sof<=wx==0&&wy==0;m_eol<=wx==WIDTH-tw;m_last<=wx==WIDTH-tw&&wy==HEIGHT-th;
 if(!done_error&&(!best_valid||normalized>best_score))begin best_valid<=1;best_score<=normalized;best_x<=wx;best_y<=wy;end state<=OUTPUT;end
 ZERO:begin m_score<=0;m_invalid<=1;m_x<=wx;m_y<=wy;m_valid<=1;
 m_sof<=wx==0&&wy==0;m_eol<=wx==WIDTH-tw;m_last<=wx==WIDTH-tw&&wy==HEIGHT-th;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin m_valid<=0;if(m_last)state<=DONE;
 else begin if(wx==WIDTH-tw)begin wx<=0;wy<=wy+1;end else wx<=wx+1;state<=CLEAR;end end
 DONE:if(done_ready)state<=IDLE;
 MULTIPLY:begin accumulator<=accumulator+(multiplier[0]?multiplicand:64'b0);multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(bit_index==31)begin product<=accumulator+(multiplier[0]?multiplicand:64'b0);state<=return_state;end else bit_index<=bit_index+1;end
 DIVIDE:begin dividend<=dividend<<1;quotient<=quotient_next;remainder<=div_take?div_trial-divisor:div_trial;
 if(bit_index==63)state<=RESULT;else bit_index<=bit_index+1;end
 default:begin done_error<=1;error_code<=4;m_valid<=0;state<=DONE;end
 endcase end
endmodule
