// ============================================================================
// gaussian3x3 -- 3x3 Gaussian blur, fixed kernel (1/16) * [[1,2,1],[2,4,2],
// [1,2,1]].  Shift-add only, no multipliers.  Consumes windows from
// win3x3_gen (win_valid), emits pix_out + out_valid one clk_en beat later.
// ============================================================================
module gaussian3x3 (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,
    input  wire [71:0] win,         // tap i at win[i*8 +: 8], i = r*3+c
    input  wire        win_valid,
    input  wire        new_line_out,
    output reg  [7:0]  pix_out,
    output reg         out_valid,
    output reg         nl_out
);
    wire [7:0] w0 = win[7:0],    w1 = win[15:8],   w2 = win[23:16];
    wire [7:0] w3 = win[31:24],  w4 = win[39:32],  w5 = win[47:40];
    wire [7:0] w6 = win[55:48],  w7 = win[63:56],  w8 = win[71:64];

    // corners*1 + edges*2 + centre*4, sum <= 255*16 = 4080 (12 bits)
    wire [11:0] corners = {4'b0, w0} + {4'b0, w2} + {4'b0, w6} + {4'b0, w8};
    wire [11:0] edges   = {4'b0, w1} + {4'b0, w3} + {4'b0, w5} + {4'b0, w7};
    wire [11:0] sum     = corners + (edges << 1) + ({4'b0, w4} << 2);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pix_out   <= 8'd0;
            out_valid <= 1'b0;
            nl_out    <= 1'b0;
        end else if (clk_en) begin
            pix_out   <= sum[11:4];             // >> 4
            out_valid <= win_valid;
            nl_out    <= new_line_out;
        end
    end
endmodule
