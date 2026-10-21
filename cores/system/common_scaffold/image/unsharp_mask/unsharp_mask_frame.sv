// 3x3 replicated-border binomial Gaussian unsharp mask; shared serial gain.
module unsharp_mask_frame #(parameter WIDTH=7,HEIGHT=5,CHANNELS=3)(
 input clk,rst_n,ce,input start_valid,output start_ready,
 input [7:0] cfg_gain,cfg_threshold,
 input [CHANNELS*8-1:0] s_pixel,input s_valid,s_sof,s_eol,s_last,output s_ready,
 output reg [CHANNELS*8-1:0] m_pixel,output reg m_valid,input m_ready,
 output reg m_sof,m_eol,m_last,
 output reg [12:0] clipped_samples,
 output done_valid,input done_ready,output reg done_error,output reg [3:0] error_code,
 output busy
);
 localparam N=WIDTH*HEIGHT;
 localparam IDLE=0,CAPTURE=1,CENTER_READ=2,CENTER_LOAD=3,TAP_ADDR=4,
 TAP_READ=5,TAP_LOAD=6,DETAIL=7,MULTIPLY=8,SHARPEN=9,OUTPUT=10,DONE=11;
 reg [3:0] state;
 reg [CHANNELS*8-1:0] frame_mem[0:N-1],ram_q,center_pixel;
 reg [10:0] pos,address;
 reg [5:0] x,y;
 reg [1:0] channel,tx,ty;
 reg [7:0] gain,threshold;
 reg [12:0] gaussian_sum;
 reg [15:0] mul_shift,mul_acc;
 reg [7:0] mul_factor;
 reg [3:0] bit_index;
 reg detail_negative;
 wire [7:0] tap_value=ram_q>>(channel*8);
 wire [7:0] center_value=center_pixel>>(channel*8);
 wire [2:0] tap_shift=(tx==1)+(ty==1);
 wire [12:0] weighted={5'b0,tap_value}<<tap_shift;
 wire [8:0] blur=(gaussian_sum+13'd8)>>4;
 wire signed [9:0] detail=$signed({2'b0,center_value})-$signed({1'b0,blur});
 wire [9:0] detail_abs=detail<0?-detail:detail;
 wire [16:0] boost=({1'b0,mul_acc}+17'd8)>>4;
 wire signed [18:0] sharpened=$signed({11'b0,center_value})+(detail_negative?-$signed({2'b0,boost}):$signed({2'b0,boost}));
 wire [5:0] sample_x=tx==0?(x==0?6'd0:x-1'b1):tx==1?x:(x==WIDTH-1?x:x+1'b1);
 wire [5:0] sample_y=ty==0?(y==0?6'd0:y-1'b1):ty==1?y:(y==HEIGHT-1?y:y+1'b1);
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=state==DONE;
 assign busy=state!=IDLE;
 always @(posedge clk)if(ce)ram_q<=frame_mem[address];
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_valid<=0;m_pixel<=0;m_sof<=0;m_eol<=0;m_last<=0;
 clipped_samples<=0;done_error<=0;error_code<=0;address<=0;end
 else if(ce)case(state)
 IDLE:if(start_valid)begin done_error<=0;error_code<=0;
 if(WIDTH<1||WIDTH>32||HEIGHT<1||HEIGHT>32||(CHANNELS!=1&&CHANNELS!=3))begin
 done_error<=1;error_code<=1;state<=DONE;
 end else begin gain<=cfg_gain;threshold<=cfg_threshold;clipped_samples<=0;
 pos<=0;x<=0;y<=0;state<=CAPTURE;end end
 CAPTURE:if(s_valid)begin frame_mem[pos]<=s_pixel;
 if(s_sof!=(pos==0)||s_eol!=(x==WIDTH-1)||s_last!=(pos==N-1))begin done_error<=1;error_code<=2;end
 if(pos==N-1)begin pos<=0;x<=0;y<=0;address<=0;state<=CENTER_READ;end
 else begin pos<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end end
 CENTER_READ:state<=CENTER_LOAD;
 CENTER_LOAD:begin center_pixel<=ram_q;channel<=0;tx<=0;ty<=0;gaussian_sum<=0;state<=TAP_ADDR;end
 TAP_ADDR:begin address<=sample_y*WIDTH+sample_x;state<=TAP_READ;end
 TAP_READ:state<=TAP_LOAD;
 TAP_LOAD:begin gaussian_sum<=gaussian_sum+weighted;
 if(tx==2)begin tx<=0;if(ty==2)state<=DETAIL;else begin ty<=ty+1;state<=TAP_ADDR;end end
 else begin tx<=tx+1;state<=TAP_ADDR;end end
 DETAIL:begin detail_negative<=detail<0;mul_shift<={8'b0,detail_abs[7:0]};mul_factor<=detail_abs>threshold?gain:0;
 mul_acc<=0;bit_index<=0;state<=MULTIPLY;end
 MULTIPLY:begin if(mul_factor[0])mul_acc<=mul_acc+mul_shift;mul_factor<=mul_factor>>1;mul_shift<=mul_shift<<1;
 if(bit_index==7)state<=SHARPEN;else bit_index<=bit_index+1;end
 SHARPEN:begin
 m_pixel[channel*8+:8]<=sharpened<0?8'd0:sharpened>255?8'd255:sharpened[7:0];
 if(sharpened<0||sharpened>255)clipped_samples<=clipped_samples+1;
 if(channel==CHANNELS-1)begin m_valid<=1;m_sof<=pos==0;m_eol<=x==WIDTH-1;m_last<=pos==N-1;state<=OUTPUT;end
 else begin channel<=channel+1;tx<=0;ty<=0;gaussian_sum<=0;state<=TAP_ADDR;end end
 OUTPUT:if(m_ready)begin m_valid<=0;if(pos==N-1)state<=DONE;
 else begin pos<=pos+1;address<=pos+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=CENTER_READ;end end
 DONE:if(done_ready)state<=IDLE;
 default:begin done_error<=1;error_code<=3;m_valid<=0;state<=DONE;end
 endcase end
endmodule
