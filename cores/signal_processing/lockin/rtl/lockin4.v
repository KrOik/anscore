// Four simultaneous signed16 samples, coherent DDS and boxcar lock-in.
// Errors:0 cross-lane timestamp mismatch,1 cadence,2 calibration clip,
// 3 CORDIC magnitude limitation,4 invalid command. Error-tagged results invalid.
module lockin4 #(
 parameter SIN_FILE="cores/signal_processing/lockin/vectors/sine.mem",
 parameter COS_FILE="cores/signal_processing/lockin/vectors/cosine.mem"
)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [31:0] cmd_tuning,cmd_period,cmd_id,input wire [3:0] cmd_log2,
 input wire [63:0] cmd_offsets,cmd_gains,
 input wire s_valid,output wire s_ready,input wire [63:0] s_samples,
 input wire [255:0] s_timestamps,
 output wire m_valid,input wire m_ready,output reg [63:0] m_i,m_q,m_amplitude,
 output reg [71:0] m_phase,output reg [63:0] m_first,m_last,
 output reg [31:0] m_id,output reg [4:0] m_error
);
 localparam IDLE=0,ACCEPT=1,MIX=2,AVERAGE=3,ANGLE_SEND=4,ANGLE_WAIT=5,RESULT=6;
 reg [2:0] state;reg [31:0] tuning,period;reg [3:0] log2_n;
 reg [12:0] count;reg [1:0] lane;
 reg [63:0] offsets,gains,held_samples,previous_time;
 reg signed [47:0] sum_i[0:3],sum_q[0:3];
 reg signed [15:0] iq_i[0:3],iq_q[0:3];
 wire accept=s_valid&&s_ready;
 wire nco_reset=rst_n&&state!=IDLE;
 wire signed [15:0] sine,cosine;
 dds_nco #(.LUT_FILE(SIN_FILE)) sine_reference(clk,accept,nco_reset,1'b1,tuning,sine,,);
 dds_nco #(.LUT_FILE(COS_FILE)) cosine_reference(clk,accept,nco_reset,1'b1,tuning,cosine,,);
 wire signed [15:0] cordic_x,cordic_y;wire signed [17:0] cordic_phase;wire angle_valid;
 reg [3:0] normalize_shift;reg [16:0] normalize_max,abs_i,abs_q;
 integer norm_step;
 always @*begin
  abs_i=iq_i[lane]<0?-$signed({iq_i[lane][15],iq_i[lane]}):{1'b0,iq_i[lane]};
  abs_q=iq_q[lane]<0?-$signed({iq_q[lane][15],iq_q[lane]}):{1'b0,iq_q[lane]};
  normalize_max=abs_i>abs_q?abs_i:abs_q;normalize_shift=0;
  for(norm_step=0;norm_step<12;norm_step=norm_step+1)
   if(normalize_max!=0&&normalize_max<4096)begin normalize_max=normalize_max<<1;normalize_shift=normalize_shift+1'b1;end
 end
 wire signed [15:0] angle_i=iq_i[lane]<<<normalize_shift;
 wire signed [15:0] angle_q=iq_q[lane]<<<normalize_shift;
 cordic angle(clk,1'b1,rst_n,1'b1,state==ANGLE_SEND,angle_i,angle_q,16'sd0,
  cordic_x,cordic_y,cordic_phase,angle_valid);
 assign cmd_ready=rst_n&&state==IDLE;
 assign s_ready=rst_n&&state==ACCEPT;
 assign m_valid=rst_n&&state==RESULT;
 integer k;
 reg signed [16:0] delta;
 reg signed [33:0] calibrated;
 reg signed [15:0] corrected;
 reg signed [31:0] pi,pq;
 reg signed [47:0] pi_ext,pq_ext;
 reg signed [31:0] magnitude_product;
 // Drop the fixed15 fractional bits before the variable shift. This keeps
 // the variable barrel shifter33bits wide and is exact for signed floor.
 function [15:0] average16;
 input signed [47:0] value;input [3:0] shift;
 reg signed [32:0] coarse;
 begin coarse=value[47:15];average16=coarse>>>shift;end
 endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;tuning<=0;period<=0;log2_n<=0;count<=0;lane<=0;
   offsets<=0;gains<=0;held_samples<=0;previous_time<=0;
   m_i<=0;m_q<=0;m_amplitude<=0;m_phase<=0;m_first<=0;m_last<=0;m_id<=0;m_error<=0;
   for(k=0;k<4;k=k+1)begin sum_i[k]<=0;sum_q[k]<=0;iq_i[k]<=0;iq_q[k]<=0;end
  end else case(state)
   IDLE:if(cmd_valid)begin
    tuning<=cmd_tuning;period<=cmd_period;log2_n<=cmd_log2;offsets<=cmd_offsets;gains<=cmd_gains;
    m_id<=cmd_id;m_error<=0;count<=0;m_i<=0;m_q<=0;m_amplitude<=0;m_phase<=0;m_first<=0;m_last<=0;
    for(k=0;k<4;k=k+1)begin sum_i[k]<=0;sum_q[k]<=0;end
    if(cmd_log2<4||cmd_log2>12||cmd_period==0)begin m_error<=16;state<=RESULT;end
    else state<=ACCEPT;
   end
   ACCEPT:if(s_valid)begin
    held_samples<=s_samples;
    if(count==0)m_first<=s_timestamps[63:0];
    else if(s_timestamps[63:0]!=previous_time+period)m_error[1]<=1;
    for(k=1;k<4;k=k+1)if(s_timestamps[k*64+:64]!=s_timestamps[63:0])m_error[0]<=1;
    previous_time<=s_timestamps[63:0];m_last<=s_timestamps[63:0];state<=MIX;
   end
   MIX:begin
    for(k=0;k<4;k=k+1)begin
     delta=$signed(held_samples[k*16+:16])-$signed({offsets[k*16+15],offsets[k*16+:16]});
     calibrated=(delta*$signed({1'b0,gains[k*16+:16]}))>>>15;
     if(calibrated>32767)begin corrected=32767;m_error[2]<=1;end
     else if(calibrated< -32768)begin corrected=-32768;m_error[2]<=1;end
     else corrected=calibrated[15:0];
     pi=corrected*cosine;pq=corrected*sine;
     pi_ext={{16{pi[31]}},pi};pq_ext={{16{pq[31]}},pq};
     sum_i[k]<=sum_i[k]+pi_ext;sum_q[k]<=sum_q[k]-pq_ext;
    end
    count<=count+1'b1;
    if(count==(13'd1<<log2_n)-1)state<=AVERAGE;else state<=ACCEPT;
   end
   AVERAGE:begin
    for(k=0;k<4;k=k+1)begin
     iq_i[k]<=average16(sum_i[k],log2_n);iq_q[k]<=average16(sum_q[k],log2_n);
     m_i[k*16+:16]<=average16(sum_i[k],log2_n);m_q[k*16+:16]<=average16(sum_q[k],log2_n);
    end
    lane<=0;state<=ANGLE_SEND;
   end
   ANGLE_SEND:state<=ANGLE_WAIT;
   ANGLE_WAIT:if(angle_valid)begin
    // CORDIC gain compensation K=9949/16384,then x2 for real-tone amplitude.
    magnitude_product=cordic_x*32'sd19898;
    m_amplitude[lane*16+:16]<=iq_i[lane]==0&&iq_q[lane]==0?16'd0:
     (magnitude_product+(32'sd1<<(13+normalize_shift)))>>>(14+normalize_shift);
    m_phase[lane*18+:18]<=iq_i[lane]==0&&iq_q[lane]==0?18'd0:cordic_phase;
    if(cordic_x==32767)m_error[3]<=1;
    if(lane==3)state<=RESULT;else begin lane<=lane+1'b1;state<=ANGLE_SEND;end
   end
   RESULT:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
