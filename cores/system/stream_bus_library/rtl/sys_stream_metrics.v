// Passive ordered stream observer; fixed16 timestamp slots, explicit overflow.
module sys_stream_metrics(
 input wire clk,rst_n,start,stop,
 input wire in_valid,in_ready,out_valid,out_ready,
 output reg running,output reg [31:0] cycles,inputs,outputs,input_stalls,output_stalls,
 output reg [31:0] latency_min,latency_max,max_output_gap,errors
);
reg [31:0] stamps[0:15];
reg [3:0] wp,rp;
reg [4:0] pending;
reg [31:0] last_output;
reg seen_output;
wire push=in_valid&&in_ready,pop=out_valid&&out_ready;
wire [31:0] latency=cycles-stamps[rp];
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  running<=0; cycles<=0; inputs<=0; outputs<=0; input_stalls<=0; output_stalls<=0;
  latency_min<=32'hffffffff; latency_max<=0; max_output_gap<=0; errors<=0;
  wp<=0; rp<=0; pending<=0; last_output<=0; seen_output<=0;
 end else if(start) begin
  running<=1; cycles<=0; inputs<=0; outputs<=0; input_stalls<=0; output_stalls<=0;
  latency_min<=32'hffffffff; latency_max<=0; max_output_gap<=0; errors<=0;
  wp<=0; rp<=0; pending<=0; last_output<=0; seen_output<=0;
 end else if(running) begin
  cycles<=cycles+1;
  if(in_valid&&!in_ready) input_stalls<=input_stalls+1;
  if(out_valid&&!out_ready) output_stalls<=output_stalls+1;
  if(push) inputs<=inputs+1;
  if(pop) begin
   outputs<=outputs+1;
   if(seen_output&&cycles-last_output>max_output_gap) max_output_gap<=cycles-last_output;
   seen_output<=1; last_output<=cycles;
  end
  if(pop&&pending==0&&!push) errors<=errors+1;
  if(push&&pending==16&&!pop) errors<=errors+1;
  if(pending==0&&push&&pop) begin
   latency_min<=0;
  end else begin
   if(push&&(pending<16||pop)) begin stamps[wp]<=cycles; wp<=wp+1'b1; end
   if(pop&&pending!=0) begin
    rp<=rp+1'b1;
    if(latency<latency_min) latency_min<=latency;
    if(latency>latency_max) latency_max<=latency;
   end
   case({(push&&(pending<16||pop)),(pop&&pending!=0)})
    2'b10: pending<=pending+1'b1;
    2'b01: pending<=pending-1'b1;
   endcase
  end
  if(stop) running<=0;
 end
end
endmodule
