// ============================================================================
// feat_lbp -- 3x3 Local Binary Pattern + uniform-pattern flag (wave2 idx12).
//
// Per emitted 3x3 window (win3x3_gen contract, 72-bit tap bus):
//   ring order (clockwise from top-left): w0 w1 w2 w5 w8 w7 w6 w3
//   code bit i = (ring_i >= centre w4)
//   uniform  = (number of 0->1 / 1->0 transitions on the 8-bit ring <= 2)
// Emits code_out and uni_out (8'h01 / 8'h00) one clk_en beat after win_valid.
// Pure combinational path -> registered output; no RAM, no multipliers.
// ============================================================================
module feat_lbp (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [7:0]  code_out,
    output reg  [7:0]  uni_out,
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] w0 = win[7:0],    w1 = win[15:8],   w2 = win[23:16];
    wire [7:0] w3 = win[31:24],  w4 = win[39:32],  w5 = win[47:40];
    wire [7:0] w6 = win[55:48],  w7 = win[63:56],  w8 = win[71:64];

    // clockwise ring starting at top-left tap
    wire b0 = (w0 >= w4);
    wire b1 = (w1 >= w4);
    wire b2 = (w2 >= w4);
    wire b3 = (w5 >= w4);
    wire b4 = (w8 >= w4);
    wire b5 = (w7 >= w4);
    wire b6 = (w6 >= w4);
    wire b7 = (w3 >= w4);

    wire [7:0] code = {b7, b6, b5, b4, b3, b2, b1, b0};

    // ring transition count (b7->b0 wraps)
    wire [3:0] trans = {3'd0, (b0 ^ b1)} + {3'd0, (b1 ^ b2)} +
                       {3'd0, (b2 ^ b3)} + {3'd0, (b3 ^ b4)} +
                       {3'd0, (b4 ^ b5)} + {3'd0, (b5 ^ b6)} +
                       {3'd0, (b6 ^ b7)} + {3'd0, (b7 ^ b0)};
    wire uni = (trans <= 4'd2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            code_out  <= 8'd0;
            uni_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            code_out  <= code;
            uni_out   <= uni ? 8'h01 : 8'h00;
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
