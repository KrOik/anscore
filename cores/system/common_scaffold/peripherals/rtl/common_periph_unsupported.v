`default_nettype none
// Deliberate placeholder endpoint. Every accepted command returns UNSUPPORTED.
// Native clock-enable protocol: transfers occur only with clk_en == 1.
module common_periph_unsupported (
    input wire clk, input wire rst_n, input wire clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire cmd_write, input wire [7:0] cmd_addr,
    input wire [31:0] cmd_wdata,
    output reg rsp_valid, input wire rsp_ready,
    output wire [31:0] rsp_rdata, output wire [1:0] rsp_error
);
    assign cmd_ready = rst_n && clk_en && !rsp_valid;
    assign rsp_rdata = 32'b0;
    assign rsp_error = 2'd1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rsp_valid <= 1'b0;
        else if (clk_en) begin
            if (rsp_valid && rsp_ready) rsp_valid <= 1'b0;
            if (cmd_valid && cmd_ready) rsp_valid <= 1'b1;
        end
    end
endmodule
`default_nettype wire
