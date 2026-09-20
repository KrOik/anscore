// ============================================================================
// gw2a_cnn_w_manager -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: w_manager  (adapted from CNN_FPGA rtl_pds, src/w_manager.v)
// Board-validated: unit(s) 3 (WM), digest 6A9E1AC5, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_w_manager #(
    parameter PE_ROW_NUM = 9,
    parameter PE_COL_NUM = 2,
    parameter WEIGHT_WIDTH = 8,
    parameter CYCLE_PERIOD = 2,
    parameter WEIGHT_FILE = "wm_test.mem"  // $readmemb weight init
)(
    input  wire clk,
    input  wire clk_en,
    input  wire  new_line_1,  // restart weight sequence
    output  wire signed [PE_ROW_NUM*PE_COL_NUM*WEIGHT_WIDTH-1:0] W_out   // weight matrix, [col][row] order
);

    wire signed [PE_COL_NUM-1:0][PE_ROW_NUM-1:0][WEIGHT_WIDTH-1:0] W_out_pk;
    assign W_out = W_out_pk;

    w_manager #(
        .PE_ROW_NUM(PE_ROW_NUM),
        .PE_COL_NUM(PE_COL_NUM),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .CYCLE_PERIOD(CYCLE_PERIOD),
        .WEIGHT_FILE(WEIGHT_FILE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .new_line_1(new_line_1),
        .W_out(W_out_pk)
    );

endmodule
