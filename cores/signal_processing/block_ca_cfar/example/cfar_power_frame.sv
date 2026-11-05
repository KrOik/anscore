// SPDX-License-Identifier: Apache-2.0
// A complete directly connectable default instance. Lists resolve at package root.
module cfar_power_frame(
 input wire clk,rst_n,c_valid, output wire c_ready,
 input wire [31:0] c_length, input wire [15:0] c_alpha_num,c_alpha_den,
 input wire [7:0] c_tag, input wire s_valid, output wire s_ready,
 input wire [15:0] s_data, output wire m_valid, input wire m_ready,
 output wire [31:0] m_index, output wire [15:0] m_sample,
 output wire [18:0] m_noise_sum,
 output wire m_eligible,m_detect,m_last,m_error, output wire [7:0] m_tag
);
 block_ca_cfar dut(.*);
endmodule
