// ---------------------------------------------------------------------------
// gw2a_ips_ram_sp_1p : packaged, licensable wrapper for the ips_ram_sp_1p core.
// Family path.  Single-port RAM wrapper with byte write enable, optional registered read and BSRAM inference contract
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_ram_sp_1p #(
    parameter WIDTH = 32,
    parameter ADDR_BITS = 5,
    parameter DEPTH = 1 << ADDR_BITS,
    parameter OUT_REG = 1,
    parameter BYTES = WIDTH / 8,
    parameter MATCH_CONST = 32'hA5A5_5A5A
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire ce,
    input wire we,
    input wire [WIDTH/8-1:0] be,
    input wire [ADDR_BITS-1:0] waddr,
    input wire [ADDR_BITS-1:0] raddr,
    input wire top_sel,
    input wire [WIDTH-1:0] wdata,
    output wire [WIDTH-1:0] rdata,
    output wire [ADDR_BITS-1:0] raddr_q,
    output wire [7:0] hit_count,
    output wire [7:0] guard_count,
    output wire [15:0] addr_count,
    output wire error_sticky
);

    ips_ram_sp_1p #(
        .WIDTH(WIDTH),
        .ADDR_BITS(ADDR_BITS),
        .DEPTH(DEPTH),
        .OUT_REG(OUT_REG),
        .BYTES(BYTES),
        .MATCH_CONST(MATCH_CONST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .ce(ce),
        .we(we),
        .be(be),
        .waddr(waddr),
        .raddr(raddr),
        .top_sel(top_sel),
        .wdata(wdata),
        .rdata(rdata),
        .raddr_q(raddr_q),
        .hit_count(hit_count),
        .guard_count(guard_count),
        .addr_count(addr_count),
        .error_sticky(error_sticky)
    );

endmodule
