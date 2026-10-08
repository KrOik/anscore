// ---------------------------------------------------------------------------
// gw2a_ips_booth_mult_s16 : packaged, licensable wrapper for the ips_booth_mult_s16 core.
// Family arith.  Signed 16x16 Booth multiplier, 4-stage pipelined, 2's complement product with overflow flag
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_booth_mult_s16 #(
    parameter ITER = 8,
    parameter PIPE = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire signed [15:0] operand_a,
    input wire signed [15:0] operand_b,
    output wire signed [31:0] product,
    output wire ovf,
    output wire valid,
    output wire busy,
    output wire [3:0] stage,
    output wire [3:0] ppc,
    output wire [7:0] err_start
);

    ips_booth_mult_s16 #(
        .ITER(ITER),
        .PIPE(PIPE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .operand_a(operand_a),
        .operand_b(operand_b),
        .product(product),
        .ovf(ovf),
        .valid(valid),
        .busy(busy),
        .stage(stage),
        .ppc(ppc),
        .err_start(err_start)
    );

endmodule
