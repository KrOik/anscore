// IP-01 reference composition, packet semantics only.
module stream_fabric4 #(parameter FIFO_DEPTH=32)(
 input wire s_clk,m_clk,rst_n,
 input wire [127:0] s_data,input wire [15:0] s_keep,
 input wire [31:0] s_user,input wire [3:0] s_last,s_valid,
 output wire [3:0] s_ready,
 output wire [23:0] m_data,output wire [2:0] m_keep,
 output wire [7:0] m_user,output wire m_last,m_valid,input wire m_ready,
 output wire [31:0] frames,dropped_packets
);
 wire [127:0] mux_data;
 wire [15:0] mux_keep;
 wire [31:0] mux_user;
 wire [3:0] mux_last,mux_valid;
 wire mux_ready;
 sys_frame_switch4 arbiter(.clk(s_clk),.rst_n(rst_n),
 .s_data(s_data),.s_keep(s_keep),.s_user(s_user),.s_last(s_last),
 .s_valid(s_valid),.s_ready(s_ready),.s_dest(8'd0),
 .m_data(mux_data),.m_keep(mux_keep),.m_user(mux_user),
 .m_last(mux_last),.m_valid(mux_valid),.m_ready({3'd0,mux_ready}),.frames(frames));
 wire [23:0] packed_data;
 wire [2:0] packed_keep;
 wire [7:0] packed_user;
 wire packed_last,packed_valid,packed_ready;
 stream_width_adapter #(.IN_WIDTH(32),.OUT_WIDTH(24)) width_adapter(
 .clk(s_clk),.rst_n(rst_n),.s_data(mux_data[31:0]),.s_keep(mux_keep[3:0]),
 .s_user(mux_user[7:0]),.s_last(mux_last[0]),.s_valid(mux_valid[0]),.s_ready(mux_ready),
 .m_data(packed_data),.m_keep(packed_keep),.m_user(packed_user),
 .m_last(packed_last),.m_valid(packed_valid),.m_ready(packed_ready));
 wire [34:0] fifo_data;
 sys_packet_async_fifo #(.WIDTH(35),.DEPTH(FIFO_DEPTH)) fifo(
 .s_clk(s_clk),.m_clk(m_clk),.rst_n(rst_n),
 .s_data({packed_user,packed_keep,packed_data}),.s_last(packed_last),
 .s_valid(packed_valid),.s_ready(packed_ready),
 .m_data(fifo_data),.m_last(m_last),.m_valid(m_valid),.m_ready(m_ready),
 .dropped_packets(dropped_packets));
 assign {m_user,m_keep,m_data}=fifo_data;
endmodule
