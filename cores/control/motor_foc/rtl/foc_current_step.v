// Serialized ownership of a complete phase-current -> applied PWM update.
module foc_current_step(
 input wire clk,rst_n,enable,fault_n,clear_fault,
 input wire s_valid,output wire s_ready,
 input wire signed [9:0] ia,ib,ic,input wire [7:0] theta,
 input wire signed [11:0] reference_d,reference_q,kp,ki,
 input wire [3:0] gain_shift,input wire restart,freeze_integral,
 input wire [15:0] period,dead_ticks,input wire [31:0] sample_id,
 output wire done_valid,input wire done_ready,
 output reg [7:0] error,output reg [31:0] result_id,
 output reg signed [11:0] measured_d,measured_q,voltage_d,voltage_q,
 output reg [15:0] duty_u,duty_v,duty_w,
 output wire [2:0] high_gate,low_gate,output wire fault_latched,
 output reg [39:0] diagnostics,
 output wire applied_update
);
localparam IDLE=0,TRANS_ISSUE=1,TRANS_WAIT=2,PI_ISSUE=3,PI_WAIT=4,
 MOD_ISSUE=5,MOD_WAIT=6,PWM_ISSUE=7,PWM_WAIT=8,DONE=9;
reg [3:0] state;reg flush,trip;
reg signed [9:0] ca,cb,cc;reg [7:0] angle;
reg signed [11:0] rd,rq,pk,ik;reg [3:0] shift;
reg reset_i,freeze_i;reg [15:0] carrier,dead;
wire core_rst_n=rst_n&&!flush;
assign s_ready=rst_n&&state==IDLE;
assign done_valid=rst_n&&state==DONE;
wire tr,tv,tsf,taf;wire signed [11:0] td,tq,ta,tb;
wire [11:0] tres;wire [3:0] tflags;wire [31:0] tid;
current_transform transform(clk,core_rst_n,state==TRANS_ISSUE,tr,ca,cb,cc,angle,8'd2,1'b1,result_id,
 tv,state==TRANS_WAIT,td,tq,ta,tb,tres,tflags,tsf,taf,tid);
wire pr,pv;wire signed [11:0] pd,pq,pi_d,pi_q;
wire [11:0] pf_d,pf_q;wire [1:0] p_fault,p_clip;wire [31:0] pid;
dq_current_pi regulator(clk,core_rst_n,state==PI_ISSUE,pr,rd,rq,measured_d,measured_q,
 pk,ik,shift,reset_i,freeze_i,result_id,pv,state==PI_WAIT,pd,pq,pi_d,pi_q,pf_d,pf_q,p_fault,p_clip,pid);
wire mr,mv;wire [15:0] mu,m_v,mw,mp;wire [1:0] m_error;wire [3:0] m_flags;wire [31:0] mid;
voltage_modulator modulator(clk,core_rst_n,state==MOD_ISSUE,mr,voltage_d,voltage_q,angle,carrier,result_id,
 mv,state==MOD_WAIT,mu,m_v,mw,mp,m_error,m_flags,mid);
wire pwm_ready,pwm_config,pwm_pending,pwm_applied;wire [31:0] pwm_id,rejected;
assign applied_update=pwm_applied;
wire [2:0] raw;wire [15:0] pwm_counter,ap,au,av,aw,ad;
pwm3_atomic pwm(clk,rst_n,enable,fault_n&&!trip,clear_fault,state==PWM_ISSUE,pwm_ready,
 carrier,duty_u,duty_v,duty_w,dead,result_id,raw,high_gate,low_gate,fault_latched,
 pwm_config,pwm_pending,pwm_applied,pwm_id,rejected,pwm_counter,ap,au,av,aw,ad);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;flush<=0;trip<=0;error<=0;result_id<=0;diagnostics<=0;
  ca<=0;cb<=0;cc<=0;angle<=0;rd<=0;rq<=0;pk<=0;ik<=0;shift<=0;reset_i<=0;freeze_i<=0;
  carrier<=0;dead<=0;measured_d<=0;measured_q<=0;voltage_d<=0;voltage_q<=0;duty_u<=0;duty_v<=0;duty_w<=0;
 end else begin
  flush<=0;
  if(clear_fault&&!enable)trip<=0;
  if(state!=IDLE&&state!=DONE&&enable&&(!fault_n||fault_latched))begin
   error<=8'h08;trip<=1;flush<=1;state<=DONE;
  end else case(state)
   IDLE:if(s_valid)begin
    result_id<=sample_id;error<=0;diagnostics<=0;
    if(period<4||dead_ticks==0||{1'b0,dead_ticks,1'b0}>={2'b0,period})begin
     error<=8'h01;trip<=1;flush<=1;state<=DONE;
    end else if(enable&&fault_latched)begin error<=8'h08;state<=DONE;end
    else begin
     ca<=ia;cb<=ib;cc<=ic;angle<=theta;rd<=reference_d;rq<=reference_q;pk<=kp;ik<=ki;
     shift<=gain_shift;reset_i<=restart;freeze_i<=freeze_integral;carrier<=period;dead<=dead_ticks;state<=TRANS_ISSUE;
    end
   end
   TRANS_ISSUE:if(tr)state<=TRANS_WAIT;
   TRANS_WAIT:if(tv)begin
    measured_d<=td;measured_q<=tq;diagnostics[29:26]<=tflags;
    if(tsf||taf||tid!=result_id)begin error<=8'h02;trip<=1;flush<=1;state<=DONE;end
    else state<=PI_ISSUE;
   end
   PI_ISSUE:if(pr)state<=PI_WAIT;
   PI_WAIT:if(pv)begin
    voltage_d<=pd;voltage_q<=pq;diagnostics[11:0]<=pf_d;diagnostics[23:12]<=pf_q;
    diagnostics[25:24]<=p_clip;diagnostics[35:34]<=p_fault;
    if(pid!=result_id||p_clip!=0)begin error<=8'h04;trip<=1;flush<=1;state<=DONE;end
    else state<=MOD_ISSUE;
   end
   MOD_ISSUE:if(mr)state<=MOD_WAIT;
   MOD_WAIT:if(mv)begin
    duty_u<=mu;duty_v<=m_v;duty_w<=mw;diagnostics[33:30]<=m_flags;
    if(m_error[0]||mid!=result_id||mp!=carrier)begin error<=8'h01;trip<=1;flush<=1;state<=DONE;end
    else state<=PWM_ISSUE;
   end
   PWM_ISSUE:if(pwm_ready)state<=PWM_WAIT;
   PWM_WAIT:if(pwm_applied&&pwm_id==result_id)begin error<=m_error[1]?8'h10:8'd0;state<=DONE;end
   DONE:if(done_ready)state<=IDLE;
   default:begin error<=8'h80;trip<=1;flush<=1;state<=DONE;end
  endcase
 end
end
endmodule
