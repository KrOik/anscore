// Host-loaded words traverse the actual packet fabric and a 24->32 repacker.
// Each input word is one four-byte packet on source 0; sources 1..3 idle.
module loaded_fabric_replay(
 input wire clk,rst_n,req_valid,req_write,input wire [7:0] req_addr,
 input wire [31:0] req_data,input wire [3:0] req_strobe,
 output wire req_ready,resp_valid,resp_error,output wire [31:0] resp_data,
 input wire resp_ready,output reg [7:0] probe
);
 wire [31:0] sd,md;
 wire sv,sr,mv,mr,active,done,error;
 wire [3:0] source_ready;
 wire [23:0] fd;
 wire [2:0] fk;
 wire [7:0] fu,mu;
 wire fl,fv,fr,ml;
 wire [3:0] mk;
 wire [31:0] frames,drops;
 reg [3:0] ticks;
 always @(posedge clk or negedge rst_n)
  if(!rst_n) ticks<=0;else if(!active) ticks<=0;else ticks<=ticks+1'b1;
 wire permit=ticks>=4;
 csr_capture_replay replay(clk,rst_n,req_valid,req_write,req_addr,req_data,req_strobe,
 req_ready,resp_valid,resp_error,resp_data,resp_ready,
 sd,sv,sr,md,mv&&permit,mr,active,done,error);
 // Reset between runs also discards residual traffic after timeout/reset.
 wire stream_reset=rst_n&&active;
 stream_fabric4 fabric(clk,clk,stream_reset,{96'd0,sd},16'h000f,32'd0,
 4'b0001,{3'd0,sv},source_ready,fd,fk,fu,fl,fv,fr,frames,drops);
 assign sr=source_ready[0];
 stream_width_adapter #(.IN_WIDTH(24),.OUT_WIDTH(32)) repack(
 clk,stream_reset,fd,fk,fu,fl,fv,fr,md,mk,mu,ml,mv,mr&&permit);
 always @(posedge clk or negedge rst_n)
  if(!rst_n) probe<=0;
  else probe<={error,ml,mr&&permit,mv,fr,fv,sv,active};
endmodule
