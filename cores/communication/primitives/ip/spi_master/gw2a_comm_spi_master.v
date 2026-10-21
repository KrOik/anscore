// ============================================================================
// gw2a_comm_spi_master -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: spi_master  (src/spi_master.v)
// Board-validated: selftest unit 1 (SPIM), digest E4107F07,
//   evidence doc/board_uart_*.txt
// SPI master: CPOL/CPHA params, SCLK divider, 8/16/32-bit (1..32) transfers.
// ============================================================================
module gw2a_comm_spi_master #(
    parameter integer CPOL     = 0,
    parameter integer CPHA     = 0,
    parameter integer SCLK_DIV = 4         // sclk period = 2*SCLK_DIV clk_en beats
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_en,             // step enable; tie 1 for full rate
    input  wire        start,
    input  wire [5:0]  nbits,              // transfer length 1..32
    input  wire [31:0] tx_data,            // MSB-first
    output wire [31:0] rx_data,            // received word, MSB-first aligned
    output wire        busy,
    output wire        done,
    output wire        sclk,
    output wire        mosi,
    input  wire        miso,
    output wire        cs_n
);

    spi_master #(
        .CPOL(CPOL),
        .CPHA(CPHA),
        .SCLK_DIV(SCLK_DIV)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .start(start),
        .nbits(nbits),
        .tx_data(tx_data),
        .rx_data(rx_data),
        .busy(busy),
        .done(done),
        .sclk(sclk),
        .mosi(mosi),
        .miso(miso),
        .cs_n(cs_n)
    );

endmodule
