// ============================================================================
// gw2a_cnn_pe_col -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: pe_col  (adapted from CNN_FPGA rtl_pds, src/pe_col.v)
// Board-validated: unit(s) 6 (COL), digest D149A670, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_pe_col #(
    parameter PE_ROW_NUM = 9,
    parameter DATA_WIDTH = 7,
    parameter WEIGHT_WIDTH = 8,
    parameter OUTPUT_WIDTH = DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1),
    parameter USE_DSP_PE = "no"
)(
    input  wire clk,
    input  wire clk_en,
    input  wire [PE_ROW_NUM*DATA_WIDTH-1:0] D,  // unrolled kernel data
    input  wire signed [PE_ROW_NUM*WEIGHT_WIDTH-1:0] W,  // unrolled kernel weights
    output  wire signed [OUTPUT_WIDTH-1:0] y_out   // dot-product result
);

    wire [PE_ROW_NUM-1:0][DATA_WIDTH-1:0] D_pk;
    assign D_pk = D;
    wire signed [PE_ROW_NUM-1:0][WEIGHT_WIDTH-1:0] W_pk;
    assign W_pk = W;

    pe_col #(
        .PE_ROW_NUM(PE_ROW_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .USE_DSP_PE(USE_DSP_PE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .D(D_pk),
        .W(W_pk),
        .y_out(y_out)
    );

endmodule
