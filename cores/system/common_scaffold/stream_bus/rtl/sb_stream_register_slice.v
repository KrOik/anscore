// functional_minimal: STAGES elastic registers; backward READY is combinational.
module sb_stream_register_slice #(
    parameter DATA_WIDTH = 32, parameter USER_WIDTH = 1, parameter STAGES = 2
)(
    input wire clk, rst_n, clk_en,
    input wire [DATA_WIDTH-1:0] s_data,
    input wire [DATA_WIDTH/8-1:0] s_keep,
    input wire [USER_WIDTH-1:0] s_user,
    input wire s_last, s_valid, output wire s_ready,
    output wire [DATA_WIDTH-1:0] m_data,
    output wire [DATA_WIDTH/8-1:0] m_keep,
    output wire [USER_WIDTH-1:0] m_user,
    output wire m_last, m_valid, input wire m_ready
);
    wire [DATA_WIDTH-1:0] data [0:STAGES];
    wire [DATA_WIDTH/8-1:0] keep [0:STAGES];
    wire [USER_WIDTH-1:0] user [0:STAGES];
    wire [STAGES:0] last, valid, ready;
    assign data[0]=s_data; assign keep[0]=s_keep; assign user[0]=s_user;
    assign last[0]=s_last; assign valid[0]=s_valid; assign s_ready=ready[0];
    assign m_data=data[STAGES]; assign m_keep=keep[STAGES]; assign m_user=user[STAGES];
    assign m_last=last[STAGES]; assign m_valid=valid[STAGES]; assign ready[STAGES]=m_ready;
    genvar k;
    generate for(k=0;k<STAGES;k=k+1) begin: stage
        sb_stream_elastic #(.DATA_WIDTH(DATA_WIDTH),.USER_WIDTH(USER_WIDTH)) reg_i (
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
            .s_data(data[k]),.s_keep(keep[k]),.s_user(user[k]),
            .s_last(last[k]),.s_valid(valid[k]),.s_ready(ready[k]),
            .m_data(data[k+1]),.m_keep(keep[k+1]),.m_user(user[k+1]),
            .m_last(last[k+1]),.m_valid(valid[k+1]),.m_ready(ready[k+1]));
    end endgenerate
    initial if (STAGES < 1) $fatal(1,"sb_stream_register_slice: STAGES>=1 required");
endmodule
