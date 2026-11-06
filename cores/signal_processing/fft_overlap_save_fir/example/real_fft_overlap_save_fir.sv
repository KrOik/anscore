// Original ANSCORE real-input adapter. Apache-2.0.
// Imaginary output is exposed because finite fixed-point arithmetic is explicit.
module real_fft_overlap_save_fir #(
 parameter integer LOG_N=6,DATA_W=16,TAG_W=8
)(
 input wire clk,rst,
 input wire g_valid,output wire g_ready,
 input wire [31:0] g_taps,g_frac,input wire [TAG_W-1:0] g_tag,
 input wire k_valid,output wire k_ready,input wire signed [DATA_W-1:0] k_data,
 input wire k_last,k_invalid,
 output wire r_valid,input wire r_ready,
 output wire [3:0] r_status,output wire [31:0] r_taps,r_frac,r_received,
 output wire r_overflow,r_inexact,output wire [TAG_W-1:0] r_tag,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_count,input wire c_end,c_restart,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire signed [DATA_W-1:0] s_data,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,
 output wire signed [DATA_W-1:0] m_data,m_im_residual,
 output wire m_keep,m_last,m_error,output wire [3:0] m_status,
 output wire m_overflow,m_inexact,
 output wire [LOG_N-1:0] m_index,
 output wire [31:0] m_count,m_total,m_received,
 output wire [TAG_W-1:0] m_tag,output wire busy
);
 fft_overlap_save_fir #(.LOG_N(LOG_N),.DATA_W(DATA_W),.TAG_W(TAG_W)) filter (
  .clk(clk),.rst(rst),.g_valid(g_valid),.g_ready(g_ready),
  .g_taps(g_taps),.g_frac(g_frac),.g_tag(g_tag),
  .k_valid(k_valid),.k_ready(k_ready),.k_re(k_data),.k_im({DATA_W{1'b0}}),
  .k_last(k_last),.k_invalid(k_invalid),
  .r_valid(r_valid),.r_ready(r_ready),.r_status(r_status),.r_taps(r_taps),
  .r_frac(r_frac),.r_received(r_received),.r_overflow(r_overflow),
  .r_inexact(r_inexact),.r_tag(r_tag),
  .c_valid(c_valid),.c_ready(c_ready),.c_count(c_count),.c_end(c_end),
  .c_restart(c_restart),.c_tag(c_tag),.s_valid(s_valid),.s_ready(s_ready),
  .s_re(s_data),.s_im({DATA_W{1'b0}}),.s_last(s_last),.s_invalid(s_invalid),
  .m_valid(m_valid),.m_ready(m_ready),.m_re(m_data),.m_im(m_im_residual),
  .m_keep(m_keep),.m_last(m_last),.m_error(m_error),.m_status(m_status),
  .m_overflow(m_overflow),.m_inexact(m_inexact),.m_index(m_index),
  .m_count(m_count),.m_total(m_total),.m_received(m_received),.m_tag(m_tag),.busy(busy));
endmodule
