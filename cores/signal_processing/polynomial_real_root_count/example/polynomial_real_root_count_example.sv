// SPDX-License-Identifier: Apache-2.0
`default_nettype none
module polynomial_real_root_count_example(
    input wire clk,rst,s_valid,output wire s_ready,
    input wire signed [7:0] s_c0,s_c1,s_c2,s_c3,s_lower,s_upper,
    input wire [2:0] s_degree,input wire [7:0] s_tag,
    output wire m_valid,input wire m_ready,
    output wire [2:0] m_count,output wire [1:0] m_endpoints,m_status,
    output wire [2:0] m_degree,output wire [7:0] m_tag,
    output wire signed [7:0] m_lower,m_upper
);
    polynomial_real_root_count #(.DATA_W(8),.MAX_DEG(3),.TAG_W(8)) core(.*);
endmodule
`default_nettype wire
