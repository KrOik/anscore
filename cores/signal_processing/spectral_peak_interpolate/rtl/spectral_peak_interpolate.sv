// SPDX-License-Identifier: Apache-2.0
// Three-point quadratic interpolation of the strongest power-spectrum bin.
module spectral_peak_interpolate #(
 parameter integer MAX_LOG2N=8, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_log2n,c_low,c_high,c_min_power,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_power,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,
 output reg [2:0] m_status,output reg [TAG_W-1:0] m_tag,
 output reg [31:0] m_log2n,m_low,m_high,m_min_power,
 output reg [12:0] m_received,
 output reg [31:0] m_peak_index,m_left,m_center,m_right,
 output reg signed [33:0] m_curvature,
 output reg signed [17:0] m_offset_q16,
 output reg [31:0] m_bin_q16,output reg m_interp_valid
);
 localparam [3:0] IDLE=0,CONFIG=1,COLLECT=2,WAITPK=3,
  RD_L=4,CAP_L=5,RD_C=6,CAP_C=7,RD_R=8,CAP_R=9,
  ARITH=10,DIVSEND=11,DIVWAIT=12,OUT=13;
 reg [3:0] state;
 reg [31:0] ram [0:(1<<MAX_LOG2N)-1];
 reg [31:0] ram_q;
 reg [MAX_LOG2N-1:0] read_addr;
 reg [12:0] length,count;
 reg signed [32:0] numerator;
 reg signed [34:0] denominator;
 wire support_n=!rst && state!=IDLE && state!=OUT;
 wire pk_cfg_ready,pk_cfg_done,pk_cfg_error,pk_ready,pk_valid,pk_threshold;
 wire [47:0] pk_result;
 wire in_band=({19'd0,count}>=m_low && {19'd0,count}<=m_high);
 wire sample_fire=s_valid && s_ready;
 wire sample_good=!s_invalid && !s_last && count!=length-1'b1 ||
                  !s_invalid && s_last && count==length-1'b1;
 assign c_ready=!rst && state==IDLE;
 assign s_ready=!rst && state==COLLECT && pk_ready;
 assign m_valid=!rst && state==OUT;
 peak_search #(.MAX_LOG2N(MAX_LOG2N)) selector(
  .clk(clk),.rst_n(support_n),.s_tdata(in_band?s_power:32'd0),
  .s_tvalid(state==COLLECT && s_valid && sample_good),.s_tready(pk_ready),
  .m_tdata(pk_result),.m_tuser(pk_threshold),.m_tvalid(pk_valid),.m_tready(state==WAITPK),
  .cfg_valid(state==CONFIG),.cfg_ready(pk_cfg_ready),.cfg_log2n(m_log2n[3:0]),
  .cfg_thr_en(2'd0),.cfg_threshold(32'd0),.cfg_done(pk_cfg_done),.cfg_error(pk_cfg_error));
 wire div_ready,div_valid;
 wire [17:0] div_result;
 wire [1:0] div_flags;
 fp_div_iter #(.AW(33),.BW(35),.FB(16),.OUT_W(18)) divider(
  .clk(clk),.rst_n(support_n),.s_tdata({denominator,numerator}),
  .s_tvalid(state==DIVSEND),.s_tready(div_ready),
  .m_tdata(div_result),.m_tuser(div_flags),.m_tvalid(div_valid),.m_tready(state==DIVWAIT));
 wire signed [33:0] curve_now=$signed({1'b0,m_center,1'b0})-
  $signed({2'b0,m_left})-$signed({2'b0,m_right});
 wire signed [32:0] difference_now=$signed({1'b0,m_right})-$signed({1'b0,m_left});
 wire signed [32:0] refined=$signed({1'b0,m_peak_index[15:0],16'b0})+
  $signed({{15{div_result[17]}},div_result});
 always @* begin
  read_addr=m_peak_index[MAX_LOG2N-1:0];
  if(state==RD_L)read_addr=m_peak_index[MAX_LOG2N-1:0]-1'b1;
  if(state==RD_R)read_addr=m_peak_index[MAX_LOG2N-1:0]+1'b1;
 end
 // A single synchronous read port; reads and collection writes never overlap.
 always @(posedge clk)begin
  if(sample_fire)ram[count[MAX_LOG2N-1:0]]<=s_power;
  if(state==RD_L || state==RD_C || state==RD_R)ram_q<=ram[read_addr];
 end
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;length<=0;count<=0;numerator<=0;denominator<=0;
   m_status<=0;m_tag<=0;m_log2n<=0;m_low<=0;m_high<=0;m_min_power<=0;
   m_received<=0;m_peak_index<=0;m_left<=0;m_center<=0;m_right<=0;
   m_curvature<=0;m_offset_q16<=0;m_bin_q16<=0;m_interp_valid<=0;
  end else case(state)
   IDLE:if(c_valid)begin
    m_tag<=c_tag;m_log2n<=c_log2n;m_low<=c_low;m_high<=c_high;m_min_power<=c_min_power;
    m_status<=0;m_received<=0;m_peak_index<=0;m_left<=0;m_center<=0;m_right<=0;
    m_curvature<=0;m_offset_q16<=0;m_bin_q16<=0;m_interp_valid<=0;count<=0;
    if(c_log2n<4 || c_log2n>MAX_LOG2N || c_low<1 || c_low>c_high ||
       c_high>((32'd1<<c_log2n)-32'd2))begin m_status<=1;state<=OUT;end
    else begin length<=13'd1<<c_log2n;state<=CONFIG;end
   end
   CONFIG:if(pk_cfg_ready)state<=COLLECT;
   COLLECT:if(sample_fire)begin
    m_received<=count+1'b1;
    if(s_invalid)begin m_status<=2;state<=OUT;end
    else if(s_last && count!=length-1'b1)begin m_status<=3;state<=OUT;end
    else if(!s_last && count==length-1'b1)begin m_status<=4;state<=OUT;end
    else if(count==length-1'b1)state<=WAITPK;
    else count<=count+1'b1;
   end
   WAITPK:if(pk_valid)begin
    // Zero masking wins outside-band ties only when every candidate is zero.
    m_peak_index<=pk_result[31:0]==0?m_low:{16'd0,pk_result[47:32]};
    state<=RD_L;
   end
   RD_L:state<=CAP_L;
   CAP_L:begin m_left<=ram_q;state<=RD_C;end
   RD_C:state<=CAP_C;
   CAP_C:begin m_center<=ram_q;state<=RD_R;end
   RD_R:state<=CAP_R;
   CAP_R:begin m_right<=ram_q;state<=ARITH;end
   ARITH:begin
    m_curvature<=curve_now;m_bin_q16<={m_peak_index[15:0],16'd0};
    numerator<=difference_now;denominator<=$signed({curve_now,1'b0});
    if(m_center!=0 && m_center>=m_min_power && m_center>=m_left &&
       m_center>=m_right && curve_now>0)state<=DIVSEND;
    else state<=OUT;
   end
   DIVSEND:if(div_ready)state<=DIVWAIT;
   DIVWAIT:if(div_valid)begin
    if(div_flags!=0)begin m_status<=5;m_curvature<=0;m_bin_q16<=0;end
    else begin m_offset_q16<=div_result;m_bin_q16<=refined[31:0];m_interp_valid<=1;end
    state<=OUT;
   end
   OUT:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
 generate if(MAX_LOG2N<4 || MAX_LOG2N>12 || TAG_W<1 || TAG_W>32)begin:unsupported
  SPECTRAL_PEAK_INTERPOLATE_UNSUPPORTED_PARAMETERS invalid_configuration();
 end endgenerate
endmodule
