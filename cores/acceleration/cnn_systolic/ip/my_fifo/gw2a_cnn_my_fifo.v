// ============================================================================
// gw2a_cnn_my_fifo -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: my_fifo  (adapted from CNN_FPGA rtl_pds, src/my_fifo.v)
// Board-validated: unit(s) 5 (FIFO), digest D0C7C975, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_my_fifo #(
    parameter DATA_WIDTH = 8,
    parameter FIFO_DEPTH = 16
)(
    input  wire rd_clk,
    input  wire wr_clk,
    input  wire  rst,  // async reset, ACTIVE HIGH
    input  wire  wr_en,  // write enable
    input  wire [DATA_WIDTH-1:0] din,  // write data
    input  wire  rd_en,  // read enable
    output  wire [DATA_WIDTH-1:0] dout,  // read data
    output  wire  full,  // wr domain
    output  wire  empty   // rd domain
);

    my_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(FIFO_DEPTH)
    ) u_core (
        .rd_clk(rd_clk),
        .wr_clk(wr_clk),
        .rst(rst),
        .wr_en(wr_en),
        .din(din),
        .rd_en(rd_en),
        .dout(dout),
        .full(full),
        .empty(empty)
    );

endmodule
