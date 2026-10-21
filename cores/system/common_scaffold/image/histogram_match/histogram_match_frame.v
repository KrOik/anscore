// Exact discrete normalized-CDF closest matching; ties choose lowest intensity.
module histogram_match_frame #(parameter BITS=8,WIDTH=32,HEIGHT=32,REF_COUNT_W=16)(
 input wire clk,rst,ce,
 input wire ref_begin_valid,output wire ref_begin_ready,
 input wire[REF_COUNT_W-1:0] ref_count,input wire ref_valid,ref_last,output wire ref_ready,
 input wire ref_commit_valid,output wire ref_commit_ready,
 output reg ref_result_valid,input wire ref_result_ready,output reg[1:0] ref_error,
 output reg ref_active_valid,
 input wire[BITS-1:0] s_gray,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire m_valid,input wire m_ready,output reg[BITS-1:0] m_gray,
 output wire[((WIDTH<2)?1:$clog2(WIDTH))-1:0] m_x,
 output wire[((HEIGHT<2)?1:$clog2(HEIGHT))-1:0] m_y,
 output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,
 output reg marker_error,arithmetic_error,output wire busy
);
 localparam BINS=1<<BITS,PIXELS=WIDTH*HEIGHT;
 localparam CW=$clog2(PIXELS+1),AW=PIXELS<2?1:$clog2(PIXELS),RW=REF_COUNT_W+BITS,PW=RW+CW;
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT),MW=$clog2(PW+1);
 localparam HCLEAR=0,CAPTURE=1,HREAD=2,HADD=3,CADDR=4,CREAD=5,CCDF=6,
 MULTIPLY=7,TARGET_DONE=8,RADDR=9,RREAD=10,RCDF=11,REF_DONE=12,COMPARE=13,
 MAPWRITE=14,FADDR=15,FREAD=16,LADDR=17,LREAD=18,RESULT=19,OUTPUT=20,DONE=21;
 reg[4:0] state,mul_return;
 reg active_bank,loading,load_complete,load_bad;
 reg[BITS-1:0] load_index,clear_index,hist_addr,input_bin,map_index,reference_index,map_value;
 reg[RW-1:0] load_sum,active_total,ref_q;
 reg[BITS:0] reference_addr;
 reg[RW-1:0] reference_cdf[0:2*BINS-1];
 reg[CW-1:0] current_hist[0:BINS-1],hist_q,current_cdf;
 reg[BITS-1:0] frame_mem[0:PIXELS-1],frame_q,lut_mem[0:BINS-1],lut_q,lut_addr;
 reg[AW-1:0] capture_addr,output_addr;
 reg[XW-1:0] capture_x,x;reg[YW-1:0] capture_y,y;
 reg last_input;
 reg[PW-1:0] multiplicand,multiplier,product,product_result,target,reference_product,previous_product;
 reg[MW-1:0] mul_bit;
 reg[BITS-1:0] previous_index;
 reg previous_valid;
 wire[PW-1:0] product_next=product+(multiplier[0]?multiplicand:0);
 wire[RW:0] load_next={1'b0,load_sum}+ref_count;
 assign ref_begin_ready=!rst&&ce&&state==CAPTURE&&capture_addr==0&&!loading&&!ref_result_valid;
 assign ref_ready=!rst&&ce&&loading&&!load_complete;
 assign ref_commit_ready=!rst&&ce&&loading&&load_complete&&!ref_result_valid;
 assign s_ready=!rst&&ce&&state==CAPTURE&&ref_active_valid&&!loading&&!ref_result_valid&&!(ref_begin_valid&&ref_begin_ready);
 assign m_valid=!rst&&state==OUTPUT;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;assign m_last=m_eol&&y==HEIGHT-1;
 assign done_valid=!rst&&state==DONE;
 assign busy=state!=CAPTURE||capture_addr!=0||loading||ref_result_valid;
 always @(posedge clk)if(ce&&!rst)begin
 if(ref_valid&&ref_ready)reference_cdf[{!active_bank,load_index}]<=load_next[RW-1:0];
 if(state==RREAD)ref_q<=reference_cdf[reference_addr];
 if(state==HCLEAR)current_hist[clear_index]<=0;
 else if(state==HADD)current_hist[input_bin]<=hist_q+1'b1;
 if(state==HREAD||state==CREAD)hist_q<=current_hist[hist_addr];
 if(state==CAPTURE&&s_valid&&s_ready)frame_mem[capture_addr]<=s_gray;
 if(state==FREAD)frame_q<=frame_mem[output_addr];
 if(state==MAPWRITE)lut_mem[map_index]<=map_value;
 if(state==LREAD)lut_q<=lut_mem[lut_addr];
 end
 initial if(BITS<8||BITS>12||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||REF_COUNT_W<1||REF_COUNT_W>24)$fatal(1,"invalid histogram match parameters");
 always @(posedge clk)begin
 if(rst)begin
 state<=HCLEAR;mul_return<=0;active_bank<=0;loading<=0;load_complete<=0;load_bad<=0;load_index<=0;load_sum<=0;active_total<=0;
 ref_result_valid<=0;ref_error<=0;ref_active_valid<=0;clear_index<=0;hist_addr<=0;input_bin<=0;map_index<=0;reference_index<=0;reference_addr<=0;map_value<=0;
 current_cdf<=0;capture_addr<=0;output_addr<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;last_input<=0;lut_addr<=0;m_gray<=0;
 multiplicand<=0;multiplier<=0;product<=0;product_result<=0;mul_bit<=0;target<=0;reference_product<=0;previous_product<=0;previous_index<=0;previous_valid<=0;
 marker_error<=0;arithmetic_error<=0;
 end else if(ce)begin
 if(ref_result_valid&&ref_result_ready)ref_result_valid<=0;
 if(ref_begin_valid&&ref_begin_ready)begin loading<=1;load_complete<=0;load_bad<=0;load_index<=0;load_sum<=0;end
 if(ref_valid&&ref_ready)begin
 load_sum<=load_next[RW-1:0];
 if(ref_last!=(load_index==BINS-1)||load_next[RW])load_bad<=1;
 if(load_index==BINS-1)load_complete<=1;else load_index<=load_index+1'b1;
 end
 if(ref_commit_valid&&ref_commit_ready)begin
 ref_result_valid<=1;ref_error<={load_bad,load_sum==0};loading<=0;load_complete<=0;
 if(!load_bad&&load_sum!=0)begin active_bank<=!active_bank;active_total<=load_sum;ref_active_valid<=1;end
 end
 case(state)
 HCLEAR:if(clear_index==BINS-1)begin clear_index<=0;state<=CAPTURE;end else clear_index<=clear_index+1'b1;
 CAPTURE:if(s_valid&&s_ready)begin
 if(capture_addr==0)begin marker_error<=0;arithmetic_error<=0;end
 if(s_sof!=(capture_addr==0)||s_eol!=(capture_x==WIDTH-1))marker_error<=1;
 input_bin<=s_gray;hist_addr<=s_gray;last_input<=capture_addr==PIXELS-1;
 if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
 if(capture_addr==PIXELS-1)begin capture_addr<=0;capture_x<=0;capture_y<=0;end else capture_addr<=capture_addr+1'b1;
 state<=HREAD;
 end
 HREAD:state<=HADD;
 HADD:if(last_input)begin map_index<=0;reference_index<=0;current_cdf<=0;previous_valid<=0;state<=CADDR;end else state<=CAPTURE;
 CADDR:begin hist_addr<=map_index;state<=CREAD;end
 CREAD:state<=CCDF;
 CCDF:begin
 current_cdf<=current_cdf+hist_q;
 multiplicand<=current_cdf+hist_q;multiplier<=active_total;product<=0;mul_bit<=0;mul_return<=TARGET_DONE;state<=MULTIPLY;
 end
 MULTIPLY:begin
 product<=product_next;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(mul_bit==PW-1)begin product_result<=product_next;state<=mul_return;end else mul_bit<=mul_bit+1'b1;
 end
 TARGET_DONE:begin target<=product_result;if(map_index==0)state<=RADDR;else state<=COMPARE;end
 RADDR:begin reference_addr<={active_bank,reference_index};state<=RREAD;end
 RREAD:state<=RCDF;
 RCDF:begin multiplicand<=ref_q;multiplier<=PIXELS;product<=0;mul_bit<=0;mul_return<=REF_DONE;state<=MULTIPLY;end
 REF_DONE:begin reference_product<=product_result;state<=COMPARE;end
 COMPARE:begin
 if(reference_product<target&&reference_index!=BINS-1)begin
 if(!previous_valid||reference_product!=previous_product)begin previous_valid<=1;previous_product<=reference_product;previous_index<=reference_index;end
 reference_index<=reference_index+1'b1;state<=RADDR;
 end else begin
 if(reference_product<target)arithmetic_error<=1;
 if(previous_valid&&target-previous_product<=reference_product-target)map_value<=previous_index;else map_value<=reference_index;
 state<=MAPWRITE;
 end
 end
 MAPWRITE:if(map_index==BINS-1)begin output_addr<=0;x<=0;y<=0;state<=FADDR;end
 else begin map_index<=map_index+1'b1;state<=CADDR;end
 FADDR:state<=FREAD;
 FREAD:state<=LADDR;
 LADDR:begin lut_addr<=frame_q;state<=LREAD;end
 LREAD:state<=RESULT;
 RESULT:begin m_gray<=lut_q;state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 if(output_addr==PIXELS-1)state<=DONE;
 else begin output_addr<=output_addr+1'b1;if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=FADDR;end
 end
 DONE:if(done_ready)begin clear_index<=0;state<=HCLEAR;end
 default:state<=HCLEAR;
 endcase
 end
 end
endmodule
