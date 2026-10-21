// Completion covers actual final RMII FCS plus96-bit IFG, not merely packing.
module rmii_udp_transmitter #(
 parameter [47:0] MAC=48'h0600aabb0cdd,parameter [31:0] IP=32'hc0a8890f
)(
 input wire clk,rst_n,cmd_valid,output wire cmd_ready,
 input wire [47:0] cmd_dst_mac,input wire [31:0] cmd_dst_ip,
 input wire [15:0] cmd_src_port,cmd_dst_port,cmd_length,cmd_ip_id,
 input wire [95:0] cmd_user,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,
 input wire s_keep,s_last,output wire txen,output wire [1:0] txd,
 output wire done_valid,input wire done_ready,output wire [2:0] done_error,
 output wire [95:0] done_user,output wire [31:0] sent_frames,sent_bytes
);
 wire fv,fr,fk,fl,packed_done,wire_done;wire [7:0] fd;wire [95:0] fu;
 wire [1:0] pack_error,wire_error;reg [95:0] owner;
 wire ack=done_valid&&done_ready;
 assign done_valid=packed_done&&(pack_error!=0||wire_done);
 assign done_error=pack_error!=0?{1'b0,pack_error}:wire_error!=0?3'd4:3'd0;
 assign done_user=owner;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)owner<=0;else if(cmd_valid&&cmd_ready)owner<=cmd_user;
 udp_frame_tx #(.MAC(MAC),.IP(IP)) packetizer(clk,rst_n,cmd_valid,cmd_ready,
  cmd_dst_mac,cmd_dst_ip,cmd_src_port,cmd_dst_port,cmd_length,cmd_ip_id,cmd_user,
  s_valid,s_ready,s_data,s_keep,s_last,fv,fr,fd,fk,fl,fu,packed_done,ack,pack_error);
 rmii_frame_tx serializer(clk,rst_n,fv,fr,fd,fk,fl,fu,txen,txd,
  wire_done,ack,wire_error,,sent_frames,sent_bytes);
endmodule
