// ============================================================================
// gw2a_cnn_sdp_ram -- proprietary IP wrapper (Cognition dev kit, GW2A-18C)
// Core: sdp_ram  (adapted from CNN_FPGA rtl_pds, src/sdp_ram.v)
// Board-validated: unit(s) 4 (RAM), digest 2339D078, bitstream m00ff
// Port arrays are flattened: element i occupies bits [i*W +: W].
// ============================================================================
module gw2a_cnn_sdp_ram #(
    parameter WIDTH = 21,
    parameter DEPTH = 128,
    parameter AW = (DEPTH > 1) ? $clog2(DEPTH) : 1  // address width
)(
    input  wire clk,
    input  wire clk_en,
    input  wire  we,  // write enable (needs clk_en)
    input  wire [AW-1:0] waddr,  // write address
    input  wire [WIDTH-1:0] wdata,  // write data
    input  wire  re,  // read enable (needs clk_en)
    input  wire [AW-1:0] raddr,  // read address
    output  wire [WIDTH-1:0] q   // registered read data
);

    sdp_ram #(
        .WIDTH(WIDTH),
        .DEPTH(DEPTH)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .we(we),
        .waddr(waddr),
        .wdata(wdata),
        .re(re),
        .raddr(raddr),
        .q(q)
    );

endmodule
