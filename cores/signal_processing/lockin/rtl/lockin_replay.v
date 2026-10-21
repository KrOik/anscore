// Finite replay owner. Abort discards incomplete source/core transaction but
// preserves the canonical source timestamp epoch. Failed output data is zero.
module lockin_replay #(
 parameter SIN_FILE="cores/signal_processing/lockin/vectors/sine.mem",
 parameter COS_FILE="cores/signal_processing/lockin/vectors/cosine.mem"
)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [31:0] cmd_tuning,cmd_period,cmd_id,cmd_timeout,input wire [3:0] cmd_log2,
 input wire [63:0] cmd_amplitudes,cmd_offsets,cmd_gains,input wire [31:0] cmd_phases,
 input wire sample_allow,
 output wire m_valid,input wire m_ready,output reg [63:0] m_i,m_q,m_amplitude,
 output reg [71:0] m_phase,output reg [63:0] m_first,m_last,
 output reg [31:0] m_id,m_cycles,m_generated,m_accepted,m_dropped,output reg [7:0] m_error
);
 localparam IDLE=0,RUN=1,ABORT=2,RESPONSE=3;
 reg [1:0] state;reg [31:0] timeout,age;
 wire adc_ready,core_ready,adc_valid,core_sample_ready,adc_done,core_done;
 wire [63:0] samples,ci,cq,ca,cf,cl;wire [255:0] timestamps;wire [71:0] cp;
 wire [31:0] cid,generated,accepted,dropped;wire [1:0] adc_error;wire [4:0] core_error;
 wire launch=cmd_valid&&cmd_ready&&cmd_timeout!=0;
 wire finish=state==RUN&&core_done&&adc_done&&adc_error==0&&core_error==0;
 assign cmd_ready=rst_n&&state==IDLE&&adc_ready&&core_ready;
 assign m_valid=rst_n&&state==RESPONSE;
 virtual_adc4 #(.COS_FILE(COS_FILE)) source(clk,rst_n,launch,adc_ready,cmd_tuning,cmd_period,cmd_log2,
  cmd_amplitudes,cmd_phases,adc_valid,state==RUN&&core_sample_ready&&sample_allow,samples,timestamps,
  adc_done,finish,adc_error,generated,accepted,dropped,state==ABORT);
 lockin4 #(.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE)) core(clk,rst_n&&state!=ABORT,
  launch,core_ready,cmd_tuning,cmd_period,cmd_id,cmd_log2,cmd_offsets,cmd_gains,
  state==RUN&&adc_valid&&sample_allow,core_sample_ready,samples,timestamps,
  core_done,finish,ci,cq,ca,cp,cf,cl,cid,core_error);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;timeout<=0;age<=0;m_i<=0;m_q<=0;m_amplitude<=0;m_phase<=0;
   m_first<=0;m_last<=0;m_id<=0;m_cycles<=0;m_generated<=0;m_accepted<=0;m_dropped<=0;m_error<=0;
  end else case(state)
   IDLE:if(cmd_valid&&cmd_ready)begin
    timeout<=cmd_timeout;age<=0;m_id<=cmd_id;m_cycles<=0;m_error<=0;
    m_i<=0;m_q<=0;m_amplitude<=0;m_phase<=0;m_first<=0;m_last<=0;
    m_generated<=0;m_accepted<=0;m_dropped<=0;
    if(cmd_timeout==0)begin m_error<=128;state<=RESPONSE;end else state<=RUN;
   end
   RUN:begin
    age<=age+1'b1;
    if(adc_error!=0||core_error!=0||age>=timeout-1)begin
     m_error<={age>=timeout-1,adc_error[1],adc_error[0],core_error};
     m_cycles<=age+1'b1;state<=ABORT;
    end else if(finish)begin
     m_i<=ci;m_q<=cq;m_amplitude<=ca;m_phase<=cp;m_first<=cf;m_last<=cl;
     m_cycles<=age+1'b1;m_generated<=generated;m_accepted<=accepted;m_dropped<=dropped;state<=RESPONSE;
    end
   end
   ABORT:begin
    // Source synchronous abort and these snapshots share the same edge;
    // counters retain all events up to the abort,while pending offers vanish.
    m_generated<=generated;m_accepted<=accepted;m_dropped<=dropped;state<=RESPONSE;
   end
   RESPONSE:if(m_ready)state<=IDLE;
  endcase
 end
endmodule
