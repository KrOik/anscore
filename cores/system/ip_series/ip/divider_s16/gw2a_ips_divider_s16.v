// ---------------------------------------------------------------------------
// gw2a_ips_divider_s16 : packaged, licensable wrapper for the ips_divider_s16 core.
// Family arith.  Iterative restoring signed 16/16 fixed-point divide, quotient plus remainder and divide-by-zero flag
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_divider_s16 #(
    parameter ITER = 16,
    parameter PIPE = 4
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire signed [15:0] dividend,
    input wire signed [15:0] divisor,
    output wire signed [16:0] quotient,
    output wire signed [15:0] remainder,
    output wire divz,
    output wire valid,
    output wire busy,
    output wire [4:0] iter,
    output wire [3:0] stage
);

    ips_divider_s16 #(
        .ITER(ITER),
        .PIPE(PIPE)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .dividend(dividend),
        .divisor(divisor),
        .quotient(quotient),
        .remainder(remainder),
        .divz(divz),
        .valid(valid),
        .busy(busy),
        .iter(iter),
        .stage(stage)
    );

endmodule
