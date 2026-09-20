// ============================================================================
// gw2a_cnn_lprnet_spatial_sum -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: lprnet_spatial_sum  (adapted from CNN_FPGA rtl_pds, src/lprnet_spatial_sum.v)
// Board-validated: unit(s) 14 (SSUM), digest 77330EC1, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_lprnet_spatial_sum #(
    parameter PE_COL_NUM = 2,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter IMG_COL = 8,
    parameter IMG_ROW = 6,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 16
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_input_1,  // pulse before each row
    input  wire  data_input_valid,  // data beat valid
    input  wire signed [PE_COL_NUM*DATA_WIDTH-1:0] data_input,  // signed samples
    output  wire signed [PE_COL_NUM*ACC_WIDTH-1:0] y_out,  // row sums
    output  wire  new_line_out_1,  // row marker
    output  wire  output_valid   // result valid
);

    wire signed [PE_COL_NUM-1:0][DATA_WIDTH-1:0] data_input_pk;
    assign data_input_pk = data_input;
    wire signed [PE_COL_NUM-1:0][ACC_WIDTH-1:0] y_out_pk;
    assign y_out = y_out_pk;

    lprnet_spatial_sum #(
        .PE_COL_NUM(PE_COL_NUM),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .IMG_COL(IMG_COL),
        .IMG_ROW(IMG_ROW),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH)
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
