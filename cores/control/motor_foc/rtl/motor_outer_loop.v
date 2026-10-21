// Serial current/speed/position command generation using canonical pid_core.
module motor_outer_loop #(parameter SPEED_LIMIT=32,CURRENT_LIMIT=256,POSITION_SHIFT=3,SPEED_KI_SHIFT=2)(
 input wire clk,rst_n,s_valid,output wire s_ready,
 input wire [1:0] mode,input wire restart,velocity_valid,
 input wire signed [31:0] position,velocity,target_position,
 input wire signed [15:0] target_speed,
 input wire signed [11:0] direct_d,direct_q,input wire [31:0] sample_id,
 output wire m_valid,input wire m_ready,
 output reg signed [11:0] reference_d,reference_q,
 output reg signed [15:0] speed_command,
 output reg [31:0] m_sample_id,output reg [7:0] error,
 output reg [3:0] clipped,output reg integrator_restarted
);
localparam IDLE=0,RESET_PI=1,ISSUE=2,WAIT_PI=3,RESULT=4;
reg [2:0] state;reg [1:0] last_mode;reg signed [15:0] loop_error;
reg signed [32:0] position_delta,desired_speed,error_wide;
reg signed [15:0] limited_speed,limited_error;reg [3:0] clip_next;
always @* begin
 position_delta=$signed({target_position[31],target_position})-$signed({position[31],position});
 desired_speed=mode==2?(position_delta>>>POSITION_SHIFT):$signed(target_speed);
 clip_next=0;
 if(desired_speed>SPEED_LIMIT)begin limited_speed=SPEED_LIMIT;clip_next[2]=1;end
 else if(desired_speed< -SPEED_LIMIT)begin limited_speed=-SPEED_LIMIT;clip_next[2]=1;end
 else limited_speed=desired_speed[15:0];
 error_wide=$signed(limited_speed)-$signed({velocity[31],velocity});
 if(error_wide>32767)begin limited_error=32767;clip_next[0]=1;end
 else if(error_wide< -32768)begin limited_error=-32768;clip_next[0]=1;end
 else limited_error=error_wide[15:0];
 if(mode==0&&(direct_q>CURRENT_LIMIT||direct_q< -CURRENT_LIMIT))clip_next[3]=1;
end
wire signed [15:0] pi_output;wire pi_valid;
wire pi_reset_n=rst_n&&state!=RESET_PI;
pid_core #(.KP_MUL(4),.KP_SH(0),.KI_MUL(1),.KI_SH(SPEED_KI_SHIFT),.KD_MUL(0),.KD_SH(0),.I_LIM(2047),.OUT_LIM(CURRENT_LIMIT))
 speed_pi(clk,state==ISSUE||state==WAIT_PI,pi_reset_n,state==ISSUE,loop_error,pi_output,pi_valid);
assign s_ready=rst_n&&state==IDLE;assign m_valid=rst_n&&state==RESULT;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;last_mode<=3;loop_error<=0;reference_d<=0;reference_q<=0;
  speed_command<=0;m_sample_id<=0;error<=0;clipped<=0;integrator_restarted<=0;end
 else case(state)
  IDLE:if(s_valid)begin
   reference_d<=direct_d;m_sample_id<=sample_id;error<=0;clipped<=clip_next;
   speed_command<=limited_speed;integrator_restarted<=0;
   if(mode==3)begin reference_q<=0;error<=1;state<=RESULT;end
   else if(mode!=0&&!velocity_valid)begin reference_q<=0;error<=2;state<=RESULT;end
   else begin
    last_mode<=mode;
    if(mode==0)begin
     reference_q<=direct_q>CURRENT_LIMIT?CURRENT_LIMIT:direct_q< -CURRENT_LIMIT?-CURRENT_LIMIT:direct_q;
     state<=RESULT;
    end else begin integrator_restarted<=restart||mode!=last_mode;loop_error<=limited_error;state<=(restart||mode!=last_mode)?RESET_PI:ISSUE;end
   end
  end
  RESET_PI:state<=ISSUE;
  ISSUE:state<=WAIT_PI;
  WAIT_PI:if(pi_valid)begin reference_q<=pi_output[11:0];state<=RESULT;end
  RESULT:if(m_ready)state<=IDLE;
  default:begin error<=8'h80;state<=RESULT;end
 endcase
end
initial if(SPEED_LIMIT<1||SPEED_LIMIT>32767||CURRENT_LIMIT<1||CURRENT_LIMIT>2047||POSITION_SHIFT<0||POSITION_SHIFT>31||SPEED_KI_SHIFT<0||SPEED_KI_SHIFT>15)
 $fatal(1,"outer loop parameter range");
endmodule
