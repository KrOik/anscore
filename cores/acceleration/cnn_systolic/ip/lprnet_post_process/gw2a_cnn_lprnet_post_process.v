// ============================================================================
// gw2a_cnn_lprnet_post_process -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: lprnet_post_process  (adapted from CNN_FPGA rtl_pds, src/lprnet_post_process.v)
// Board-validated: unit(s) 15 (CTC), digest ED74208A, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_lprnet_post_process #(
    parameter PE_COL_NUM = 2,
    parameter CYCLE_PERIOD_OUT = 2,
    parameter IMG_COL = 8,
    parameter IMG_ROW = 6,
    parameter DATA_WIDTH = 8,
    parameter ACC_WIDTH = 16,
    parameter CONV_POSITIVE = 1,
    parameter BLANK_CHAR = 3,
    parameter VALID_CHAR_NUM = 4,
    parameter OCHW = $clog2(CYCLE_PERIOD_OUT*PE_COL_NUM)  // char index width
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_input_1,  // pulse before each row
    input  wire  data_input_valid,  // data beat valid
    input  wire signed [PE_COL_NUM*DATA_WIDTH-1:0] data_input,  // signed samples
    output  wire [OCHW-1:0] out_char,  // decoded channel index
    output  wire  out_valid,  // decoded char valid
    output  wire  frame_start_out   // 1 beat before out_valid
);

    wire signed [PE_COL_NUM-1:0][DATA_WIDTH-1:0] data_input_pk;
    assign data_input_pk = data_input;

    lprnet_post_process #(
        .PE_COL_NUM(PE_COL_NUM),
        .CYCLE_PERIOD_OUT(CYCLE_PERIOD_OUT),
        .IMG_COL(IMG_COL),
        .IMG_ROW(IMG_ROW),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH(ACC_WIDTH),
        .CONV_POSITIVE(CONV_POSITIVE),
        .BLANK_CHAR(BLANK_CHAR),
        .VALID_CHAR_NUM(VALID_CHAR_NUM)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .new_line_input_1(new_line_input_1),
        .data_input_valid(data_input_valid),
        .data_input(data_input_pk),
        .out_char(out_char),
        .out_valid(out_valid),
        .frame_start_out(frame_start_out)
    );

endmodule
