// Canonical row-bounded binary image RLE. At most one transition pixel held.
module binary_rle_encoder #(parameter WIDTH=32,HEIGHT=32)(
 input wire clk,rst,ce,
 input wire s_value,s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output wire m_value,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_start_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire[$clog2(WIDTH+1)-1:0] m_length,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg frame_error,output wire busy
);
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),LW=$clog2(WIDTH+1);
 localparam COLLECT=0,EMIT=1,DONE=2;
 reg[1:0] state;
 reg[XW-1:0] input_x,run_start,pending_x;
 reg[YW-1:0] input_y,run_y,pending_y;
 reg[LW-1:0] run_length;
 reg run_value,have_run,pending_new,pending_value,pending_eol;
 wire[LW:0] run_end={1'b0,run_start}+{1'b0,run_length};
 assign s_ready=!rst&&ce&&state==COLLECT;
 assign m_valid=!rst&&state==EMIT;
 assign m_value=run_value;assign m_start_x=run_start;assign m_y=run_y;assign m_length=run_length;
 assign m_sof=m_valid&&run_start==0&&run_y==0;
 assign m_eol=m_valid&&run_end==WIDTH;
 assign m_last=m_eol&&run_y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=COLLECT||have_run||input_x!=0||input_y!=0;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>65535||HEIGHT>65535)$fatal(1,"invalid binary RLE geometry");
 always @(posedge clk)begin
 if(rst)begin
 state<=COLLECT;input_x<=0;input_y<=0;run_start<=0;run_y<=0;run_length<=0;run_value<=0;have_run<=0;
 pending_new<=0;pending_value<=0;pending_eol<=0;pending_x<=0;pending_y<=0;frame_error<=0;
 end else if(ce)case(state)
 COLLECT:if(s_valid&&s_ready)begin
 if(input_x==0&&input_y==0)frame_error<=0;
 if(s_sof!=(input_x==0&&input_y==0)||s_eol!=(input_x==WIDTH-1))frame_error<=1;
 if(input_x==WIDTH-1)begin input_x<=0;if(input_y==HEIGHT-1)input_y<=0;else input_y<=input_y+1'b1;end else input_x<=input_x+1'b1;
 if(!have_run)begin
 run_value<=s_value;run_start<=input_x;run_y<=input_y;run_length<=1;have_run<=1;pending_new<=0;
 if(input_x==WIDTH-1)state<=EMIT;
 end else if(s_value==run_value)begin
 run_length<=run_length+1'b1;
 if(input_x==WIDTH-1)begin pending_new<=0;state<=EMIT;end
 end else begin
 pending_new<=1;pending_value<=s_value;pending_x<=input_x;pending_y<=input_y;pending_eol<=input_x==WIDTH-1;state<=EMIT;
 end
 end
 EMIT:if(m_ready)begin
 if(pending_new)begin
 run_value<=pending_value;run_start<=pending_x;run_y<=pending_y;run_length<=1;pending_new<=0;
 if(pending_eol)state<=EMIT;else state<=COLLECT;
 end else begin
 have_run<=0;
 if(m_last)state<=DONE;else state<=COLLECT;
 end
 end
 DONE:if(done_ready)state<=COLLECT;
 default:state<=COLLECT;
 endcase
 end
endmodule
