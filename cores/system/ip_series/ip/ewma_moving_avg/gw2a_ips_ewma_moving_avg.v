// ---------------------------------------------------------------------------
// gw2a_ips_ewma_moving_avg : packaged, licensable wrapper for the ips_ewma_moving_avg core.
// Family arith.  Alpha-weighted EWMA plus N-tap circular moving average with warm-up correctness
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_ewma_moving_avg #(
    parameter NTAP = 8,
    parameter KSHIFT = 3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire signed [7:0] x_in,
    output wire signed [7:0] ewma,
    output wire signed [7:0] mean,
    output wire signed [10:0] msum,
    output wire [3:0] rem,
    output wire [3:0] frac,
    output wire stall,
    output wire valid,
    output wire busy,
    output wire [2:0] stage,
    output wire [3:0] wptr,
    output wire [3:0] cnt,
    output wire [4:0] it
);

    ips_ewma_moving_avg #(
        .NTAP(NTAP),
        .KSHIFT(KSHIFT)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .x_in(x_in),
        .ewma(ewma),
        .mean(mean),
        .msum(msum),
        .rem(rem),
        .frac(frac),
        .stall(stall),
        .valid(valid),
        .busy(busy),
        .stage(stage),
        .wptr(wptr),
        .cnt(cnt),
        .it(it)
    );

endmodule
