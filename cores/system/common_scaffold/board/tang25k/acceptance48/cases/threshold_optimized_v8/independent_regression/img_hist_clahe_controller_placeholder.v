// LEGACY error-only compatibility interface. New designs must instantiate
// img_hist_clahe_frame, which implements the real multi-tile frame manager.
// This old interface has no pixel ports and cannot perform image processing.
// Every accepted command produces an UNSUPPORTED error response. There is no
// image-stream bypass that could be mistaken for completed CLAHE processing.
module img_hist_clahe_controller_placeholder #(
    parameter integer TAG_WIDTH = 16
) (
    input wire clk,
    input wire rst_n,
    input wire clk_en,
    input wire start_valid,
    output wire start_ready,
    input wire [TAG_WIDTH-1:0] start_tag,
    output reg done_valid,
    input wire done_ready,
    output wire done_error,
    output wire [7:0] done_error_code,
    output wire [31:0] done_count,
    output reg [TAG_WIDTH-1:0] done_tag
);
    assign start_ready = rst_n && clk_en && !done_valid;
    assign done_error = 1'b1;
    assign done_error_code = 8'h80; // UNSUPPORTED_TILE_FRAME_MANAGER
    assign done_count = 0;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_valid <= 0;
            done_tag <= 0;
        end else if (clk_en) begin
            if (done_valid && done_ready)
                done_valid <= 0;
            if (start_valid && start_ready) begin
                done_valid <= 1;
                done_tag <= start_tag;
            end
        end
    end
endmodule
