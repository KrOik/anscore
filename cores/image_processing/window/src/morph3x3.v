// ============================================================================
// morph3x3 -- 3x3 binary morphology.  Each window tap is treated as a binary
// value: tap != 0 counts as 1 (set).  Outputs are 8'hFF / 8'h00.
//   erode  = AND of all 9 tap bits
//   dilate = OR  of all 9 tap bits
//   pix_out = mode ? dilate : erode        (mode is a run-time select pin)
// Both raw outputs are also exposed.  One clk_en beat latency.
// ============================================================================
module morph3x3 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    input  wire        mode,         // 0 = erode, 1 = dilate
    output reg  [7:0]  pix_out,
    output wire [7:0]  erode_out,
    output wire [7:0]  dilate_out,
    output reg         out_valid,
    output reg         nl_out
);
    wire [8:0] b;
    genvar gi;
    generate
        for (gi = 0; gi < 9; gi = gi + 1) begin : g_bits
            assign b[gi] = (win[gi*8 +: 8] != 8'd0);
        end
    endgenerate

    assign erode_out  = (&b) ? 8'hFF : 8'h00;
    assign dilate_out = (|b) ? 8'hFF : 8'h00;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= mode ? dilate_out : erode_out;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
