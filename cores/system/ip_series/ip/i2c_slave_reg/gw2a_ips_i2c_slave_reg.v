// ---------------------------------------------------------------------------
// gw2a_ips_i2c_slave_reg : packaged, licensable wrapper for the ips_i2c_slave_reg core.
// Family iface.  I2C 7-bit slave with 8-bit register index auto-increment and repeated-start safe state decode
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_i2c_slave_reg #(
    parameter SLAVE_ADDR = 7'h34,
    parameter REG_BITS = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire scl,
    inout wire sda,
    output wire [2:0] o_state,
    output wire [7:0] ptr,
    output wire [7:0] o_rdata,
    output wire [7:0] o_last,
    output wire [3:0] o_err_nam,
    output wire [3:0] o_err_fmt,
    output wire [7:0] o_txn,
    output wire o_ack,
    output wire o_lo
);

    ips_i2c_slave_reg #(
        .SLAVE_ADDR(SLAVE_ADDR),
        .REG_BITS(REG_BITS)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .scl(scl),
        .sda(sda),
        .o_state(o_state),
        .ptr(ptr),
        .o_rdata(o_rdata),
        .o_last(o_last),
        .o_err_nam(o_err_nam),
        .o_err_fmt(o_err_fmt),
        .o_txn(o_txn),
        .o_ack(o_ack),
        .o_lo(o_lo)
    );

endmodule
