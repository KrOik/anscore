// First-fault ownership around canonical window watchdog and encoder diagnostics.
module motor_safety #(parameter [7:0] WMIN=0,WMAX=64)(
 input wire clk,rst_n,enable,external_fault_n,encoder_error,control_error,
 input wire monitor_tick,control_applied,clear_fault,
 output wire drive_fault_n,output reg fault_latched,
 output reg [7:0] first_cause,output reg [63:0] first_time,
 output reg [31:0] fault_count,
 output wire [7:0] watchdog_good,watchdog_early,watchdog_late,watchdog_timeout
);
reg heartbeat_pending,clear_pending,external_latched;
reg [63:0] timestamp;wire wd_reset,ev_good,ev_early,ev_late,ev_timeout;
wire clear_allowed=clear_fault&&!enable;
wire kick=heartbeat_pending||control_applied;
wire wd_clear=clear_pending||clear_allowed;
wdt_win #(.WMIN(WMIN),.WMAX(WMAX)) watchdog(clk,monitor_tick,rst_n,enable,kick,wd_clear,
 wd_reset,ev_good,ev_early,ev_late,ev_timeout,watchdog_good,watchdog_early,watchdog_late,watchdog_timeout);
// A disabled pulse clear can precede the watchdog clock-enable beat.
// Ignore stale watchdog causes until that beat; live faults still win.
// The raw watchdog state continues to inhibit the physical gates meanwhile.
wire clearing_watchdog=clear_pending&&!enable;
wire [7:0] cause=external_latched||!external_fault_n?8'd1:encoder_error?8'd2:
 wd_reset&&!clearing_watchdog?8'd3:(ev_early||ev_late)&&!clearing_watchdog?8'd4:control_error?8'd5:8'd0;
assign drive_fault_n=rst_n&&external_fault_n&&!external_latched&&!fault_latched&&
 !encoder_error&&!control_error&&!wd_reset&&!ev_early&&!ev_late;
// One asynchronous set pin; system reset clears this capture synchronously.
// Raw external fault always wins and also directly gates drive_fault_n.
always @(posedge clk or negedge external_fault_n)begin
 if(!external_fault_n)external_latched<=1;
 else if(!rst_n||clear_allowed)external_latched<=0;
end
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin heartbeat_pending<=0;clear_pending<=0;timestamp<=0;
  fault_latched<=0;first_cause<=0;first_time<=0;fault_count<=0;end
 else begin
  timestamp<=timestamp+1;
  if(!enable||monitor_tick)heartbeat_pending<=0;else if(control_applied)heartbeat_pending<=1;
  if(monitor_tick)clear_pending<=0;else if(clear_allowed)clear_pending<=1;
  if(clear_allowed&&external_fault_n&&!encoder_error&&!control_error)begin
   fault_latched<=0;first_cause<=0;first_time<=0;
  end else if(cause!=0&&!fault_latched)begin
   fault_latched<=1;first_cause<=cause;first_time<=timestamp;fault_count<=fault_count+1;
  end
 end
end
initial if(WMIN>WMAX)$fatal(1,"watchdog window range");
endmodule
