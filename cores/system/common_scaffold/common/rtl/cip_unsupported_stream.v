// Native command/stream placeholder. A transfer occurs only on clk_en.
// Every accepted command receives UNSUPPORTED; no sample is consumed/emitted.
module cip_unsupported_stream #(
    parameter DATA_W = 16,
    parameter TAG_W = 8
)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output reg rsp_valid,
    input wire rsp_ready,
    output reg [TAG_W-1:0] rsp_tag,
    output wire [1:0] rsp_error,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid, s_last,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid, m_last,
    input wire m_ready
);
assign cmd_ready = rst_n && (!rsp_valid || rsp_ready);
assign rsp_error = 2'b01; // UNSUPPORTED; meaningful only with rsp_valid
assign s_ready = 1'b0;
assign m_data = {DATA_W{1'b0}};
assign m_valid = 1'b0;
assign m_last = 1'b0;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin rsp_valid <= 0; rsp_tag <= 0; end
    else if (clk_en) begin
        if (rsp_valid && rsp_ready) rsp_valid <= 0;
        if (cmd_valid && cmd_ready) begin
            rsp_valid <= 1;
            rsp_tag <= cmd_tag;
        end
    end
end
initial begin
    if (DATA_W < 1 || TAG_W < 1) $fatal(1, "positive widths required");
end
endmodule
