// Fixed-point three-Gaussian grayscale background model. Not OpenCV MOG2.
module mog3_background_frame #(parameter WIDTH=7,HEIGHT=5)(
 input wire clk,rst_n,ce,
 input wire start_valid,output wire start_ready,
 input wire [3:0] cfg_learning_shift,input wire [4:0] cfg_match_sigma2,
 input wire [8:0] cfg_background_threshold,
 input wire [15:0] cfg_initial_variance,cfg_min_variance,input wire cfg_reset_models,
 input wire [7:0] s_gray,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg m_foreground,output reg [7:0] m_background,output reg [1:0] m_match,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error,output reg [3:0] error_code,
 output wire busy
);
 localparam N=WIDTH*HEIGHT,AW=N<2?1:$clog2(N);
 localparam IDLE=0,INPUT_PIXEL=1,LOAD=2,INIT=3,DIST_ISSUE=4,DIST_DONE=5,MATCH_CHECK=6,CLASSIFY=7,
 WEIGHT_SUM=8,DIV_ISSUE=9,DIV_DONE=10,NORMALIZE=11,SORT_A=12,SORT_B=13,SORT_C=14,SORT_D=15,SORT_COMPARE=16,
 WRITE=17,HOLD=18,DONE=19,MULTIPLY=20,DIVIDE=21;
 reg [4:0] state,return_state;
 reg initialized;
 reg [122:0] model_mem[0:N-1],model_read;
 reg [8:0] weight[0:2],normalized[0:2];
 reg [15:0] mean[0:2],variance[0:2],distance[0:2];
 reg [AW-1:0] pixel_index;
 reg [15:0] x,y;
 reg [7:0] pixel;
 reg [3:0] learning_shift;
 reg [4:0] sigma2;
 reg [8:0] background_threshold;
 reg [15:0] initial_variance,min_variance;
 reg [1:0] component,matched,norm_index,max_index,sort_step;
 reg sort_before_match;
 reg [9:0] total_weight;
 reg [31:0] square;
 reg [63:0] product,multiplicand,left_score;
 reg [31:0] multiplier;
 reg [4:0] mul_bit;
 reg [17:0] dividend,quotient;
 reg [18:0] remainder;
 reg [9:0] divisor;
 reg [4:0] div_bit;
 wire [1:0] a=sort_step==1?1:0,b=sort_step==1?2:1;
 wire signed [16:0] difference=$signed({1'b0,pixel,8'd0})-$signed({1'b0,mean[component]});
 wire [16:0] absolute_difference=difference[16]?-difference:difference;
 wire [18:0] next_remainder={remainder[17:0],dividend[17]};
 wire [1:0] background_end=weight[0]>=background_threshold?0:({1'b0,weight[0]}+weight[1]>=background_threshold?1:2);
 wire valid_config=cfg_learning_shift>=1&&cfg_learning_shift<=8&&cfg_match_sigma2>=1&&cfg_match_sigma2<=25&&
 cfg_background_threshold>=1&&cfg_background_threshold<=256&&cfg_min_variance>=1&&cfg_min_variance<=65025&&
 cfg_initial_variance>=cfg_min_variance&&cfg_initial_variance<=65025;
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==INPUT_PIXEL;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&pixel_index==0;assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&pixel_index==N-1;
 assign done_valid=rst_n&&state==DONE;assign busy=state!=IDLE;
 function signed [31:0] rounded_shift;
 input signed [31:0] v;input [3:0] shift;
 begin if(v<0)rounded_shift=-(((-v)+(32'sd1<<(shift-1)))>>>shift);else rounded_shift=(v+(32'sd1<<(shift-1)))>>>shift;end
 endfunction
 function [8:0] weight_update;
 input [8:0] old;input hit;
 reg signed [31:0] v;
 begin v=$signed({1'b0,old})+rounded_shift((hit?32'sd256:32'sd0)-$signed({1'b0,old}),learning_shift);
 weight_update=v<0?0:(v>256?256:v[8:0]);end
 endfunction
 function [15:0] mean_update;
 input [15:0] old;
 reg signed [31:0] v;
 begin v=$signed({1'b0,old})+rounded_shift($signed({1'b0,pixel,8'd0})-$signed({1'b0,old}),learning_shift);
 mean_update=v<0?0:(v>65280?65280:v[15:0]);end
 endfunction
 function [15:0] variance_update;
 input [15:0] old,target;
 reg signed [31:0] v;
 begin v=$signed({1'b0,old})+rounded_shift($signed({1'b0,target})-$signed({1'b0,old}),learning_shift);
 variance_update=v<min_variance?min_variance:(v>65025?65025:v[15:0]);end
 endfunction
 task mul;
 input [31:0] v,w;input [4:0] next_state;
 begin product<=0;multiplicand<={32'd0,v};multiplier<=w;mul_bit<=0;return_state<=next_state;state<=MULTIPLY;end
 endtask
 task divide;
 input [17:0] v;input [9:0] d;input [4:0] next_state;
 begin dividend<=v;divisor<=d;quotient<=0;remainder<=0;div_bit<=0;return_state<=next_state;state<=DIVIDE;end
 endtask
 initial if(WIDTH<1||HEIGHT<1||WIDTH>1024||HEIGHT>1024||N>1024)$fatal(1,"invalid MOG3 geometry");
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;initialized<=0;model_read<=0;pixel_index<=0;x<=0;y<=0;pixel<=0;
   learning_shift<=1;sigma2<=1;background_threshold<=256;initial_variance<=1;min_variance<=1;
   component<=0;matched<=3;norm_index<=0;max_index<=0;sort_step<=0;sort_before_match<=0;total_weight<=0;square<=0;
   product<=0;multiplicand<=0;multiplier<=0;left_score<=0;mul_bit<=0;return_state<=0;
   dividend<=0;quotient<=0;remainder<=0;divisor<=1;div_bit<=0;
   m_foreground<=0;m_background<=0;m_match<=0;done_error<=0;error_code<=0;
  end else if(ce)begin
   case(state)
    IDLE:if(start_valid)begin
     if(!valid_config)begin done_error<=1;error_code<=1;state<=DONE;end
     else begin
      learning_shift<=cfg_learning_shift;sigma2<=cfg_match_sigma2;background_threshold<=cfg_background_threshold;
      initial_variance<=cfg_initial_variance;min_variance<=cfg_min_variance;
      if(cfg_reset_models)initialized<=0;
      pixel_index<=0;x<=0;y<=0;done_error<=0;error_code<=0;state<=INPUT_PIXEL;
     end
    end
    INPUT_PIXEL:if(s_valid)begin
     pixel<=s_gray;model_read<=model_mem[pixel_index];
     if(s_sof!=(pixel_index==0)||s_eol!=(x==WIDTH-1))begin done_error<=1;error_code<=2;end
     state<=LOAD;
    end
    LOAD:begin
     if(!initialized)state<=INIT;
     else begin
      weight[0]<=model_read[0+:9];mean[0]<=model_read[9+:16];variance[0]<=model_read[25+:16]<min_variance?min_variance:model_read[25+:16];
      weight[1]<=model_read[41+:9];mean[1]<=model_read[50+:16];variance[1]<=model_read[66+:16]<min_variance?min_variance:model_read[66+:16];
      weight[2]<=model_read[82+:9];mean[2]<=model_read[91+:16];variance[2]<=model_read[107+:16]<min_variance?min_variance:model_read[107+:16];
      sort_before_match<=1;sort_step<=0;state<=SORT_A;
     end
    end
    INIT:begin
     weight[0]<=256;weight[1]<=0;weight[2]<=0;
     mean[0]<={pixel,8'd0};mean[1]<={pixel,8'd0};mean[2]<={pixel,8'd0};
     variance[0]<=initial_variance;variance[1]<=initial_variance;variance[2]<=initial_variance;
     m_foreground<=0;m_background<=pixel;m_match<=0;state<=WRITE;
    end
    DIST_ISSUE:mul({15'd0,absolute_difference},{15'd0,absolute_difference},DIST_DONE);
    DIST_DONE:begin square<=product[31:0];mul({16'd0,variance[component]},{27'd0,sigma2},MATCH_CHECK);end
    MATCH_CHECK:begin
     distance[component]<=( {1'b0,square}+33'd32768)>>16;
     if(weight[component]!=0&&matched==3&&{32'd0,square}<=(product<<16))matched<=component;
     if(component==2)state<=CLASSIFY;else begin component<=component+1'b1;state<=DIST_ISSUE;end
    end
    CLASSIFY:begin
     m_foreground<=matched==3||matched>background_end;m_background<=({1'b0,mean[0]}+17'd128)>>8;m_match<=matched;
     weight[0]<=weight_update(weight[0],matched==0);weight[1]<=weight_update(weight[1],matched==1);weight[2]<=weight_update(weight[2],matched==2);
     if(matched==3)begin weight[2]<=rounded_shift(256,learning_shift);mean[2]<={pixel,8'd0};variance[2]<=initial_variance;end
     else begin mean[matched]<=mean_update(mean[matched]);variance[matched]<=variance_update(variance[matched],distance[matched]);end
     state<=WEIGHT_SUM;
    end
    WEIGHT_SUM:begin
     total_weight<={1'b0,weight[0]}+weight[1]+weight[2];
     max_index<=weight[0]>=weight[1]&&weight[0]>=weight[2]?0:(weight[1]>=weight[2]?1:2);
     norm_index<=0;state<=DIV_ISSUE;
    end
    DIV_ISSUE:divide({1'b0,weight[norm_index],8'd0},total_weight,DIV_DONE);
    DIV_DONE:begin
     normalized[norm_index]<=quotient[8:0];
     if(norm_index==2)state<=NORMALIZE;else begin norm_index<=norm_index+1'b1;state<=DIV_ISSUE;end
    end
    NORMALIZE:begin
     weight[0]<=normalized[0];weight[1]<=normalized[1];weight[2]<=normalized[2];
     weight[max_index]<=normalized[max_index]+(10'd256-{1'b0,normalized[0]}-normalized[1]-normalized[2]);
     sort_step<=0;sort_before_match<=0;state<=SORT_A;
    end
    SORT_A:mul({23'd0,weight[a]},{23'd0,weight[a]},SORT_B);
    SORT_B:mul(product[31:0],{16'd0,variance[b]},SORT_C);
    SORT_C:begin left_score<=product;mul({23'd0,weight[b]},{23'd0,weight[b]},SORT_D);end
    SORT_D:mul(product[31:0],{16'd0,variance[a]},SORT_COMPARE);
    SORT_COMPARE:begin
     if(left_score<product)begin
      weight[a]<=weight[b];weight[b]<=weight[a];mean[a]<=mean[b];mean[b]<=mean[a];variance[a]<=variance[b];variance[b]<=variance[a];
     end
     if(sort_step==2)begin
      if(sort_before_match)begin component<=0;matched<=3;state<=DIST_ISSUE;end else state<=WRITE;
     end else begin sort_step<=sort_step+1'b1;state<=SORT_A;end
    end
    WRITE:begin model_mem[pixel_index]<={variance[2],mean[2],weight[2],variance[1],mean[1],weight[1],variance[0],mean[0],weight[0]};state<=HOLD;end
    HOLD:if(m_ready)begin
     if(pixel_index==N-1)begin initialized<=!done_error;state<=DONE;end
     else begin pixel_index<=pixel_index+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=INPUT_PIXEL;end
    end
    DONE:if(done_ready)state<=IDLE;
    MULTIPLY:begin
     if(multiplier[0])product<=product+multiplicand;
     multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
     if(mul_bit==31)state<=return_state;else mul_bit<=mul_bit+1'b1;
    end
    DIVIDE:begin
     if(next_remainder>=divisor)begin remainder<=next_remainder-divisor;quotient<={quotient[16:0],1'b1};end
     else begin remainder<=next_remainder;quotient<={quotient[16:0],1'b0};end
     dividend<=dividend<<1;
     if(div_bit==17)state<=return_state;else div_bit<=div_bit+1'b1;
    end
    default:begin state<=DONE;initialized<=0;done_error<=1;error_code<=3;end
   endcase
  end
 end
endmodule
