// One outstanding sample, coherent QEI snapshot, outer loop and applied FOC.
// Electrical theta is supplied by the caller; no implicit encoder/pole mapping.
module motor_controller #(parameter [7:0] WMIN=0,WMAX=64,parameter SPEED_KI_SHIFT=6)(
 input wire clk,rst_n,enable,external_fault_n,clear_fault,monitor_tick,
 input wire qa,qb,qindex,index_reset,
 input wire s_valid,output wire s_ready,
 input wire [1:0] mode,input wire restart,freeze_integral,
 input wire signed [9:0] ia,ib,ic,input wire [7:0] theta,
 input wire signed [31:0] target_position,input wire signed [15:0] target_speed,
 input wire signed [11:0] direct_d,direct_q,kp,ki,
 input wire [3:0] gain_shift,input wire [15:0] period,dead_ticks,
 input wire [31:0] sample_id,
 output wire m_valid,input wire m_ready,
 output reg [31:0] result_id,output reg [7:0] error,
 output wire signed [31:0] position,velocity,
 output wire signed [11:0] measured_d,measured_q,voltage_d,voltage_q,
 output wire [15:0] duty_u,duty_v,duty_w,
 output wire [2:0] high_gate,low_gate,
 output wire drive_fault_n,pwm_fault,output wire [7:0] first_cause,
 output wire [63:0] first_time,output wire [31:0] fault_count,
 output wire applied_update
);
localparam IDLE=0,SNAPSHOT=1,OUT_ISSUE=2,OUT_WAIT=3,FOC_ISSUE=4,FOC_WAIT=5,RESULT=6;
reg [2:0] state;reg [1:0] cmode;reg cr,cf;
reg signed [9:0] ca,cb,cc;reg [7:0] angle;
reg signed [31:0] target;reg signed [15:0] speed;
reg signed [11:0] dd,dq,pk,ik;reg [3:0] shift;
reg [15:0] carrier,dead;reg control_fault;
wire accepted=s_valid&&s_ready;
wire clear_allowed=clear_fault&&!enable;
assign s_ready=rst_n&&state==IDLE;
assign m_valid=rst_n&&state==RESULT;
wire snap,vvalid,enc_error;wire [31:0] count,idx,seq,invalid;
wire direction,step,idx_event;wire [63:0] snap_time;
encoder_feedback feedback(clk,rst_n,qa,qb,qindex,index_reset,accepted,clear_allowed,
 count,idx,direction,step,idx_event,snap,vvalid,position,velocity,snap_time,seq,enc_error,invalid);
wire outer_ready,outer_valid,outer_restart;wire signed [11:0] rd,rq;
wire signed [15:0] speed_cmd;wire [31:0] outer_id;wire [7:0] outer_error;wire [3:0] clipped;
motor_outer_loop #(.SPEED_KI_SHIFT(SPEED_KI_SHIFT)) outer(clk,rst_n,state==OUT_ISSUE,outer_ready,cmode,cr,vvalid,
 position,velocity,target,speed,dd,dq,result_id,outer_valid,state==OUT_WAIT,
 rd,rq,speed_cmd,outer_id,outer_error,clipped,outer_restart);
wire foc_ready,foc_done;wire [7:0] foc_error;wire [31:0] foc_id;wire [39:0] diagnostics;
foc_current_step current_loop(clk,rst_n,enable,drive_fault_n,clear_fault,
 state==FOC_ISSUE,foc_ready,ca,cb,cc,angle,rd,rq,pk,ik,shift,cr,cf,carrier,dead,result_id,
 foc_done,state==FOC_WAIT,foc_error,foc_id,measured_d,measured_q,voltage_d,voltage_q,
 duty_u,duty_v,duty_w,high_gate,low_gate,pwm_fault,diagnostics,applied_update);
wire safety_latched;wire [7:0] good,early,late,timeout_count;
motor_safety #(.WMIN(WMIN),.WMAX(WMAX)) safety(clk,rst_n,enable,external_fault_n,
 enc_error,control_fault,monitor_tick,applied_update,clear_fault,drive_fault_n,
 safety_latched,first_cause,first_time,fault_count,good,early,late,timeout_count);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;result_id<=0;error<=0;control_fault<=0;
  cmode<=0;cr<=0;cf<=0;ca<=0;cb<=0;cc<=0;angle<=0;target<=0;speed<=0;
  dd<=0;dq<=0;pk<=0;ik<=0;shift<=0;carrier<=0;dead<=0;
 end else begin
  if(clear_allowed)control_fault<=0;
  case(state)
   IDLE:if(accepted)begin
    result_id<=sample_id;error<=0;cmode<=mode;cr<=restart;cf<=freeze_integral;
    ca<=ia;cb<=ib;cc<=ic;angle<=theta;target<=target_position;speed<=target_speed;
    dd<=direct_d;dq<=direct_q;pk<=kp;ik<=ki;shift<=gain_shift;carrier<=period;dead<=dead_ticks;
    state<=SNAPSHOT;
   end
   SNAPSHOT:if(snap)state<=OUT_ISSUE;
   OUT_ISSUE:if(outer_ready)state<=OUT_WAIT;
   OUT_WAIT:if(outer_valid)begin
    if(outer_error!=0||outer_id!=result_id)begin
     error<=8'h20;control_fault<=1;state<=RESULT;
    end else state<=FOC_ISSUE;
   end
   FOC_ISSUE:if(foc_ready)state<=FOC_WAIT;
   FOC_WAIT:if(foc_done)begin
    error<=foc_id!=result_id?8'h40:foc_error;
    if(foc_id!=result_id||(foc_error&8'hef)!=0)control_fault<=1;
    state<=RESULT;
   end
   RESULT:if(m_ready)state<=IDLE;
   default:begin error<=8'h80;control_fault<=1;state<=RESULT;end
  endcase
 end
end
endmodule
