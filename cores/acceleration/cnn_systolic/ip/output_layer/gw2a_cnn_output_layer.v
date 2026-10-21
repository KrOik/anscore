// ============================================================================
// gw2a_cnn_output_layer -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: output_layer  (adapted from CNN_FPGA rtl_pds, src/output_layer.v)
// Board-validated: unit(s) 11 (OL), digest 46E9E19D, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_output_layer #(
    parameter PE_PAGE_NUM = 2,
    parameter PE_COL_NUM = 2,
    parameter PE_ROW_NUM = 9,
    parameter PE_OUT_WIDTH = 20,
    parameter BIAS_WIDTH = 16,
    parameter ACC_WIDTH = 22,
    parameter SHIFT_KEY = 4,
    parameter OUT_WIDTH = 8,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter CYCLE_PERIOD_IN = 1,
    parameter IMG_COL = 8,
    parameter WITH_RELU = 1,
    parameter BIAS_FILE = "bias_test.mem"  // $readmemh bias init
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_in,  // row sync from input_layer
    input  wire signed [PE_COL_NUM*PE_PAGE_NUM*PE_OUT_WIDTH-1:0] page_y_out,  // partial sums [page][col]
    output  wire [PE_COL_NUM*OUT_WIDTH-1:0] final_out,  // quantized output
    output  wire  output_valid,  // result valid
    output  wire  new_line_out_1   // row marker
);

    wire signed [PE_PAGE_NUM-1:0][PE_COL_NUM-1:0][PE_OUT_WIDTH-1:0] page_y_out_pk;
    assign page_y_out_pk = page_y_out;
    wire [PE_COL_NUM-1:0][OUT_WIDTH-1:0] final_out_pk;
    assign final_out = final_out_pk;

    output_layer #(
        .PE_PAGE_NUM(PE_PAGE_NUM),
        .PE_COL_NUM(PE_COL_NUM),
        .PE_ROW_NUM(PE_ROW_NUM),
        .PE_OUT_WIDTH(PE_OUT_WIDTH),
        .BIAS_WIDTH(BIAS_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .SHIFT_KEY(SHIFT_KEY),
        .OUT_WIDTH(OUT_WIDTH),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .CYCLE_PERIOD_IN(CYCLE_PERIOD_IN),
        .IMG_COL(IMG_COL),
        .WITH_RELU(WITH_RELU),
        .BIAS_FILE(BIAS_FILE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .new_line_in(new_line_in),
        .page_y_out(page_y_out_pk),
        .final_out(final_out_pk),
        .output_valid(output_valid),
        .new_line_out_1(new_line_out_1)
    );

endmodule
