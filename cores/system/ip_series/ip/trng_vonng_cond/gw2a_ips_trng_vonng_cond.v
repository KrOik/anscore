// ---------------------------------------------------------------------------
// gw2a_ips_trng_vonng_cond : packaged, licensable wrapper for the ips_trng_vonng_cond core.
// Family sec.  Ring-oscillator entropy source collector with von Neumann conditioning and continuous health tests
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_trng_vonng_cond #(
    parameter CNT_BITS = 12,
    parameter SYNC_STAGES = 2,
    parameter STUCK_LIMIT = 12'd64
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire cond_start,
    input wire cond_run,
    input wire src_bit,
    output wire out_bit,
    output wire out_valid,
    output wire stuck_alarm,
    output wire pair_pending,
    output wire [CNT_BITS-1:0] out_bit_cnt,
    output wire [CNT_BITS-1:0] disc_pair_cnt,
    output wire [CNT_BITS-1:0] bit_cnt
);

    ips_trng_vonng_cond #(
        .CNT_BITS(CNT_BITS),
        .SYNC_STAGES(SYNC_STAGES),
        .STUCK_LIMIT(STUCK_LIMIT)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .cond_start(cond_start),
        .cond_run(cond_run),
        .src_bit(src_bit),
        .out_bit(out_bit),
        .out_valid(out_valid),
        .stuck_alarm(stuck_alarm),
        .pair_pending(pair_pending),
        .out_bit_cnt(out_bit_cnt),
        .disc_pair_cnt(disc_pair_cnt),
        .bit_cnt(bit_cnt)
    );

endmodule
