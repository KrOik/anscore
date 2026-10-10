// ---------------------------------------------------------------------------
// gw2a_ips_ram_dp_1w2r : packaged, licensable wrapper for the ips_ram_dp_1w2r core.
// Family path.  One-write two-read banked RAM giving three logical ports from two physical dual-ports without collision
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_ram_dp_1w2r #(
    parameter WIDTH = 32,
    parameter ADDR_BITS = 4,
    parameter DEPTH = 1 << ADDR_BITS,
    parameter OUT_REG = 1,
    parameter GUARD_SHIFT = 8,
    parameter MATCH_CONST = 32'hA5A5_5A5A
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire wr_en,
    input wire [ADDR_BITS-1:0] waddr,
    input wire [WIDTH-1:0] wdata,
    input wire r0_en,
    input wire [ADDR_BITS-1:0] r0_addr,
    input wire r0_top,
    input wire r1_en,
    input wire [ADDR_BITS-1:0] r1_addr,
    input wire r1_top,
    output wire [WIDTH-1:0] r0_data,
    output wire [ADDR_BITS-1:0] r0_addr_q,
    output wire r0_valid,
    output wire [WIDTH-1:0] r1_data,
    output wire [ADDR_BITS-1:0] r1_addr_q,
    output wire r1_valid,
    output wire [7:0] hit_count,
    output wire [7:0] guard_count,
    output wire [15:0] read_count,
    output wire [7:0] write_count,
    output wire [7:0] collide_count,
    output wire conflict_sticky
);

    ips_ram_dp_1w2r #(
        .WIDTH(WIDTH),
        .ADDR_BITS(ADDR_BITS),
        .DEPTH(DEPTH),
        .OUT_REG(OUT_REG),
        .GUARD_SHIFT(GUARD_SHIFT),
        .MATCH_CONST(MATCH_CONST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .wr_en(wr_en),
        .waddr(waddr),
        .wdata(wdata),
        .r0_en(r0_en),
        .r0_addr(r0_addr),
        .r0_top(r0_top),
        .r1_en(r1_en),
        .r1_addr(r1_addr),
        .r1_top(r1_top),
        .r0_data(r0_data),
        .r0_addr_q(r0_addr_q),
        .r0_valid(r0_valid),
        .r1_data(r1_data),
        .r1_addr_q(r1_addr_q),
        .r1_valid(r1_valid),
        .hit_count(hit_count),
        .guard_count(guard_count),
        .read_count(read_count),
        .write_count(write_count),
        .collide_count(collide_count),
        .conflict_sticky(conflict_sticky)
    );

endmodule
