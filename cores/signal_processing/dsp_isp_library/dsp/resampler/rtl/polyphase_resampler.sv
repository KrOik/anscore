// Causal upsample L / FIR / downsample M. Shared multiplier, explicit flush.
module polyphase_resampler #(
 parameter integer MAX_TAPS=128, parameter integer MAX_INPUTS=65535
) (
 input wire clk,rst_n,
 input wire signed [15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg signed [15:0] m_tdata,output reg m_tuser,
 output reg m_tvalid,input wire m_tready,
 input wire cfg_valid,output wire cfg_ready,
 input wire [3:0] cfg_l,cfg_m,input wire [7:0] cfg_taps,
 input wire [18*MAX_TAPS-1:0] cfg_coeffs,
 output reg cfg_done,cfg_error,
 input wire flush_valid,output wire flush_ready,output reg flush_done,
 output reg [15:0] input_count,output reg [19:0] output_count,
 output reg capacity_error
);
 localparam WAIT_INPUT=0,MULTIPLY=1,ACCUMULATE=2,DONE=3;
 reg [1:0] state;
 reg [3:0] ratio_l,ratio_m,phase,need;
 reg [7:0] taps,coeff_index,history_index,history_valid;
 reg signed [17:0] coefficients[0:MAX_TAPS-1];
 reg signed [15:0] history[0:MAX_TAPS-1];
 reg signed [33:0] product;
 reg signed [40:0] accumulator;
 reg [19:0] time_index,end_time;
 reg draining;
 wire advance=rst_n && (!m_tvalid || m_tready);
 assign cfg_ready=rst_n && (state==WAIT_INPUT || state==DONE) && !m_tvalid && !draining;
 assign flush_ready=rst_n && state==WAIT_INPUT && !m_tvalid && !draining && !cfg_valid;
 assign s_tready=advance && state==WAIT_INPUT && need!=0 && !draining && !cfg_valid && !flush_valid && input_count<MAX_INPUTS;
 wire take_real=s_tvalid && s_tready;
 wire take_zero=advance && state==WAIT_INPUT && need!=0 && draining && time_index<=end_time;
 wire take_sample=take_real || take_zero;
 wire signed [15:0] sample_value=take_zero ? 16'sd0 : s_tdata;
 wire signed [15:0] mac_sample=history_index<history_valid ? history[history_index] : 16'sd0;
 wire signed [33:0] multiply_value=coefficients[coeff_index]*mac_sample;
 wire signed [40:0] sum_value=accumulator+$signed({{7{product[33]}},product});
 function signed [25:0] rounded;
  input signed [40:0] value;
  reg signed [40:0] q;
  begin
   // RNE(value/2**15) as a single adder: (x + 2**14 - 1 + q[0]) >>> 15 is
   // bit-exactly the round-half-up-then-ties-to-even compare/increment it
   // replaces, and removes a 15-bit magnitude compare plus a mux from the
   // already-deep accumulate->saturate output cone.
   q=value+41'sd16383+$signed({40'd0,value[15]});
   rounded=q>>>15;
  end
 endfunction
 wire signed [25:0] output_wide=rounded(sum_value);
 // in range [-32768,32767] iff every bit above 15 duplicates the sign
 wire output_clip=output_wide[25:15]!={11{output_wide[15]}};
 function [19:0] input_time;
  input [15:0] n;input [3:0] l;
  integer bitnum;
  begin
   input_time=0;
   for(bitnum=0;bitnum<4;bitnum=bitnum+1)if(l[bitnum])input_time=input_time+({4'd0,n}<<bitnum);
  end
 endfunction
 reg [4:0] next_phase;
 reg [3:0] next_need;
 integer k;
 always @* begin
  next_phase={1'b0,phase}+{1'b0,ratio_m};next_need=0;
  for(k=0;k<8;k=k+1)begin
   if(next_phase>=ratio_l)begin next_phase=next_phase-ratio_l;next_need=next_need+1'b1;end
  end
 end
 integer i;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=WAIT_INPUT;ratio_l<=1;ratio_m<=1;taps<=1;phase<=0;need<=1;
   coeff_index<=0;history_index<=0;history_valid<=0;product<=0;accumulator<=0;
   time_index<=0;end_time<=0;draining<=0;
   input_count<=0;output_count<=0;capacity_error<=0;
   m_tvalid<=0;m_tdata<=0;m_tuser<=0;cfg_done<=0;cfg_error<=0;flush_done<=0;
   for(i=0;i<MAX_TAPS;i=i+1)coefficients[i]<=i==0 ? 18'sd32768 : 18'sd0;
  end else begin
   cfg_done<=0;cfg_error<=0;flush_done<=0;
   if(m_tvalid && m_tready)output_count<=output_count+1'b1;
   if(m_tready)m_tvalid<=0;
   if(!draining && state==WAIT_INPUT && need!=0 && !cfg_valid && !flush_valid && s_tvalid && input_count==MAX_INPUTS)capacity_error<=1;
   if(cfg_valid && cfg_ready)begin
    cfg_done<=1;
    if(cfg_l<1 || cfg_l>8 || cfg_m<1 || cfg_m>8 || cfg_taps<cfg_l || cfg_taps>MAX_TAPS)cfg_error<=1;
    else begin
     ratio_l<=cfg_l;ratio_m<=cfg_m;taps<=cfg_taps;
     phase<=0;need<=1;state<=WAIT_INPUT;history_valid<=0;time_index<=0;end_time<=0;draining<=0;
     input_count<=0;output_count<=0;capacity_error<=0;
     accumulator<=0;product<=0;coeff_index<=0;history_index<=0;
     for(i=0;i<MAX_TAPS;i=i+1)coefficients[i]<=cfg_coeffs[i*18 +:18];
    end
   end else if(flush_valid && flush_ready)begin
    if(input_count==0)begin state<=DONE;flush_done<=1;end
    else begin draining<=1;end_time<=input_time(input_count-1'b1,ratio_l)+taps-1'b1;end
   end else if(advance)begin
    case(state)
     WAIT_INPUT:begin
      if(draining && time_index>end_time)begin state<=DONE;draining<=0;flush_done<=1;end
      else if(draining || (!cfg_valid && !flush_valid))begin
       if(need==0)begin coeff_index<={4'd0,phase};history_index<=0;accumulator<=0;state<=MULTIPLY;end
       else if(take_sample)begin
        need<=need-1'b1;
        if(need==1)begin coeff_index<={4'd0,phase};history_index<=0;accumulator<=0;state<=MULTIPLY;end
       end
      end
     end
     MULTIPLY:begin product<=multiply_value;state<=ACCUMULATE;end
     ACCUMULATE:begin
      accumulator<=sum_value;
      if({1'b0,coeff_index}+ratio_l>=taps)begin
       m_tvalid<=1;m_tuser<=output_clip;
       m_tdata<=output_clip ? (output_wide[25] ? 16'sh8000 : 16'sh7fff) : output_wide[15:0];
       phase<=next_phase[3:0];need<=next_need;time_index<=time_index+ratio_m;state<=WAIT_INPUT;
      end else begin coeff_index<=coeff_index+ratio_l;history_index<=history_index+1'b1;state<=MULTIPLY;end
     end
     DONE:state<=DONE;
    endcase
   end
   if(take_sample)begin
    history[0]<=sample_value;
    for(i=1;i<MAX_TAPS;i=i+1)history[i]<=history[i-1];
    if(history_valid<MAX_TAPS)history_valid<=history_valid+1'b1;
    if(take_real)input_count<=input_count+1'b1;
   end
  end
 end
`ifndef SYNTHESIS
 initial if(MAX_TAPS<1 || MAX_TAPS>128 || MAX_INPUTS<1 || MAX_INPUTS>65535)$fatal(1,"unsupported static configuration");
`endif
endmodule
