// Synchronized canonical x4 QEI plus coherent position/velocity sampling.
module encoder_feedback(
 input wire clk,rst_n,qa,qb,qindex,index_reset,sample_tick,clear_errors,
 output wire [31:0] encoder_count,index_latch,
 output wire direction,step_event,index_event,
 output reg snapshot_valid,velocity_valid,
 output reg signed [31:0] position,velocity,
 output reg [63:0] snapshot_time,output reg [31:0] snapshot_sequence,
 output reg encoder_error,output reg [31:0] invalid_transitions
);
(* async_reg="true" *) reg [2:0] sync0,sync1;
reg [1:0] previous_ab;reg index_reset_delay;
reg [31:0] baseline;reg have_baseline;reg [63:0] timestamp;
wire illegal=(sync1[1:0]^previous_ab)==2'b11;
wire rebasing=index_event&&index_reset_delay;
qei_dec decoder(clk,1'b1,rst_n,sync1[1],sync1[0],sync1[2],index_reset,
 encoder_count,direction,step_event,index_latch,index_event);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  sync0<=0;sync1<=0;previous_ab<=0;index_reset_delay<=0;baseline<=0;have_baseline<=0;
  timestamp<=0;snapshot_valid<=0;velocity_valid<=0;position<=0;velocity<=0;
  snapshot_time<=0;snapshot_sequence<=0;encoder_error<=0;invalid_transitions<=0;
 end else begin
  sync0<={qindex,qa,qb};sync1<=sync0;previous_ab<=sync1[1:0];index_reset_delay<=index_reset;
  timestamp<=timestamp+1;snapshot_valid<=sample_tick;
  if(clear_errors)begin encoder_error<=0;invalid_transitions<=0;end
  if(illegal)begin encoder_error<=1;invalid_transitions<=clear_errors?1:invalid_transitions+1;end
  if(rebasing)begin baseline<=encoder_count;have_baseline<=0;end
  if(sample_tick)begin
   position<=encoder_count;snapshot_time<=timestamp;snapshot_sequence<=snapshot_sequence+1;
   velocity_valid<=have_baseline&&!rebasing;
   velocity<=(have_baseline&&!rebasing)?encoder_count-baseline:32'd0;
   baseline<=encoder_count;have_baseline<=!rebasing;
  end
 end
end
endmodule
