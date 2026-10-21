// ============================================================================
// gw2a_cnn_conv_layer -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: lprnet_layer_direct  (adapted from CNN_FPGA rtl_pds, src/layer.v)
// Board-validated: unit(s) 12 (LAYR), digest 9A9AEA61, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_conv_layer #(
    parameter PE_PAGE_NUM = 2,
    parameter PE_ROW_NUM = 9,
    parameter KERNEL_COL = 3,
    parameter KERNEL_ROW = 3,
    parameter PE_COL_NUM = 2,
    parameter MAX_POOL = 0,
    parameter WITH_RELU = 1,
    parameter DATA_WIDTH = 8,
    parameter WEIGHT_WIDTH = 9,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter CYCLE_PERIOD_IN = 1,
    parameter IMG_COL = 8,
    parameter IMG_ROW = 6,
    parameter STEP_ROW = 1,
    parameter STEP_COL = 1,
    parameter USE_DSP_PE = "no",
    parameter SHIFT_KEY = 4,
    parameter BIAS_WIDTH = 16,
    parameter OUT_WIDTH = 8,
    parameter WEIGHT_FILE0 = "pepage_weight.mem",
    parameter WEIGHT_FILE1 = "pepage_weight.mem",
    parameter WEIGHT_FILE2 = "pepage_weight.mem",
    parameter WEIGHT_FILE3 = "pepage_weight.mem",
    parameter BIAS_FILE = "bias_test.mem"
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_input_1,  // pulse before each input row
    input  wire  data_input_valid,  // pixel beat valid
    input  wire [PE_PAGE_NUM*DATA_WIDTH-1:0] data_input,  // input lanes
    output  wire [PE_COL_NUM*OUT_WIDTH-1:0] y_out,  // conv result
    output  wire  new_line_out_1,  // row marker
    output  wire  output_valid   // result valid
);

    wire [PE_PAGE_NUM-1:0][DATA_WIDTH-1:0] data_input_pk;
    assign data_input_pk = data_input;
    wire [PE_COL_NUM-1:0][OUT_WIDTH-1:0] y_out_pk;
    assign y_out = y_out_pk;

    lprnet_layer_direct #(
        .PE_PAGE_NUM(PE_PAGE_NUM),
        .PE_ROW_NUM(PE_ROW_NUM),
        .KERNEL_COL(KERNEL_COL),
        .KERNEL_ROW(KERNEL_ROW),
        .PE_COL_NUM(PE_COL_NUM),
        .MAX_POOL(MAX_POOL),
        .WITH_RELU(WITH_RELU),
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .CYCLE_PERIOD_IN(CYCLE_PERIOD_IN),
        .IMG_COL(IMG_COL),
        .IMG_ROW(IMG_ROW),
        .STEP_ROW(STEP_ROW),
        .STEP_COL(STEP_COL),
        .USE_DSP_PE(USE_DSP_PE),
        .SHIFT_KEY(SHIFT_KEY),
        .BIAS_WIDTH(BIAS_WIDTH),
        .OUT_WIDTH(OUT_WIDTH),
        .WEIGHT_FILE0(WEIGHT_FILE0),
        .WEIGHT_FILE1(WEIGHT_FILE1),
        .WEIGHT_FILE2(WEIGHT_FILE2),
        .WEIGHT_FILE3(WEIGHT_FILE3),
        .BIAS_FILE(BIAS_FILE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .new_line_input_1(new_line_input_1),
        .data_input_valid(data_input_valid),
        .data_input(data_input_pk),
        .y_out(y_out_pk),
        .new_line_out_1(new_line_out_1),
        .output_valid(output_valid)
    );

endmodule
