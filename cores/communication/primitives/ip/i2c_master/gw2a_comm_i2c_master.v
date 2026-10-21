// ============================================================================
// gw2a_comm_i2c_master -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: i2c_master  (src/i2c_master.v)
// Board-validated: selftest unit 2 (I2CM), digest D6A89792,
//   evidence doc/board_uart_*.txt
// I2C master: 7-bit addr, multi-byte read/write, ACK/NACK, clock-stretch
// tolerant, open-drain sda/scl via *_oe (drive pin low when oe=1).
// ============================================================================
module gw2a_comm_i2c_master #(
    parameter integer QDIV = 64            // quarter-bit divider (clk_en beats)
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       clk_en,              // step enable; tie 1 for full rate
    input  wire       start,
    input  wire [6:0] addr,
    input  wire       rw,                  // 0 = write, 1 = read
    input  wire [4:0] len,                 // data byte count, 1..16
    input  wire [7:0] tx_data,
    input  wire       tx_valid,
    output wire       tx_ready,
    output wire [7:0] rx_data,
    output wire       rx_valid,
    input  wire       rx_ack,
    output wire       busy,
    output wire       done,
    output wire       nack,
    input  wire       sda_in,
    input  wire       scl_in,
    output wire       sda_oe,
    output wire       scl_oe
);

    i2c_master #(
        .QDIV(QDIV)
    ) u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .start(start),
        .addr(addr),
        .rw(rw),
        .len(len),
        .tx_data(tx_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .rx_data(rx_data),
        .rx_valid(rx_valid),
        .rx_ack(rx_ack),
        .busy(busy),
        .done(done),
        .nack(nack),
        .sda_in(sda_in),
        .scl_in(scl_in),
        .sda_oe(sda_oe),
        .scl_oe(scl_oe)
    );

endmodule
