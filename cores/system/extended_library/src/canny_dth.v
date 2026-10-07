// ============================================================================
// canny_dth -- wave2 idx8 (DTH): double-threshold classifier, third stage
// of the Canny edge-detector chain.
//
//   pix >= TH_HI -> 2 (strong edge)
//   pix >= TH_LO -> 1 (weak edge)
//   else         -> 0 (none)
//
// Pure per-pixel stage with one clk_en beat of latency; pix_valid and
// new_line pass through so the cell composes with either stream
// convention (dedicated new_line beats or nl flag on the first pixel).
// All registers clk_en gated (T2).
// ============================================================================
module canny_dth #(
    parameter [7:0] TH_LO = 8'd100,
    parameter [7:0] TH_HI = 8'd200
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [7:0]  pix,
    input  wire        pix_valid,
    input  wire        new_line,
    output reg  [1:0]  cls_out,
    output reg         out_valid,
    output reg         nl_out
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cls_out   <= 2'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            cls_out   <= (pix >= TH_HI) ? 2'd2 :
                         (pix >= TH_LO) ? 2'd1 : 2'd0;
            out_valid <= pix_valid;
            nl_out    <= new_line;
        end
    end
endmodule
