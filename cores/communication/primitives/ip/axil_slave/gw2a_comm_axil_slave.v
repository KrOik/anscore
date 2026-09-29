// ============================================================================
// gw2a_comm_axil_slave -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: axil_slave  (src/axil_slave.v)
// Board-validated: selftest unit 3 (AXIL), digest 9B3A6985,
//   evidence doc/board_uart_*.txt
// AXI4-Lite slave: 16x32-bit register bank, full ready/valid handshake,
// byte strobes, SLVERR on unaligned/out-of-range addresses.
// ============================================================================
module gw2a_comm_axil_slave (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clk_en,             // step enable; tie 1 for full rate
    input  wire        awvalid,
    output wire        awready,
    input  wire [7:0]  awaddr,
    input  wire        wvalid,
    output wire        wready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    output wire        bvalid,
    input  wire        bready,
    output wire [1:0]  bresp,
    input  wire        arvalid,
    output wire        arready,
    input  wire [7:0]  araddr,
    output wire        rvalid,
    input  wire        rready,
    output wire [31:0] rdata,
    output wire [1:0]  rresp
);

    axil_slave u_core (
        .clk(clk),
        .rst_n(rst_n),
        .clk_en(clk_en),
        .awvalid(awvalid),
        .awready(awready),
        .awaddr(awaddr),
        .wvalid(wvalid),
        .wready(wready),
        .wdata(wdata),
        .wstrb(wstrb),
        .bvalid(bvalid),
        .bready(bready),
        .bresp(bresp),
        .arvalid(arvalid),
        .arready(arready),
        .araddr(araddr),
        .rvalid(rvalid),
        .rready(rready),
        .rdata(rdata),
        .rresp(rresp)
    );

endmodule
