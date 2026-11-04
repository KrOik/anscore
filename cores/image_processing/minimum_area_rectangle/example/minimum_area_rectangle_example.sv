// Offline wiring example. No CE-qualified neighbor is connected implicitly.
module minimum_area_rectangle_example(
    input wire clk,rst,s_valid,s_keep,s_last,m_ready,
    input wire signed [7:0] s_x,s_y,input wire [7:0] s_tag,
    output wire s_ready,m_valid,
    output wire signed [35:0] m_axis_x,m_axis_y,m_u_min,m_u_max,m_v_min,m_v_max,
    output wire [35:0] m_den,m_area_num,
    output wire m_pair_valid,
    output wire [2:0] m_pair_i,m_pair_j,m_u_min_index,m_u_max_index,m_v_min_index,m_v_max_index,
    output wire [1:0] m_dimension,m_status,
    output wire [3:0] m_count,output wire [7:0] m_tag
);
    minimum_area_rectangle core(.*);
endmodule
