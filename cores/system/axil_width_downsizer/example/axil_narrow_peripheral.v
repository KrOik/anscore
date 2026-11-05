// SPDX-License-Identifier: Apache-2.0
// Example: aligned 32-bit AXI-Lite host to 8-bit addressed peripheral.
`default_nettype none
module axil_narrow_peripheral(
    input wire clk, input wire rst,
    input wire [16-1:0] s_awaddr, input wire [2:0] s_awprot,
    input wire s_awvalid, output wire s_awready,
    input wire [32-1:0] s_wdata, input wire [32/8-1:0] s_wstrb,
    input wire s_wvalid, output wire s_wready,
    output wire [1:0] s_bresp, output wire s_bvalid, input wire s_bready,
    input wire [16-1:0] s_araddr, input wire [2:0] s_arprot,
    input wire s_arvalid, output wire s_arready,
    output wire [32-1:0] s_rdata, output wire [1:0] s_rresp,
    output wire s_rvalid, input wire s_rready,
    output wire [16-1:0] m_awaddr, output wire [2:0] m_awprot,
    output wire m_awvalid, input wire m_awready,
    output wire [8-1:0] m_wdata, output wire [8/8-1:0] m_wstrb,
    output wire m_wvalid, input wire m_wready,
    input wire [1:0] m_bresp, input wire m_bvalid, output wire m_bready,
    output wire [16-1:0] m_araddr, output wire [2:0] m_arprot,
    output wire m_arvalid, input wire m_arready,
    input wire [8-1:0] m_rdata, input wire [1:0] m_rresp,
    input wire m_rvalid, output wire m_rready
);
    axil_width_downsizer adapter (.*);
endmodule
`default_nettype wire
