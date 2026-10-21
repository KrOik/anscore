// Finite fixed-cadence owner for an already initialized motor_controller.
// A preloaded descriptor store supplies s_data; results must be durably buffered
// upstream of m_ready. This module never clears protection automatically.
module motor_replay_owner #(parameter WIDTH=480)(
 input wire clk,rst_n,start,abort_run,armed,
 input wire [31:0] sample_count,interval_clocks,
 output wire start_ready,
 input wire s_valid,input wire [WIDTH-1:0] s_data,output wire s_ready,
 output wire core_valid,input wire core_ready,output wire [WIDTH-1:0] core_data,
 input wire core_done,input wire [7:0] core_error,input wire core_safe,
 output wire core_done_ready,core_enable,
 output wire m_valid,input wire m_ready,
 output wire done_valid,input wire done_ready,
 output reg [7:0] error,
 output reg [31:0] issued,completed,missed_deadlines,starvations,
 output reg [63:0] elapsed
);
localparam IDLE=0,RUN=1,DRAIN=2,DONE=3;
reg [1:0] state;reg outstanding;reg [31:0] count,interval,phase;
wire due=phase==0&&issued<count;
wire allowed=state==RUN&&!abort_run&&armed&&core_safe;
assign core_enable=allowed;
assign start_ready=rst_n&&state==IDLE&&!outstanding;
assign core_data=s_data;
assign s_ready=rst_n&&allowed&&due&&!outstanding&&core_ready;
assign core_valid=s_valid&&s_ready;
assign m_valid=rst_n&&outstanding&&core_done;
assign core_done_ready=m_valid&&m_ready;
assign done_valid=rst_n&&state==DONE;
wire issue=core_valid&&core_ready;
wire finish=core_done_ready;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;outstanding<=0;count<=0;interval<=0;phase<=0;
  error<=0;issued<=0;completed<=0;missed_deadlines<=0;starvations<=0;elapsed<=0;end
 else begin
  if(issue)begin outstanding<=1;issued<=issued+1;end
  if(finish)begin outstanding<=0;completed<=completed+1;end
  case(state)
   IDLE:if(start)begin
    error<=0;issued<=0;completed<=0;missed_deadlines<=0;starvations<=0;elapsed<=0;
    if(!armed||!core_safe||!core_ready||sample_count==0||interval_clocks<4)begin error<=1;state<=DONE;end
    else begin count<=sample_count;interval<=interval_clocks;phase<=0;state<=RUN;end
   end
   RUN:begin
    elapsed<=elapsed+1;
    if(phase==0)phase<=interval-1;else phase<=phase-1;
    if(abort_run)begin error<=5;state<=DRAIN;end
    else if(!armed||!core_safe)begin error<=4;state<=DRAIN;end
    else if(core_done&&outstanding&&(core_error&8'hef)!=0)begin error<=6;state<=DRAIN;end
    else if(due)begin
     if(outstanding||!core_ready)begin error<=3;missed_deadlines<=missed_deadlines+1;state<=DRAIN;end
     else if(!s_valid)begin error<=2;starvations<=starvations+1;state<=DRAIN;end
    end
    if(finish&&completed+1==count)begin
     // Preserve a terminal error if the final result itself failed.
     if((core_error&8'hef)!=0)error<=6;
     if(abort_run)error<=5;
     else if(!armed||!core_safe)error<=4;
     state<=DONE;
    end
   end
   DRAIN:if(!outstanding||finish)state<=DONE;
   DONE:if(done_ready)state<=IDLE;
  endcase
 end
end
initial if(WIDTH<1)$fatal(1,"descriptor width");
endmodule
