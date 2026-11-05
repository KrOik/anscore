module descriptor_drr4 (
    input wire clk, rst, run_enable, cmd_valid, output wire cmd_ready,
    input wire [1:0] cmd_op, input wire [31:0] cmd_flow,
    input wire [11:0] cmd_cost, input wire [31:0] cmd_data,
    input wire [7:0] cmd_tag, output wire rsp_valid, input wire rsp_ready,
    output wire [2:0] rsp_status, output wire [31:0] rsp_flow,
    output wire [7:0] rsp_tag, output wire [3:0] rsp_count,
    output wire [11:0] rsp_quantum, output wire [12:0] rsp_deficit,
    output wire m_valid, input wire m_ready, output wire [31:0] m_flow,
    output wire [11:0] m_cost, output wire [31:0] m_data,
    output wire [7:0] m_tag
);
    descriptor_drr_scheduler core (.*);
endmodule
