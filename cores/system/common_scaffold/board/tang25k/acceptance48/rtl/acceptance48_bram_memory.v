// Real persistent synchronous 4KiB byte-enable RAM for framebuffer acceptance.
// One outstanding response, CE handshake and response holding. Last word is a
// deliberate bus-error address, permitting real DUT memory-error recovery tests.
module acceptance48_bram_memory(input wire clk,rst_n,ce,
 input wire req_valid,req_write,input wire [31:0] req_addr,req_wdata,input wire [3:0] req_wstrb,
 output wire req_ready,output reg rsp_valid,output reg [31:0] rsp_rdata,output reg rsp_error,input wire rsp_ready);
reg [31:0] memory[0:1023];integer lane;
assign req_ready=rst_n && !rsp_valid;
always @(posedge clk)begin
 if(!rst_n)begin rsp_valid<=0;rsp_rdata<=0;rsp_error<=0;end
 else if(ce)begin
  if(rsp_valid && rsp_ready)rsp_valid<=0;
  if(req_valid && req_ready)begin
   rsp_valid<=1;rsp_error<=req_addr[31:12]!=0 || req_addr[1:0]!=0 || req_addr==4092;
   if(req_addr[31:12]==0 && req_addr[1:0]==0 && req_addr!=4092)begin
    rsp_rdata<=memory[req_addr[11:2]];
    if(req_write)for(lane=0;lane<4;lane=lane+1)if(req_wstrb[lane])memory[req_addr[11:2]][lane*8+:8]<=req_wdata[lane*8+:8];
   end else rsp_rdata<=0;
  end
 end
end
endmodule
