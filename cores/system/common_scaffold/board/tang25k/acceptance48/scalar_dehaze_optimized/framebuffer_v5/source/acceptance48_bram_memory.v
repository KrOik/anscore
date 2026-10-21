// Persistent 4KiB RAM, four byte banks with independent write enables.
module acceptance48_bram_memory(input wire clk,rst_n,ce,
 input wire req_valid,req_write,input wire [31:0] req_addr,req_wdata,input wire [3:0] req_wstrb,
 output wire req_ready,output reg rsp_valid,output wire [31:0] rsp_rdata,output reg rsp_error,input wire rsp_ready);
(* ram_style="block" *) reg [7:0] bank0[0:1023],bank1[0:1023],bank2[0:1023],bank3[0:1023];
reg [31:0] read_data;
reg have_data;
wire good=req_addr[31:12]==0 && req_addr[1:0]==0 && req_addr!=4092;
wire fire=ce && req_valid && req_ready;
assign req_ready=rst_n && !rsp_valid;
assign rsp_rdata=have_data && !rsp_error ? read_data:32'd0;
always @(posedge clk)begin
 if(fire && good)begin
  read_data<={bank3[req_addr[11:2]],bank2[req_addr[11:2]],bank1[req_addr[11:2]],bank0[req_addr[11:2]]};
  if(req_write)begin
   if(req_wstrb[0])bank0[req_addr[11:2]]<=req_wdata[7:0];
   if(req_wstrb[1])bank1[req_addr[11:2]]<=req_wdata[15:8];
   if(req_wstrb[2])bank2[req_addr[11:2]]<=req_wdata[23:16];
   if(req_wstrb[3])bank3[req_addr[11:2]]<=req_wdata[31:24];
  end
 end
 if(!rst_n)begin rsp_valid<=0;rsp_error<=0;have_data<=0;end
 else if(ce)begin
  if(rsp_valid && rsp_ready)rsp_valid<=0;
  if(req_valid && req_ready)begin rsp_valid<=1;rsp_error<=!good;have_data<=good;end
 end
end
endmodule
