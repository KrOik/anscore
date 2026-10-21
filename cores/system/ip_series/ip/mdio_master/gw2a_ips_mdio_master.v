// ---------------------------------------------------------------------------
// gw2a_ips_mdio_master : packaged, licensable wrapper for the ips_mdio_master core.
// Family iface.  Ethernet PHY MDIO master, preamble/start/op/PA/PHYAD/REGAD/TURN/data FSM with turnaround tri-state
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_mdio_master #(
    parameter PRE_BITS = 32,
    parameter TMO_LIMIT = 3,
    parameter DATA_BITS = 16
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire start,
    input wire rnw,
    input wire [4:0] phy_addr,
    input wire [DATA_BITS-1:0] wdata,
    inout wire mdio,
    output wire mdc,
    output wire [2:0] o_state,
    output wire [5:0] o_bc,
    output wire [6:0] o_pos,
    output wire [2:0] o_waits,
    output wire [DATA_BITS-1:0] o_rdata,
    output wire [DATA_BITS-1:0] o_sh,
    output wire [8:0] o_cmd,
    output wire [7:0] o_txn,
    output wire [3:0] o_err_to,
    output wire o_own,
    output wire o_busy,
    output wire o_lo
);

    ips_mdio_master #(
        .PRE_BITS(PRE_BITS),
        .TMO_LIMIT(TMO_LIMIT),
        .DATA_BITS(DATA_BITS)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .start(start),
        .rnw(rnw),
        .phy_addr(phy_addr),
        .wdata(wdata),
        .mdio(mdio),
        .mdc(mdc),
        .o_state(o_state),
        .o_bc(o_bc),
        .o_pos(o_pos),
        .o_waits(o_waits),
        .o_rdata(o_rdata),
        .o_sh(o_sh),
        .o_cmd(o_cmd),
        .o_txn(o_txn),
        .o_err_to(o_err_to),
        .o_own(o_own),
        .o_busy(o_busy),
        .o_lo(o_lo)
    );

endmodule
