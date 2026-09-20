// ============================================================================
// gw2a_cnn_pe_page -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: pe_page  (adapted from CNN_FPGA rtl_pds, src/pe_page.v)
// Board-validated: unit(s) 7 (PAGE), digest C5BAB594, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_pe_page #(
    parameter PE_ROW_NUM = 9,
    parameter PE_COL_NUM = 2,
    parameter DATA_WIDTH = 7,
    parameter WEIGHT_WIDTH = 8,
    parameter CYCLE_PERIOD = 2,
    parameter OUTPUT_WIDTH = DATA_WIDTH + WEIGHT_WIDTH + $clog2(PE_ROW_NUM+1),
    parameter USE_DSP_PE = "no",
    parameter WEIGHT_FILE = "pepage_weight.mem"  // $readmemb weight init
)(
    input  wire clk,
    input  wire clk_en,
    input  wire  new_line_1,  // row-start pulse, 1 beat before first data
    input  wire [PE_ROW_NUM*DATA_WIDTH-1:0] data,  // one input row beat
    output  wire signed [PE_COL_NUM*OUTPUT_WIDTH-1:0] y_out   // per-column results
);

    wire [PE_ROW_NUM-1:0][DATA_WIDTH-1:0] data_pk;
    assign data_pk = data;
    wire signed [PE_COL_NUM-1:0][OUTPUT_WIDTH-1:0] y_out_pk;
    assign y_out = y_out_pk;

    pe_page #(
        .PE_ROW_NUM(PE_ROW_NUM),
        .PE_COL_NUM(PE_COL_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .WEIGHT_WIDTH(WEIGHT_WIDTH),
        .CYCLE_PERIOD(CYCLE_PERIOD),
        .OUTPUT_WIDTH(OUTPUT_WIDTH),
        .USE_DSP_PE(USE_DSP_PE),
        .WEIGHT_FILE(WEIGHT_FILE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .new_line_1(new_line_1),
        .data(data_pk),
        .y_out(y_out_pk)
    );

endmodule
