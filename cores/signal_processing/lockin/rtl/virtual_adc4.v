// Fixed-clock scheduled, four-channel digital ADC stimulus (not analog ADC).
// One-vector elastic buffer; physical ticks never wait for downstream ready.
module virtual_adc4 #(parameter COS_FILE="cores/signal_processing/lockin/vectors/cosine.mem")(
 input wire clk,rst_n,start,output wire start_ready,
 input wire [31:0] tuning,period,input wire [3:0] log2_samples,
 input wire [63:0] amplitudes,input wire [31:0] phase_offsets,
 output reg m_valid,input wire m_ready,output reg [63:0] m_samples,
 output wire [255:0] m_timestamps,
 output wire done_valid,input wire done_ready,output reg [1:0] error,
 output reg [31:0] generated,accepted,dropped,input wire abort
);
 localparam IDLE=0,RUN=1,DRAIN=2,FINISH=3;
 reg [1:0] state;
 reg signed [15:0] cosine[0:255];initial $readmemh(COS_FILE,cosine);
 reg [31:0] phase,step,interval,countdown;
 reg [12:0] target;
 reg [63:0] amp,time_pending,time_output;
 reg [31:0] offsets;
 reg signed [15:0] ref0,ref1,ref2,ref3;
 reg sample_pending;
 wire [63:0] now;
 sys_timestamp64 clock_time(.clk(clk),.rst_n(rst_n),.load_valid(1'b0),.load_time(64'd0),
  .s_data(32'd0),.s_tag(16'd0),.s_valid(1'b0),.s_ready(),.m_data(),.m_tag(),.m_time(),
  .m_valid(),.m_ready(1'b1),.now(now));
 wire sample_tick=state==RUN&&countdown==0&&!abort;
 assign start_ready=rst_n&&state==IDLE;
 assign done_valid=rst_n&&state==FINISH;
 assign m_timestamps={4{time_output}};
 function [15:0] scaled;
 input [15:0] a;input signed [15:0] c;
 reg signed [32:0] product;
 begin product=$signed({1'b0,a})*c;scaled=product>>>15;end
 endfunction
 always @(posedge clk)if(sample_tick)begin
  ref0<=cosine[(phase[31:24]+offsets[7:0])&255];
  ref1<=cosine[(phase[31:24]+offsets[15:8])&255];
  ref2<=cosine[(phase[31:24]+offsets[23:16])&255];
  ref3<=cosine[(phase[31:24]+offsets[31:24])&255];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;phase<=0;step<=0;interval<=0;countdown<=0;target<=0;
   amp<=0;offsets<=0;time_pending<=0;time_output<=0;sample_pending<=0;
   m_valid<=0;m_samples<=0;error<=0;generated<=0;accepted<=0;dropped<=0;end
  else if(abort)begin state<=IDLE;m_valid<=0;sample_pending<=0;end
  else begin
   sample_pending<=sample_tick;
   if(m_valid&&m_ready)begin m_valid<=0;accepted<=accepted+1'b1;end
   if(sample_pending)begin
    if(!m_valid||m_ready)begin
     m_valid<=1;time_output<=time_pending;
     m_samples<={scaled(amp[63:48],ref3),scaled(amp[47:32],ref2),scaled(amp[31:16],ref1),scaled(amp[15:0],ref0)};
    end else begin error[1]<=1;dropped<=dropped+1'b1;end
   end
   case(state)
    IDLE:if(start)begin
     step<=tuning;interval<=period;countdown<=0;phase<=0;target<=13'd1<<log2_samples;
     amp<=amplitudes;offsets<=phase_offsets;generated<=0;accepted<=0;dropped<=0;error<=0;
     if(period<4||log2_samples<4||log2_samples>12||amplitudes[15:0]>32767||
        amplitudes[31:16]>32767||amplitudes[47:32]>32767||amplitudes[63:48]>32767)begin error<=1;state<=FINISH;end
     else state<=RUN;
    end
    RUN:if(sample_tick)begin
     phase<=phase+step;time_pending<=now;generated<=generated+1'b1;countdown<=interval-1'b1;
     if(generated==target-1)state<=DRAIN;
    end else countdown<=countdown-1'b1;
    DRAIN:if(!sample_pending&&!m_valid)state<=FINISH;
    FINISH:if(done_ready)state<=IDLE;
   endcase
  end
 end
endmodule
