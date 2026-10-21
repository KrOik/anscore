// ---------------------------------------------------------------------------
// gw2a_ips_isqrt_iter : packaged, licensable wrapper for the ips_isqrt_iter core.
// Family arith.  Digit-by-digit integer square root, 16 iterations, returns root and residual
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_isqrt_iter #(
    parameter ITER = 16,
    parameter FRAST = 7
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire signed [15:0] radicand,
    output wire [15:0] root,
    output wire [9:0] irem,
    output wire exact,
    output wire invalid,
    output wire valid,
    output wire busy,
    output wire [4:0] iter,
    output wire [3:0] stage
);

    ips_isqrt_iter #(
        .ITER(ITER),
        .FRAST(FRAST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .radicand(radicand),
        .root(root),
        .irem(irem),
        .exact(exact),
        .invalid(invalid),
        .valid(valid),
        .busy(busy),
        .iter(iter),
        .stage(stage)
    );

endmodule
