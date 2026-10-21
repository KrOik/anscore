// Store-and-forward, one complete packet in flight. Common reset for both clocks.
// Oversize packets are drained and discarded atomically, never partly emitted.
module sys_packet_async_fifo #(parameter WIDTH=45,parameter DEPTH=16)(
 input wire s_clk,m_clk,rst_n,
 input wire [WIDTH-1:0] s_data,input wire s_last,s_valid,output wire s_ready,
 output wire [WIDTH-1:0] m_data,output reg m_last,m_valid,input wire m_ready,
 output reg [31:0] dropped_packets
);
localparam AW=$clog2(DEPTH);
(* ram_style="block" *) reg [WIDTH-1:0] mem[0:DEPTH-1];
reg [AW:0] written,length;
reg discard,waiting,req,ack;
(* async_reg="true" *) reg ack1,ack2,req1,req2;
reg seen,reading;
reg [AW:0] issued,read_length;
reg [WIDTH-1:0] read_data;
assign s_ready=rst_n&&!waiting;
wire take=s_valid&&s_ready;
wire store=take&&!discard&&(written<DEPTH);
wire fetch=reading&&(issued<read_length)&&(!m_valid||m_ready);
assign m_data=read_data;
always @(posedge s_clk) if(store) mem[written[AW-1:0]]<=s_data;
always @(posedge m_clk) if(fetch) read_data<=mem[issued[AW-1:0]];
always @(posedge s_clk or negedge rst_n) begin
 if(!rst_n) begin written<=0; length<=0; discard<=0; waiting<=0; req<=0; ack1<=0; ack2<=0; dropped_packets<=0; end
 else begin
  ack1<=ack; ack2<=ack1;
  if(waiting&&ack2==req) begin waiting<=0; written<=0; end
  if(take) begin
   if(s_last) begin
    if(discard||written>=DEPTH) begin dropped_packets<=dropped_packets+1; written<=0; discard<=0; end
    else begin length<=written+1'b1; waiting<=1; req<=~req; end
   end else if(!discard) begin
    if(written==DEPTH-1) discard<=1;
    else written<=written+1'b1;
   end
  end
 end
end
always @(posedge m_clk or negedge rst_n) begin
 if(!rst_n) begin req1<=0; req2<=0; seen<=0; ack<=0; reading<=0; issued<=0; read_length<=0; m_valid<=0; m_last<=0; end
 else begin
  req1<=req; req2<=req1;
  if(!reading&&req2!=seen) begin
   seen<=req2; reading<=1; issued<=0; read_length<=length;
  end
  if(fetch) begin
   issued<=issued+1'b1; m_valid<=1; m_last<=(issued+1'b1==read_length);
  end else if(m_valid&&m_ready) m_valid<=0;
  if(m_valid&&m_ready&&m_last) begin reading<=0; ack<=seen; end
 end
end
initial if(WIDTH<1||DEPTH<2||(DEPTH&(DEPTH-1))!=0) $fatal(1,"invalid FIFO parameters");
endmodule
