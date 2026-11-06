// Exact nearest-step binary-turn phase unwrap, with modular accumulator and sticky overflow.
module stream_phase_unwrap #(
 parameter integer PHASE_W=24, ACC_W=40, TAG_W=16
)(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [PHASE_W-1:0] s_phase,input wire s_restart,s_last,
 input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg signed [ACC_W-1:0] m_phase,
 output reg signed [PHASE_W-1:0] m_delta,
 output reg m_first,m_overflow,m_last,output reg [TAG_W-1:0] m_tag
);
 reg occupied,have_previous,overflow_sticky;
 reg [PHASE_W-1:0] previous;
 reg signed [ACC_W-1:0] accumulator;
 wire first_sample=s_restart || !have_previous;
 wire signed [PHASE_W-1:0] delta_bits=s_phase-previous;
 wire signed [ACC_W-1:0] delta_extended={{(ACC_W-PHASE_W){delta_bits[PHASE_W-1]}},delta_bits};
 wire signed [ACC_W-1:0] initial_phase={{(ACC_W-PHASE_W){s_phase[PHASE_W-1]}},s_phase};
 wire signed [ACC_W-1:0] sum=accumulator+delta_extended;
 wire sum_overflow=(accumulator[ACC_W-1]==delta_extended[ACC_W-1]) && (sum[ACC_W-1]!=accumulator[ACC_W-1]);
 wire signed [ACC_W-1:0] accepted_phase=first_sample ? initial_phase : sum;
 wire accepted_overflow=first_sample ? 1'b0 : overflow_sticky || sum_overflow;
 assign s_ready=!rst && (!occupied || m_ready);
 assign m_valid=!rst && occupied;
 always @(posedge clk)begin
  if(rst)begin
   occupied<=0;have_previous<=0;overflow_sticky<=0;
   previous<=0;accumulator<=0;
  end else if(s_ready)begin
   occupied<=s_valid;
   if(s_valid)begin
    have_previous<=1;previous<=s_phase;accumulator<=accepted_phase;overflow_sticky<=accepted_overflow;
    m_phase<=accepted_phase;m_delta<=first_sample ? {PHASE_W{1'b0}} : delta_bits;
    m_first<=first_sample;m_overflow<=accepted_overflow;m_last<=s_last;m_tag<=s_tag;
   end
  end
 end
endmodule
