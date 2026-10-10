// ---------------------------------------------------------------------------
// gw2a_ips_spi_slave_reg : packaged, licensable wrapper for the ips_spi_slave_reg core.
// Family iface.  SPI mode 0-3 slave, 8/16-bit frame, register-indexed read/write with CS-edge alignment
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_spi_slave_reg #(
    parameter SPI_MODE = 0,
    parameter FRAME = 8,
    parameter REG_BITS = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire ss_n,
    input wire sclk,
    input wire mosi,
    inout wire miso,
    output wire [FRAME-1:0] o_rx,
    output wire [FRAME-1:0] o_tx,
    output wire [7:0] ptr,
    output wire [2:0] o_state,
    output wire [3:0] o_err_no_cs,
    output wire [3:0] o_err_short,
    output wire [7:0] o_xfer,
    output wire [3:0] o_rem,
    output wire o_drive,
    output wire o_txb,
    output wire o_rw
);

    ips_spi_slave_reg #(
        .SPI_MODE(SPI_MODE),
        .FRAME(FRAME),
        .REG_BITS(REG_BITS)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .ss_n(ss_n),
        .sclk(sclk),
        .mosi(mosi),
        .miso(miso),
        .o_rx(o_rx),
        .o_tx(o_tx),
        .ptr(ptr),
        .o_state(o_state),
        .o_err_no_cs(o_err_no_cs),
        .o_err_short(o_err_short),
        .o_xfer(o_xfer),
        .o_rem(o_rem),
        .o_drive(o_drive),
        .o_txb(o_txb),
        .o_rw(o_rw)
    );

endmodule
