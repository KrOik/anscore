// ---------------------------------------------------------------------------
// gw2a_ips_gpio_irq_bank : packaged, licensable wrapper for the ips_gpio_irq_bank core.
// Family ctrl.  32-bit GPIO bank with direction, polarity, edge/level interrupt, sticky status and clear-on-write
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_gpio_irq_bank (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [31:0] pin_in,
    input wire [3:0] bus_addr,
    input wire bus_we,
    input wire [31:0] bus_wdata,
    input wire bus_ack,
    output wire [31:0] bus_rdata,
    output wire [15:0] pend,
    output wire [31:0] pin_out,
    output wire irq_active,
    output wire [3:0] irq_vec,
    output wire storm,
    output wire acked,
    output wire [1:0] sync_idx,
    output wire [4:0] set_evts,
    output wire [3:0] w1c_evts,
    output wire [3:0] err_count,
    output wire level_any
);

    ips_gpio_irq_bank u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .pin_in(pin_in),
        .bus_addr(bus_addr),
        .bus_we(bus_we),
        .bus_wdata(bus_wdata),
        .bus_ack(bus_ack),
        .bus_rdata(bus_rdata),
        .pend(pend),
        .pin_out(pin_out),
        .irq_active(irq_active),
        .irq_vec(irq_vec),
        .storm(storm),
        .acked(acked),
        .sync_idx(sync_idx),
        .set_evts(set_evts),
        .w1c_evts(w1c_evts),
        .err_count(err_count),
        .level_any(level_any)
    );

endmodule
