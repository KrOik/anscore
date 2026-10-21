// ============================================================================
// gw2a_cnn_input_layer -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: input_layer  (adapted from CNN_FPGA rtl_pds, src/input_layer.v)
// Board-validated: unit(s) 10 (IL), digest 41C4C21F, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_input_layer #(
    parameter DATA_WIDTH = 8,
    parameter PE_PAGE_NUM = 2,
    parameter PE_ROW_NUM = 9,
    parameter CYCLE_PERIOD_IN = 1,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter STEP_ROW = 1,
    parameter STEP_COL = 1,
    parameter KERNEL_ROW = 3,
    parameter KERNEL_COL = 3,
    parameter IMG_COL = 8,
    parameter IMG_ROW = 6
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_input_1,  // pulse before each input row
    input  wire  data_input_valid,  // pixel beat valid
    input  wire [PE_PAGE_NUM*DATA_WIDTH-1:0] data_input,  // page lanes per beat
    output  wire [PE_PAGE_NUM*PE_ROW_NUM*DATA_WIDTH-1:0] data_out,  // conv window, [row][page]
    output  wire  line_buf_full,  // line buffer backpressure
    output  wire  data_out_valid,  // window valid
    output  wire  new_line_out_1   // window row marker
);

    wire [PE_PAGE_NUM-1:0][DATA_WIDTH-1:0] data_input_pk;
    assign data_input_pk = data_input;
    wire [PE_ROW_NUM-1:0][PE_PAGE_NUM-1:0][DATA_WIDTH-1:0] data_out_pk;
    assign data_out = data_out_pk;

    input_layer #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_PAGE_NUM(PE_PAGE_NUM),
        .PE_ROW_NUM(PE_ROW_NUM),
        .CYCLE_PERIOD_IN(CYCLE_PERIOD_IN),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .STEP_ROW(STEP_ROW),
        .STEP_COL(STEP_COL),
        .KERNEL_ROW(KERNEL_ROW),
        .KERNEL_COL(KERNEL_COL),
        .IMG_COL(IMG_COL),
        .IMG_ROW(IMG_ROW)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .new_line_input_1(new_line_input_1),
        .data_input_valid(data_input_valid),
        .data_input(data_input_pk),
        .data_out(data_out_pk),
        .line_buf_full(line_buf_full),
        .data_out_valid(data_out_valid),
        .new_line_out_1(new_line_out_1)
    );

endmodule
