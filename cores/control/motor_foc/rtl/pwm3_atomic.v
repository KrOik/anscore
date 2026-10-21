// One queued complete carrier command; applies only idle or carrier boundary.
module pwm3_atomic(
 input wire clk,rst_n,enable,fault_n,clear_fault,
 input wire s_valid,output wire s_ready,
 input wire [15:0] s_period,s_u,s_v,s_w,s_dead,
 input wire [31:0] s_id,
 output wire [2:0] raw_pwm,high_gate,low_gate,
 output wire fault_latched,output reg config_fault,
 output reg pending,output reg applied,output reg [31:0] applied_id,rejected,
 output reg [15:0] counter,active_period,active_u,active_v,active_w,active_dead
);
reg configured;
reg [15:0] saved_period,saved_u,saved_v,saved_w,saved_dead;
reg [31:0] saved_id;
assign s_ready=rst_n&&!pending;
wire take=s_valid&&s_ready;
wire invalid=s_period<4||s_dead==0||{1'b0,s_dead,1'b0}>={2'b0,s_period}||s_u>s_period||s_v>s_period||s_w>s_period;
wire safe=!enable||!configured||counter==active_period-1'b1;
wire apply_now=safe&&(pending||(take&&!invalid));
assign raw_pwm={3{configured&&enable}}&{counter<active_w,counter<active_v,counter<active_u};
wire protection_config_error;
pwm3_protection protection(clk,rst_n,enable&&configured,fault_n&&!config_fault,
 clear_fault,raw_pwm,active_dead,high_gate,low_gate,fault_latched,protection_config_error);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  configured<=0;pending<=0;applied<=0;applied_id<=0;rejected<=0;config_fault<=0;
  counter<=0;active_period<=4;active_u<=0;active_v<=0;active_w<=0;active_dead<=1;
  saved_period<=0;saved_u<=0;saved_v<=0;saved_w<=0;saved_dead<=0;saved_id<=0;
 end else begin
  applied<=0;
  if(!enable||!configured||counter==active_period-1'b1)counter<=0;else counter<=counter+1'b1;
  if(take&&invalid)begin rejected<=rejected+1;config_fault<=1;end
  else if(clear_fault&&!enable&&configured)config_fault<=0;
  if(take&&!invalid&&!safe)begin
   pending<=1;saved_period<=s_period;saved_u<=s_u;saved_v<=s_v;
   saved_w<=s_w;saved_dead<=s_dead;saved_id<=s_id;
  end
  if(apply_now)begin
   configured<=1;pending<=0;applied<=1;counter<=0;
   active_period<=pending?saved_period:s_period;
   active_u<=pending?saved_u:s_u;active_v<=pending?saved_v:s_v;
   active_w<=pending?saved_w:s_w;active_dead<=pending?saved_dead:s_dead;
   applied_id<=pending?saved_id:s_id;
  end
 end
end
endmodule
