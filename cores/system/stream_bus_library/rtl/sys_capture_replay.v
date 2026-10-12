// Host-loadable synchronous stimulus RAM and raw response RAM, full clock rate.
module sys_capture_replay #(parameter DEPTH=256,IN_WIDTH=96,OUT_WIDTH=192,TIMEOUT=1000000)(
 input wire clk,rst_n,
 input wire host_write,input wire [$clog2(DEPTH)-1:0] host_address,
 input wire [IN_WIDTH-1:0] host_data,
 input wire start,input wire [15:0] input_length,output_length,
 output wire [IN_WIDTH-1:0] s_data,output reg s_valid,input wire s_ready,
 input wire [OUT_WIDTH-1:0] m_data,input wire m_valid,output wire m_ready,
 input wire host_read,input wire [$clog2(DEPTH)-1:0] read_address,
 output reg [OUT_WIDTH-1:0] read_data,
 output reg active,done,error,output reg [15:0] issued,captured,
 output reg [31:0] cycles
);
localparam AW=$clog2(DEPTH);
(* ram_style="block" *) reg [IN_WIDTH-1:0] stimulus[0:DEPTH-1];
(* ram_style="block" *) reg [OUT_WIDTH-1:0] responses[0:DEPTH-1];
reg [IN_WIDTH-1:0] stimulus_data;
reg [15:0] fetched,n_inputs,n_outputs;
wire fetch=active&&(fetched<n_inputs)&&(!s_valid||s_ready);
wire request=s_valid&&s_ready,response=m_valid&&m_ready;
assign s_data=stimulus_data;
assign m_ready=active&&(captured<n_outputs);
always @(posedge clk) begin
 if(host_write&&!active) stimulus[host_address]<=host_data;
 if(fetch) stimulus_data<=stimulus[fetched[AW-1:0]];
 if(response) responses[captured[AW-1:0]]<=m_data;
 if(host_read&&!active) read_data<=responses[read_address];
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin fetched<=0; n_inputs<=0; n_outputs<=0; s_valid<=0; active<=0; done<=0; error<=0; issued<=0; captured<=0; cycles<=0; end
 else begin
  if(start&&!active) begin
   done<=0; error<=0; issued<=0; captured<=0; fetched<=0; cycles<=0; s_valid<=0;
   n_inputs<=input_length; n_outputs<=output_length;
   if(input_length==0||input_length>DEPTH||output_length==0||output_length>DEPTH) begin done<=1; error<=1; end
   else active<=1;
  end
  if(active) begin
   cycles<=cycles+1;
   if(fetch) begin fetched<=fetched+1'b1; s_valid<=1; end
   else if(request) s_valid<=0;
   if(request) issued<=issued+1'b1;
   if(response) captured<=captured+1'b1;
   if((issued+{15'd0,request}==n_inputs)&&(captured+{15'd0,response}==n_outputs)) begin active<=0; done<=1; s_valid<=0; end
   else if(TIMEOUT!=0&&cycles>=TIMEOUT-1) begin active<=0; done<=1; error<=1; s_valid<=0; end
  end
 end
end
initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0||DEPTH>32768||IN_WIDTH<1||OUT_WIDTH<1) $fatal(1,"invalid replay parameters");
endmodule
