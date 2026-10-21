// ============================================================================
// threshold_bin -- fixed-threshold binarizer for an 8-bit pixel stream.
//   pix_out = (pix >= THRESH) ? 8'hFF : 8'h00
// Pure per-pixel operation (no window needed); passes the stream protocol
// through with one clk_en beat of latency: pix_valid -> out_valid,
// new_line -> new_line_out, so it can sit in front of a win3x3_gen.
// ============================================================================
module threshold_bin #(
    parameter [7:0] THRESH = 8'd128
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire [7:0] pix,
    input  wire       pix_valid,
    input  wire       new_line,
    output reg  [7:0] pix_out,
    output reg        out_valid,
    output reg        new_line_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out      <= 8'd0;
            out_valid    <= 1'b0;
            new_line_out <= 1'b0;
        end else if (clk_en) begin
            pix_out      <= (pix >= THRESH) ? 8'hFF : 8'h00;
            out_valid    <= pix_valid;
            new_line_out <= new_line;
        end
    end
endmodule
