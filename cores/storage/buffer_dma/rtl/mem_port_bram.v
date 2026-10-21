// Single-clock word transaction port. Byte addresses are checked, never truncated.
module mem_port_bram #(parameter DEPTH=256)(
 input wire clk,rst_n,req_valid,req_write,input wire [31:0] req_addr,req_data,
 input wire [3:0] req_strobe,output wire req_ready,
 output reg resp_valid,output wire [31:0] resp_data,output reg resp_error,
 input wire resp_ready,output reg [31:0] reads,writes,errors
);
 localparam AW=$clog2(DEPTH);
 (* ram_style="block" *) reg [31:0] mem[0:DEPTH-1];
 reg [31:0] read_data;
 reg response_is_read;
 wire bad=req_addr[1:0]!=0||(req_addr>>2)>=DEPTH;
 wire take=req_valid&&req_ready;
 assign req_ready=rst_n&&(!resp_valid||resp_ready);
 assign resp_data=response_is_read?read_data:32'd0;
 integer b;
 always @(posedge clk)begin
  if(take&&!bad)begin
   if(req_write)begin
    for(b=0;b<4;b=b+1)if(req_strobe[b])mem[req_addr[AW+1:2]][8*b+:8]<=req_data[8*b+:8];
   end else read_data<=mem[req_addr[AW+1:2]];
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin resp_valid<=0;resp_error<=0;response_is_read<=0;reads<=0;writes<=0;errors<=0;end
  else begin
   if(resp_valid&&resp_ready)resp_valid<=0;
   if(take)begin
    resp_valid<=1;resp_error<=bad;response_is_read<=!req_write&&!bad;
    if(bad)errors<=errors+1'b1;
    else if(req_write)writes<=writes+1'b1;
    else reads<=reads+1'b1;
   end
  end
 end
 initial if(DEPTH<2||(DEPTH&(DEPTH-1))!=0||DEPTH>1048576)$fatal(1,"invalid BRAM depth");
endmodule
