// ============================================================================
// gw2a_comm_fifo_async -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: fifo_async  (src/fifo_async.v)
// Board-validated: selftest unit 4 (FIFO), digest B5FC9B84,
//   evidence doc/board_uart_*.txt
// Dual-clock FIFO: Gray-coded pointers, 2-FF CDC synchronizers, registered
// dout (read data valid one rd_clk after rd_en).
// ============================================================================
module gw2a_comm_fifo_async #(
    parameter integer DW = 8,              // data width
    parameter integer AW = 4               // depth = 2**AW
)(
    input  wire           wr_clk,
    input  wire           wr_rst_n,
    input  wire           wr_en,
    input  wire [DW-1:0]  din,
    output wire           full,
    input  wire           rd_clk,
    input  wire           rd_rst_n,
    input  wire           rd_en,
    output wire [DW-1:0]  dout,
    output wire           empty
);

    fifo_async #(
        .DW(DW),
        .AW(AW)
    ) u_core (
        .wr_clk(wr_clk),
        .wr_rst_n(wr_rst_n),
        .wr_en(wr_en),
        .din(din),
        .full(full),
        .rd_clk(rd_clk),
        .rd_rst_n(rd_rst_n),
        .rd_en(rd_en),
        .dout(dout),
        .empty(empty)
    );

endmodule
