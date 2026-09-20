// ============================================================================
// gw2a_cnn_extrema_finder -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: extrema_finder  (adapted from CNN_FPGA rtl_pds, src/extrema_finder.v)
// Board-validated: unit(s) 13 (EXTR), digest 931885AA, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_extrema_finder #(
    parameter DATA_WIDTH = 8,
    parameter PE_COL_NUM = 2,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter CONV_POSITIVE = 1,
    parameter CHW = $clog2(CYCLE_PERIOD_OUT*PE_COL_NUM)  // channel index width
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  data_input_valid,  // data beat valid
    input  wire  new_line_1,  // reset cycle counter per row
    input  wire signed [PE_COL_NUM*DATA_WIDTH-1:0] data_in,  // signed samples
    output  wire signed [DATA_WIDTH-1:0] val_out,  // extremum value
    output  wire [CHW-1:0] val_out_channel,  // winning channel index
    output  wire  val_valid   // result valid
);

    wire signed [PE_COL_NUM-1:0][DATA_WIDTH-1:0] data_in_pk;
    assign data_in_pk = data_in;

    extrema_finder #(
        .DATA_WIDTH(DATA_WIDTH),
        .PE_COL_NUM(PE_COL_NUM),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .CONV_POSITIVE(CONV_POSITIVE)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .data_input_valid(data_input_valid),
        .new_line_1(new_line_1),
        .data_in(data_in_pk),
        .val_out(val_out),
        .val_out_channel(val_out_channel),
        .val_valid(val_valid)
    );

endmodule
