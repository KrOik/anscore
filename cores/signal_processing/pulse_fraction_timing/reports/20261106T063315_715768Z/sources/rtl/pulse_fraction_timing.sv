// SPDX-License-Identifier: Apache-2.0
module pulse_fraction_timing #(
 parameter integer DATA_W=12, MAX_SAMPLES=256, TAG_W=8,
 parameter integer INDEX_W=$clog2(MAX_SAMPLES), TIME_W=INDEX_W+16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire[31:0]c_samples,c_fraction,
 input wire signed[DATA_W-1:0]c_baseline,input wire c_negative,
 input wire[DATA_W-1:0]c_min_peak,input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire signed[DATA_W-1:0]s_sample,input wire s_last,
 output wire m_valid,input wire m_ready,output reg[3:0]m_status,
 output reg[TAG_W-1:0]m_tag,output reg[DATA_W-1:0]m_peak,
 output reg[INDEX_W-1:0]m_peak_index,output reg[1:0]m_sides,
 output reg[TIME_W-1:0]m_left_q16,m_right_q16,m_width_q16
);
 localparam integer COUNT_W=$clog2(MAX_SAMPLES+1), DIV_W=DATA_W+10;
 localparam IDLE=0,FILL=1,MUL_ISSUE=2,MUL_WAIT=3,LEFT_INIT=4,
  READ_SAMPLE=5,TEST_SAMPLE=6,RIGHT_INIT=7,DIV_PICK=8,DIV_WAIT=9,FINISH=10,OUT=11,FLUSH=12;
 reg[3:0]state;
 reg[COUNT_W-1:0]length;
 reg[INDEX_W-1:0]index,peak_index,scan_index,left_base,right_base;
 reg signed[DATA_W-1:0]baseline;
 reg negative;
 reg[7:0]fraction;
 reg[DATA_W-1:0]min_peak,peak;
 reg[DATA_W+7:0]threshold;
 reg signed[DATA_W:0]previous;
 reg side,div_side,left_found,right_found;
 reg[DIV_W-1:0]left_num,left_den,right_num,right_den;
 (* ram_style="block" *) reg[DATA_W-1:0]samples[0:MAX_SAMPLES-1];
 reg[DATA_W-1:0]read_sample;
 function automatic signed[DATA_W:0]normalize;
  input signed[DATA_W-1:0]x,b;
  input neg;
  reg signed[DATA_W:0]delta;
  begin delta=$signed({x[DATA_W-1],x})-$signed({b[DATA_W-1],b});normalize=neg?-delta:delta;end
 endfunction
 wire signed[DATA_W:0]input_y=normalize(s_sample,baseline,negative);
 wire signed[DATA_W:0]read_y=normalize($signed(read_sample),baseline,negative);
 wire signed[DIV_W-1:0]scaled_read=$signed({{9{read_y[DATA_W]}},read_y})<<<8;
 wire signed[DIV_W-1:0]scaled_previous=$signed({{9{previous[DATA_W]}},previous})<<<8;
 wire signed[DIV_W-1:0]scaled_threshold=$signed({2'b00,threshold});
 wire multiply_ready,multiply_valid,divide_ready,divide_valid;
 wire[DATA_W+7:0]multiply_product;
 wire[17:0]divide_result;
 wire[1:0]divide_flags;
 reg multiply_rst_n;
 always @(posedge clk)begin
  if(rst||state==FLUSH)multiply_rst_n<=0;else multiply_rst_n<=1;
 end
 wire helpers_rst_n=!rst&&state!=FLUSH;
 img_hist_serial_multiply #(.A_W(DATA_W),.B_W(8)) threshold_multiply(
  .clk(clk),.rst_n(multiply_rst_n),.clk_en(1'b1),
  .s_valid(state==MUL_ISSUE&&peak>=min_peak&&!rst),.s_ready(multiply_ready),
  .s_a(peak),.s_b(fraction),.m_valid(multiply_valid),.m_ready(state==MUL_WAIT),.m_product(multiply_product));
 fp_div_iter #(.AW(DIV_W),.BW(DIV_W),.FB(16),.OUT_W(18)) crossing_divide(
  .clk(clk),.rst_n(helpers_rst_n),
  .s_tdata(div_side?{right_den,right_num}:{left_den,left_num}),
  .s_tvalid(state==DIV_PICK&&(div_side?right_found:left_found)&&!rst),.s_tready(divide_ready),
  .m_tdata(divide_result),.m_tuser(divide_flags),.m_tvalid(divide_valid),.m_tready(state==DIV_WAIT));
 assign c_ready=!rst&&multiply_rst_n&&state==IDLE;
 assign s_ready=!rst&&state==FILL;
 assign m_valid=!rst&&state==OUT;
 always @(posedge clk)begin
  if(s_valid&&s_ready)samples[index]<=s_sample;
  if(state==READ_SAMPLE&&!rst)read_sample<=samples[scan_index];
 end
 task clear_result;
  begin m_peak<=0;m_peak_index<=0;m_sides<=0;m_left_q16<=0;m_right_q16<=0;m_width_q16<=0;end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;m_status<=0;m_tag<=0;clear_result();
   length<=0;index<=0;peak<=0;peak_index<=0;left_found<=0;right_found<=0;
  end else case(state)
   IDLE:if(c_valid&&c_ready)begin
    m_tag<=c_tag;m_status<=0;clear_result();
    baseline<=c_baseline;negative<=c_negative;fraction<=c_fraction[7:0];min_peak<=c_min_peak;
    index<=0;peak<=0;peak_index<=0;left_found<=0;right_found<=0;div_side<=0;
    if(c_samples<3||c_samples>MAX_SAMPLES)begin m_status<=1;state<=OUT;end
    else if(c_fraction==0||c_fraction>255)begin m_status<=2;state<=OUT;end
    else if(c_min_peak==0)begin m_status<=3;state<=OUT;end
    else begin length<=c_samples[COUNT_W-1:0];state<=FILL;end
   end
   FILL:if(s_valid&&s_ready)begin
    if(input_y>$signed({1'b0,peak}))begin peak<=input_y[DATA_W-1:0];peak_index<=index;end
    if(s_last!=(index==length-1'b1))begin m_status<=4;clear_result();state<=OUT;end
    else if(index==length-1'b1)state<=MUL_ISSUE;
    else index<=index+1'b1;
   end
   MUL_ISSUE:begin
    if(peak<min_peak)begin m_status<=5;m_peak<=peak;m_peak_index<=peak_index;state<=OUT;end
    else if(multiply_ready)state<=MUL_WAIT;
   end
   MUL_WAIT:if(multiply_valid)begin threshold<=multiply_product;state<=LEFT_INIT;end
   LEFT_INIT:begin
    side<=0;previous<=$signed({1'b0,peak});
    if(peak_index==0)state<=RIGHT_INIT;
    else begin scan_index<=peak_index-1'b1;state<=READ_SAMPLE;end
   end
   READ_SAMPLE:state<=TEST_SAMPLE;
   TEST_SAMPLE:begin
    if(scaled_read<=scaled_threshold)begin
     if(!side)begin
      left_found<=1;left_base<=scan_index;
      left_num<=scaled_threshold-scaled_read;left_den<=scaled_previous-scaled_read;
      state<=RIGHT_INIT;
     end else begin
      right_found<=1;right_base<=scan_index-1'b1;
      right_num<=scaled_previous-scaled_threshold;right_den<=scaled_previous-scaled_read;
      state<=DIV_PICK;
     end
    end else if(!side&&scan_index==0)state<=RIGHT_INIT;
    else if(side&&scan_index==length-1'b1)state<=DIV_PICK;
    else begin previous<=read_y;scan_index<=side?scan_index+1'b1:scan_index-1'b1;state<=READ_SAMPLE;end
   end
   RIGHT_INIT:begin
    side<=1;previous<=$signed({1'b0,peak});
    if(peak_index==length-1'b1)state<=DIV_PICK;
    else begin scan_index<=peak_index+1'b1;state<=READ_SAMPLE;end
   end
   DIV_PICK:begin
    if(!(div_side?right_found:left_found))begin
     if(!div_side)div_side<=1;else state<=FINISH;
    end else if(divide_ready)state<=DIV_WAIT;
   end
   DIV_WAIT:if(divide_valid)begin
    if(divide_flags!=0||divide_result>18'd65536)begin m_status<=7;clear_result();state<=FLUSH;end
    else begin
     if(!div_side)begin m_left_q16<={left_base,16'b0}+TIME_W'(divide_result);div_side<=1;state<=DIV_PICK;end
     else begin m_right_q16<={right_base,16'b0}+TIME_W'(divide_result);state<=FINISH;end
    end
   end
   FINISH:begin
    m_status<=(left_found&&right_found)?0:6;m_peak<=peak;m_peak_index<=peak_index;
    m_sides<={right_found,left_found};m_width_q16<=(left_found&&right_found)?m_right_q16-m_left_q16:0;
    state<=OUT;
   end
   FLUSH:if(!multiply_rst_n)state<=OUT;
   OUT:if(m_ready)state<=IDLE;
   default:begin m_status<=7;clear_result();state<=FLUSH;end
  endcase
 end
 initial if(DATA_W<8||DATA_W>16||MAX_SAMPLES<3||MAX_SAMPLES>4096||TAG_W<1||TAG_W>32||
  INDEX_W!=$clog2(MAX_SAMPLES)||TIME_W!=INDEX_W+16)$fatal(1,"pulse_fraction_timing parameters");
endmodule
