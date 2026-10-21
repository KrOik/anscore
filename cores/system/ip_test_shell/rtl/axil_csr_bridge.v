// 32-bit AXI-Lite slave to a single-request CSR endpoint, 256-byte aperture.
// AW/W/AR each have an independent holding slot. Read/write dispatch is fair.
module axil_csr_bridge(
 input wire clk,rst_n,
 input wire [7:0] s_awaddr,input wire s_awvalid,output wire s_awready,
 input wire [31:0] s_wdata,input wire [3:0] s_wstrb,
 input wire s_wvalid,output wire s_wready,
 output reg [1:0] s_bresp,output reg s_bvalid,input wire s_bready,
 input wire [7:0] s_araddr,input wire s_arvalid,output wire s_arready,
 output reg [31:0] s_rdata,output reg [1:0] s_rresp,
 output reg s_rvalid,input wire s_rready,
 output wire req_valid,req_write,output wire [7:0] req_addr,
 output wire [31:0] req_data,output wire [3:0] req_strobe,input wire req_ready,
 input wire resp_valid,input wire [31:0] resp_data,input wire resp_error,
 output wire resp_ready
);
 reg aw_have,w_have,ar_have,inflight,was_write,prefer_write;
 reg selection_locked,locked_write;
 reg [7:0] awaddr,araddr;
 reg [31:0] wdata;
 reg [3:0] wstrb;
 wire write_available=aw_have&&w_have&&!s_bvalid;
 wire read_available=ar_have&&!s_rvalid;
 assign s_awready=rst_n&&!aw_have;
 assign s_wready=rst_n&&!w_have;
 assign s_arready=rst_n&&!ar_have;
 assign req_write=selection_locked?locked_write:(write_available&&(!read_available||prefer_write));
 assign req_valid=rst_n&&!inflight&&(write_available||read_available);
 assign req_addr=req_write?awaddr:araddr;
 assign req_data=req_write?wdata:32'd0;
 assign req_strobe=req_write?wstrb:4'd0;
 assign resp_ready=rst_n&&inflight&&(was_write?!s_bvalid:!s_rvalid);
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   aw_have<=0; w_have<=0; ar_have<=0; inflight<=0; was_write<=0; prefer_write<=1;
   selection_locked<=0; locked_write<=0;
   awaddr<=0; araddr<=0; wdata<=0; wstrb<=0;
   s_bvalid<=0; s_bresp<=0; s_rvalid<=0; s_rresp<=0; s_rdata<=0;
  end else begin
   if(s_bvalid&&s_bready) s_bvalid<=0;
   if(s_rvalid&&s_rready) s_rvalid<=0;
   if(s_awvalid&&s_awready) begin aw_have<=1; awaddr<=s_awaddr; end
   if(s_wvalid&&s_wready) begin w_have<=1; wdata<=s_wdata; wstrb<=s_wstrb; end
   if(s_arvalid&&s_arready) begin ar_have<=1; araddr<=s_araddr; end
   if(req_valid&&req_ready) begin
    selection_locked<=0;
    inflight<=1; was_write<=req_write; prefer_write<=!req_write;
    if(req_write) begin aw_have<=0; w_have<=0; end else ar_have<=0;
   end
   else if(req_valid&&!req_ready&&!selection_locked) begin
    selection_locked<=1; locked_write<=req_write;
   end
   if(resp_valid&&resp_ready) begin
    inflight<=0;
    if(was_write) begin s_bvalid<=1; s_bresp<=resp_error?2'b10:2'b00; end
    else begin s_rvalid<=1; s_rdata<=resp_data; s_rresp<=resp_error?2'b10:2'b00; end
   end
  end
 end
endmodule
