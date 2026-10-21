// One AXI-Lite master / four slaves, independent read and write channels.
// 0x0000..0x3fff windows of4K; other addresses respond DECERR without dispatch.
module sys_axi_lite_interconnect(
 input wire clk,rst_n,
 input wire [15:0] s_awaddr,input wire [2:0] s_awprot,input wire s_awvalid,output wire s_awready,
 input wire [31:0] s_wdata,input wire [3:0] s_wstrb,input wire s_wvalid,output wire s_wready,
 output reg [1:0] s_bresp,output reg s_bvalid,input wire s_bready,
 input wire [15:0] s_araddr,input wire [2:0] s_arprot,input wire s_arvalid,output wire s_arready,
 output reg [31:0] s_rdata,output reg [1:0] s_rresp,output reg s_rvalid,input wire s_rready,
 output wire [63:0] m_awaddr,output wire [11:0] m_awprot,output reg [3:0] m_awvalid,input wire [3:0] m_awready,
 output wire [127:0] m_wdata,output wire [15:0] m_wstrb,output reg [3:0] m_wvalid,input wire [3:0] m_wready,
 input wire [7:0] m_bresp,input wire [3:0] m_bvalid,output reg [3:0] m_bready,
 output wire [63:0] m_araddr,output wire [11:0] m_arprot,output reg [3:0] m_arvalid,input wire [3:0] m_arready,
 input wire [127:0] m_rdata,input wire [7:0] m_rresp,input wire [3:0] m_rvalid,output reg [3:0] m_rready
);
reg aw_have,w_have,aw_sent,w_sent,read_busy,ar_sent;
reg [15:0] awaddr,araddr;
reg [2:0] awprot,arprot;
reg [31:0] wdata;
reg [3:0] wstrb;
wire [1:0] wd=awaddr[13:12],rd=araddr[13:12];
assign s_awready=rst_n&&!aw_have&&!s_bvalid;
assign s_wready=rst_n&&!w_have&&!s_bvalid;
assign s_arready=rst_n&&!read_busy&&!s_rvalid;
assign m_awaddr={4{{4'd0,awaddr[11:0]}}}; assign m_awprot={4{awprot}};
assign m_wdata={4{wdata}}; assign m_wstrb={4{wstrb}};
assign m_araddr={4{{4'd0,araddr[11:0]}}}; assign m_arprot={4{arprot}};
always @* begin
 m_awvalid=0; m_wvalid=0; m_bready=0; m_arvalid=0; m_rready=0;
 if(aw_have&&w_have&&awaddr[15:14]==0&&!s_bvalid) begin
  m_awvalid[wd]=!aw_sent; m_wvalid[wd]=!w_sent;
  m_bready[wd]=aw_sent&&w_sent;
 end
 if(read_busy&&araddr[15:14]==0&&!s_rvalid) begin
  m_arvalid[rd]=!ar_sent; m_rready[rd]=ar_sent;
 end
end
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  aw_have<=0; w_have<=0; aw_sent<=0; w_sent<=0; read_busy<=0; ar_sent<=0;
  awaddr<=0; araddr<=0; awprot<=0; arprot<=0; wdata<=0; wstrb<=0;
  s_bvalid<=0; s_bresp<=0; s_rvalid<=0; s_rresp<=0; s_rdata<=0;
 end else begin
  if(s_bvalid&&s_bready) s_bvalid<=0;
  if(s_rvalid&&s_rready) s_rvalid<=0;
  if(s_awvalid&&s_awready) begin aw_have<=1; awaddr<=s_awaddr; awprot<=s_awprot; end
  if(s_wvalid&&s_wready) begin w_have<=1; wdata<=s_wdata; wstrb<=s_wstrb; end
  if(aw_have&&w_have&&!s_bvalid) begin
   if(awaddr[15:14]!=0) begin
    s_bvalid<=1; s_bresp<=3; aw_have<=0; w_have<=0; aw_sent<=0; w_sent<=0;
   end else begin
    if(m_awvalid[wd]&&m_awready[wd]) aw_sent<=1;
    if(m_wvalid[wd]&&m_wready[wd]) w_sent<=1;
    if(m_bvalid[wd]&&m_bready[wd]) begin
     s_bresp<=m_bresp[wd*2+:2]; s_bvalid<=1;
     aw_have<=0; w_have<=0; aw_sent<=0; w_sent<=0;
    end
   end
  end
  if(s_arvalid&&s_arready) begin read_busy<=1; araddr<=s_araddr; arprot<=s_arprot; ar_sent<=0; end
  if(read_busy&&!s_rvalid) begin
   if(araddr[15:14]!=0) begin s_rvalid<=1; s_rdata<=0; s_rresp<=3; read_busy<=0; end
   else begin
    if(m_arvalid[rd]&&m_arready[rd]) ar_sent<=1;
    if(m_rvalid[rd]&&m_rready[rd]) begin
     s_rdata<=m_rdata[rd*32+:32]; s_rresp<=m_rresp[rd*2+:2]; s_rvalid<=1; read_busy<=0;
    end
   end
  end
 end
end
endmodule
