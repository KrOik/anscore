// ============================================================================
// gw2a_cnn_max_pool2d -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: max_pool2d  (adapted from CNN_FPGA rtl_pds, src/max_pool2d.v)
// Board-validated: unit(s) 8 (POOL), digest 35A02396, bitstream mff00
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_max_pool2d #(
    parameter PE_ROW_NUM = 9,
    parameter DATA_WIDTH = 7
)(
    input  wire clk,
    input  wire rst_n,
    input  wire clk_en,
    input  wire  new_line_1,  // row-start pulse
    input  wire  input_valid,  // data beat valid
    input  wire [PE_ROW_NUM*DATA_WIDTH-1:0] data,  // page row data
    output  wire [DATA_WIDTH-1:0] y_out,  // pooled result
    output  wire  new_line_out_1,  // delayed row marker
    output  wire  output_valid   // result valid
);

    wire [PE_ROW_NUM-1:0][DATA_WIDTH-1:0] data_pk;
    assign data_pk = data;

    max_pool2d #(
        .PE_ROW_NUM(PE_ROW_NUM),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .new_line_1(new_line_1),
        .input_valid(input_valid),
        .data(data_pk),
        .y_out(y_out),
        .new_line_out_1(new_line_out_1),
        .output_valid(output_valid)
    );

endmodule
