// implementation_draft_unverified. One-entry UNSUPPORTED response channel.
// Legacy compatibility helper: commands complete with errors; pixels never transfer.
// Active Canny/denoise/morphology entries now implement their own processing.
// Native protocol: transfer = clk_en && valid && ready.
module img_filter_reject_command #(
    parameter [7:0] ERROR_CODE = 8'hff
)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid, output wire cmd_ready,
    input wire [7:0] cmd_tag,
    output reg rsp_valid, input wire rsp_ready,
    output reg [7:0] rsp_tag,
    output wire [7:0] rsp_error
);
    assign cmd_ready = rst_n && clk_en && (!rsp_valid || rsp_ready);
    assign rsp_error = ERROR_CODE;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rsp_valid <= 1'b0; rsp_tag <= 8'd0; end
        else if (clk_en && (!rsp_valid || rsp_ready)) begin
            rsp_valid <= cmd_valid;
            if (cmd_valid) rsp_tag <= cmd_tag;
        end
    end
endmodule
