// Composite DSP reference chain. Atomic configuration drains both result slots.
// Low-active synchronous reset; no new arithmetic and no changes to reused cores.
module dc_statistics_stream (
 input wire clk, rst_n,
 input wire signed [15:0] s_tdata, input wire s_tvalid, output wire s_tready,
 output wire [127:0] m_tdata, output wire [1:0] m_tuser,
 output wire m_tvalid, input wire m_tready,
 input wire cfg_valid, output wire cfg_ready,
 input wire [1:0] cfg_dc_mode, input wire [15:0] cfg_dc_pole,
 input wire [3:0] cfg_dc_log2,
 input wire cfg_stats_block, input wire [3:0] cfg_stats_log2,
 input wire signed [4:0] cfg_stats_scale, input wire [31:0] cfg_stats_threshold,
 output reg cfg_done, cfg_error
);
 wire [31:0] dc_data;
 wire dc_valid, dc_ready, input_ready, dc_cfg_ready, stats_cfg_ready;
 wire unused_dc_done, unused_dc_error, unused_stats_done, unused_stats_error;
 assign cfg_ready = rst_n && dc_cfg_ready && stats_cfg_ready;
 wire legal = cfg_dc_mode < 3 && cfg_dc_log2 <= 8 &&
              cfg_stats_log2 <= 6 && cfg_stats_scale >= -5'sd8;
 wire commit = cfg_valid && cfg_ready && legal;
 assign s_tready = input_ready && !cfg_valid;
 dc_stream dc (
  .clk(clk), .rst_n(rst_n),
  .s_tdata(s_tdata), .s_tvalid(s_tvalid && !cfg_valid), .s_tready(input_ready),
  .m_tdata(dc_data), .m_tvalid(dc_valid), .m_tready(dc_ready),
  .cfg_valid(commit), .cfg_ready(dc_cfg_ready),
  .cfg_mode(cfg_dc_mode), .cfg_pole(cfg_dc_pole), .cfg_window_log2(cfg_dc_log2),
  .cfg_done(unused_dc_done), .cfg_error(unused_dc_error)
 );
 statistics_stream #(.LOGIC_SQUARE(1)) stats (
  .clk(clk), .rst_n(rst_n),
  .s_tdata(dc_data[15:0]), .s_tvalid(dc_valid), .s_tready(dc_ready),
  .m_tdata(m_tdata), .m_tuser(m_tuser), .m_tvalid(m_tvalid), .m_tready(m_tready),
  .cfg_valid(commit), .cfg_ready(stats_cfg_ready),
  .cfg_block(cfg_stats_block), .cfg_log2(cfg_stats_log2),
  .cfg_scale(cfg_stats_scale), .cfg_threshold(cfg_stats_threshold),
  .cfg_done(unused_stats_done), .cfg_error(unused_stats_error)
 );
 always @(posedge clk) begin
  if (!rst_n) begin cfg_done <= 0; cfg_error <= 0; end
  else begin
   cfg_done <= cfg_valid && cfg_ready;
   cfg_error <= cfg_valid && cfg_ready && !legal;
  end
 end
endmodule
