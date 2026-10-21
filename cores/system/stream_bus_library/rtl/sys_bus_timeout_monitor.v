// Passive, single-outstanding monitor. Timeout never fabricates completion.
module sys_bus_timeout_monitor(
 input wire clk,rst_n,clear,input wire req_valid,req_ready,rsp_valid,rsp_ready,
 input wire [15:0] limit_cycles,
 output reg outstanding,timed_out,timeout_pulse,
 output reg [15:0] age,max_age,output reg [31:0] timeouts,overlaps,late_responses
);
wire request=req_valid&&req_ready,response=rsp_valid&&rsp_ready;
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin outstanding<=0; timed_out<=0; timeout_pulse<=0; age<=0; max_age<=0; timeouts<=0; overlaps<=0; late_responses<=0; end
 else begin
  timeout_pulse<=0;
  if(clear) begin timeouts<=0; overlaps<=0; late_responses<=0; max_age<=0; end
  if(outstanding&&!response) begin
   if(age!=65535) age<=age+1'b1;
   if(age!=65535&&age+1'b1>max_age) max_age<=age+1'b1;
   if(!timed_out&&limit_cycles!=0&&age>=limit_cycles-1'b1) begin
    timed_out<=1; timeout_pulse<=1; timeouts<=timeouts+1;
   end
  end
  if(response&&outstanding) begin
   outstanding<=0; age<=0;
   if(timed_out) late_responses<=late_responses+1;
   timed_out<=0;
  end
  if(request) begin
   if(outstanding&&!response) overlaps<=overlaps+1;
   else begin outstanding<=!response||outstanding; timed_out<=0; age<=0; end
  end
 end
end
endmodule
