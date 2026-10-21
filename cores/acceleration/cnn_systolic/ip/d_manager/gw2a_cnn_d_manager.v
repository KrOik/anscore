// ============================================================================
// gw2a_cnn_d_manager -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: d_manager  (adapted from CNN_FPGA rtl_pds, src/d_manager.v)
// Board-validated: unit(s) 2 (DM), digest 783B6C25, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_d_manager #(
    parameter PE_ROW_NUM = 9,
    parameter DATA_WIDTH = 7
)(
    input  wire clk,
    input  wire clk_en,
    input  wire [PE_ROW_NUM*DATA_WIDTH-1:0] data,  // input stream
    output  wire [PE_ROW_NUM*DATA_WIDTH-1:0] D   // aligned output stream
);

    wire [PE_ROW_NUM-1:0][DATA_WIDTH-1:0] data_pk;
    assign data_pk = data;
    wire [PE_ROW_NUM-1:0][DATA_WIDTH-1:0] D_pk;
    assign D = D_pk;

    d_manager #(
        .PE_ROW_NUM(PE_ROW_NUM),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .data(data_pk),
        .D(D_pk)
    );

endmodule
