// Synchronous raw PWM, complementary gates with dead-time and latched fault.
// Direct fault_n gating is a digital reference, not certified power-stage safety.
module pwm3_protection(
 input wire clk,rst_n,enable,fault_n,clear_fault,
 input wire [2:0] raw_pwm,input wire [15:0] dead_ticks,
 output wire [2:0] high_gate,low_gate,
 output reg fault_latched,output reg config_error
);
reg [1:0] release_sync;
reg [2:0] high_state,low_state,target;
reg [15:0] remaining[0:2];
wire kill=!enable||fault_latched||config_error||dead_ticks==0;
assign high_gate=high_state&{3{rst_n&&fault_n&&!kill}};
assign low_gate=low_state&{3{rst_n&&fault_n&&!kill}};
wire protection_reset_n=rst_n&&fault_n;
always @(posedge clk or negedge protection_reset_n)begin
 if(!protection_reset_n)begin fault_latched<=1;release_sync<=0;end
 else begin
  release_sync<={release_sync[0],1'b1};
  if(clear_fault&&!enable&&(&release_sync))fault_latched<=0;
 end
end
integer g;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  config_error<=0;high_state<=0;low_state<=0;target<=0;
  for(g=0;g<3;g=g+1)remaining[g]<=0;
 end else begin
  if(dead_ticks==0)config_error<=1;
  else if(clear_fault&&!enable)config_error<=0;
  for(g=0;g<3;g=g+1)begin
   if(kill)begin
    high_state[g]<=0;low_state[g]<=0;target[g]<=!raw_pwm[g];remaining[g]<=0;
   end else if(raw_pwm[g]!=target[g])begin
    high_state[g]<=0;low_state[g]<=0;target[g]<=raw_pwm[g];remaining[g]<=dead_ticks-1'b1;
   end else if(remaining[g]!=0)begin
    high_state[g]<=0;low_state[g]<=0;remaining[g]<=remaining[g]-1'b1;
   end else begin high_state[g]<=target[g];low_state[g]<=!target[g];end
  end
 end
end
endmodule
