// Common-clock RMII FCS bank receiver -> generic IPv4/UDP payload stream.
module rmii_udp_receiver #(
 parameter [47:0] MAC=48'h0600aabb0cdd,
 parameter [31:0] IP=32'hc0a8890f,parameter [15:0] PORT=11452
)(
 input wire clk,rst_n,crs,input wire [1:0] rxd,
 output wire m_valid,input wire m_ready,output wire [7:0] m_data,
 output wire m_keep,m_last,output wire [95:0] m_user,
 output wire [31:0] source_ip,output wire [15:0] source_port,
 output wire [31:0] rx_good,rx_bad,rx_overflow,frame_count,frame_bytes,
 output wire [31:0] udp_good,bad_header,bad_ip_checksum,bad_udp_checksum
);
 wire valid,ready,keep,last;wire [7:0] data;wire [95:0] metadata;
 rmii_frame_stream frontend(clk,rst_n,crs,rxd,valid,ready,data,keep,last,metadata,
  rx_good,rx_bad,rx_overflow,frame_count,frame_bytes);
 udp_payload_rx #(.MAC(MAC),.IP(IP),.PORT(PORT)) payload(clk,rst_n,
  valid,ready,data,keep,last,metadata,m_valid,m_ready,m_data,m_keep,m_last,
  m_user,source_ip,source_port,udp_good,bad_header,bad_ip_checksum,bad_udp_checksum);
endmodule
