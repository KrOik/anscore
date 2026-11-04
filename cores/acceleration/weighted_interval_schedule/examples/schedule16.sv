`timescale 1ns/1ps
module schedule16(
 input wire clk, rst,
 input wire s_valid, output wire s_ready,
 input wire signed [16-1:0] s_start, s_end,
 input wire [16-1:0] s_weight,
 input wire s_keep, s_last, input wire [8-1:0] s_tag,
 output wire m_valid, input wire m_ready,
 output wire m_keep, m_first, m_last,
 output wire [((16<=1)?1:$clog2(16))-1:0] m_index,
 output wire signed [16-1:0] m_start, m_end,
 output wire [16-1:0] m_weight,
 output wire m_selected,
 output wire [$clog2(16+1)-1:0] m_count,
 output wire [16+$clog2(16)-1:0] m_total_weight,
 output wire [16-1:0] m_selection,
 output wire [8-1:0] m_tag, output wire [1:0] m_error
);
 weighted_interval_schedule core(.*);
endmodule
