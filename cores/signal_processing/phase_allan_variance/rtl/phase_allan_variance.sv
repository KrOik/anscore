// SPDX-License-Identifier: Apache-2.0
// Exact single-tau overlapping Allan variance of uniformly spaced phase samples.
module phase_allan_variance #(
 parameter integer DATA_W=16,MAX_SAMPLES=256,MAX_M=64,TAG_W=8,
 parameter integer SUM_W=2*DATA_W+2+$clog2(MAX_SAMPLES),
 parameter integer VAR_W=2*DATA_W+18
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_samples,c_m,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,
 input wire signed [DATA_W-1:0] s_phase,input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,
 output reg [2:0] m_status,output reg [TAG_W-1:0] m_tag,
 output reg [31:0] m_samples,m_m,output reg [12:0] m_received,m_terms,
 output reg [SUM_W-1:0] m_sum,output reg [24:0] m_den,
 output reg [VAR_W-1:0] m_variance_q16
);
 localparam integer AW=$clog2(MAX_SAMPLES),DW=DATA_W+2,DIV_AW=SUM_W+1;
 localparam [3:0] IDLE=0,INPUTS=1,R0=2,R1=3,R2=4,DIFF=5,ABS=6,
  SQ_SEND=7,SQ_WAIT=8,M2_SEND=9,M2_WAIT=10,DEN_SEND=11,DEN_WAIT=12,
  DIV_SEND=13,DIV_WAIT=14,EMIT=15;
 localparam PARAM_OK=DATA_W>=8&&DATA_W<=16&&MAX_SAMPLES>=3&&MAX_SAMPLES<=4096&&
  MAX_M>=1&&MAX_M<=64&&TAG_W>=1&&TAG_W<=32&&
  SUM_W==2*DATA_W+2+$clog2(MAX_SAMPLES)&&VAR_W==2*DATA_W+18;
 generate if(!PARAM_OK)begin:g_bad_parameters
  phase_allan_variance_UNSUPPORTED_PARAMETERS invalid_parameters();
 end endgenerate
 reg [3:0] state;
 (* ram_style="block" *) reg signed [DATA_W-1:0] mem[0:MAX_SAMPLES-1];
 reg signed [DATA_W-1:0] read_data,x0,x1;
 reg [12:0] length,received,terms,index;
 reg [6:0] tau_m;
 reg invalid_seen;
 reg signed [DW-1:0] difference;
 reg [17:0] magnitude;
 reg [12:0] m_squared;
 reg [24:0] denominator;
 reg [SUM_W-1:0] accumulator;
 // The shared multiplier has an asynchronous reset. Originate its reset only
 // on clk so the public reset contract remains a synchronous cancellation.
 reg multiply_rst_n;
 always @(posedge clk) multiply_rst_n<=!rst;
 assign c_ready=!rst&&state==IDLE;
 assign s_ready=!rst&&state==INPUTS;
 assign m_valid=!rst&&state==EMIT;
 wire input_fire=s_valid&&s_ready;
 wire read_enable=state==R0||state==R1||state==R2;
 wire [12:0] read_index=state==R1 ? index+{6'b0,tau_m} :
  state==R2 ? index+{5'b0,tau_m,1'b0} : index;
 always @(posedge clk)begin
  if(input_fire)mem[received[AW-1:0]]<=s_phase;
  if(read_enable)read_data<=mem[read_index[AW-1:0]];
 end
 wire signed [DW-1:0] a0={{2{x0[DATA_W-1]}},x0};
 wire signed [DW-1:0] a1={{2{x1[DATA_W-1]}},x1};
 wire signed [DW-1:0] a2={{2{read_data[DATA_W-1]}},read_data};
 wire [DW-1:0] abs_difference=difference[DW-1] ? -difference : difference;
 wire multiply_valid=state==SQ_SEND||state==M2_SEND||state==DEN_SEND;
 wire multiply_ready,multiply_result_valid;
 wire multiply_result_ready=state==SQ_WAIT||state==M2_WAIT||state==DEN_WAIT;
 wire [17:0] multiply_a=state==M2_SEND ? {11'b0,tau_m} :
  state==DEN_SEND ? {5'b0,m_squared} : magnitude;
 wire [17:0] multiply_b=state==M2_SEND ? {11'b0,tau_m} :
  state==DEN_SEND ? {5'b0,terms} : magnitude;
 wire [35:0] multiply_product;
 img_hist_serial_multiply #(.A_W(18),.B_W(18)) square_and_denominator(
  .clk(clk),.rst_n(multiply_rst_n),.clk_en(1'b1),
  .s_valid(multiply_valid),.s_ready(multiply_ready),.s_a(multiply_a),.s_b(multiply_b),
  .m_valid(multiply_result_valid),.m_ready(multiply_result_ready),.m_product(multiply_product));
 wire [SUM_W-1:0] square_extended;
 generate if(SUM_W>=36)begin:g_extend_square
  assign square_extended={{(SUM_W-36){1'b0}},multiply_product};
 end else begin:g_bounded_square
  // |difference| <= 2^(DATA_W+1)-2, so the omitted high bits are zero.
  assign square_extended=multiply_product[SUM_W-1:0];
 end endgenerate
 wire divide_ready,divide_valid;
 wire [1:0] divide_flags;
 wire [VAR_W-1:0] divide_data;
 // Leading zeros preserve the signed helper's complete unsigned operands.
 // AW+FB = SUM_W+17 retains every bit of accumulator<<16 plus its sign.
 fp_div_iter #(.AW(DIV_AW),.BW(26),.FB(16),.OUT_W(VAR_W)) normalization(
  .clk(clk),.rst_n(!rst),.s_tdata({1'b0,denominator,1'b0,accumulator}),
  .s_tvalid(state==DIV_SEND),.s_tready(divide_ready),
  .m_tdata(divide_data),.m_tuser(divide_flags),.m_tvalid(divide_valid),.m_tready(state==DIV_WAIT));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;length<=0;received<=0;terms<=0;index<=0;tau_m<=0;invalid_seen<=0;
   difference<=0;magnitude<=0;m_squared<=0;denominator<=0;accumulator<=0;x0<=0;x1<=0;
   m_status<=0;m_tag<=0;m_samples<=0;m_m<=0;m_received<=0;m_terms<=0;
   m_sum<=0;m_den<=0;m_variance_q16<=0;
  end else case(state)
   IDLE:if(c_valid)begin
    m_tag<=c_tag;m_samples<=c_samples;m_m<=c_m;m_received<=0;m_terms<=0;
    m_sum<=0;m_den<=0;m_variance_q16<=0;m_status<=0;
    received<=0;index<=0;invalid_seen<=0;accumulator<=0;
    if(c_samples<3||c_samples>MAX_SAMPLES||c_m==0||c_m>MAX_M||
       {1'b0,c_samples}<=({1'b0,c_m}<<1))begin m_status<=1;state<=EMIT;end
    else begin
     length<=c_samples[12:0];tau_m<=c_m[6:0];terms<=c_samples-({1'b0,c_m}<<1);state<=INPUTS;
    end
   end
   INPUTS:if(input_fire)begin
    received<=received+1'b1;m_received<=received+1'b1;invalid_seen<=invalid_seen||s_invalid;
    if(s_last&&received!=length-1'b1)begin m_status<=2;state<=EMIT;end
    else if(received==length-1'b1)begin
     if(!s_last)begin m_status<=3;state<=EMIT;end
     else if(invalid_seen||s_invalid)begin m_status<=4;state<=EMIT;end
     else begin index<=0;state<=R0;end
    end
   end
   R0:state<=R1;
   R1:begin x0<=read_data;state<=R2;end
   R2:begin x1<=read_data;state<=DIFF;end
   DIFF:begin difference<=a2-(a1<<<1)+a0;state<=ABS;end
   ABS:begin magnitude<={{(18-DW){1'b0}},abs_difference};state<=SQ_SEND;end
   SQ_SEND:if(multiply_ready)state<=SQ_WAIT;
   SQ_WAIT:if(multiply_result_valid)begin
    accumulator<=accumulator+square_extended;
    if(index==terms-1'b1)state<=M2_SEND;
    else begin index<=index+1'b1;state<=R0;end
   end
   M2_SEND:if(multiply_ready)state<=M2_WAIT;
   M2_WAIT:if(multiply_result_valid)begin
    // m<=64 => m*m<=4096, exactly representable in 13 bits.
    m_squared<=multiply_product[12:0];state<=DEN_SEND;
   end
   DEN_SEND:if(multiply_ready)state<=DEN_WAIT;
   DEN_WAIT:if(multiply_result_valid)begin
    // m*m*(N-2m)<=64^2*3968=16252928<2^24; retain the exact doubled value.
    denominator<={multiply_product[23:0],1'b0};state<=DIV_SEND;
   end
   DIV_SEND:if(divide_ready)state<=DIV_WAIT;
   DIV_WAIT:if(divide_valid)begin
    if(divide_flags!=0)begin m_status<=5;end
    else begin m_sum<=accumulator;m_terms<=terms;m_den<=denominator;m_variance_q16<=divide_data;end
    state<=EMIT;
   end
   EMIT:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
