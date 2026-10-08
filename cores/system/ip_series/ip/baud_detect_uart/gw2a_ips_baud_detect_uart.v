// ---------------------------------------------------------------------------
// gw2a_ips_baud_detect_uart : packaged, licensable wrapper for the ips_baud_detect_uart core.
// Family iface.  UART receive-side baud estimator measuring the 0-bit run length and deriving an integer oversample tick
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_baud_detect_uart #(
    parameter OS_SHIFT = 2,
    parameter RUN_MIN = 8'd12,
    parameter RUN_MAX = 8'd20,
    parameter LOCK_N = 3'd3,
    parameter TOL = 8'd3,
    parameter LEN_MAX = 8'd60,
    parameter GLITCH = 8'd3
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire tick,
    input wire rx,
    input wire restart,
    output wire locked,
    output wire [1:0] state,
    output wire [7:0] len,
    output wire [7:0] meas,
    output wire [7:0] bit_len,
    output wire [7:0] min_len,
    output wire [7:0] max_len,
    output wire [7:0] tick_est,
    output wire [2:0] agree,
    output wire [5:0] run_count,
    output wire [3:0] lock_count,
    output wire [3:0] unlock_count,
    output wire [3:0] hold_count,
    output wire [3:0] err_count,
    output wire rx_q,
    output wire run_valid,
    output wire lock_valid,
    output wire glitch_sticky,
    output wire range_sticky
);

    ips_baud_detect_uart #(
        .OS_SHIFT(OS_SHIFT),
        .RUN_MIN(RUN_MIN),
        .RUN_MAX(RUN_MAX),
        .LOCK_N(LOCK_N),
        .TOL(TOL),
        .LEN_MAX(LEN_MAX),
        .GLITCH(GLITCH)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .tick(tick),
        .rx(rx),
        .restart(restart),
        .locked(locked),
        .state(state),
        .len(len),
        .meas(meas),
        .bit_len(bit_len),
        .min_len(min_len),
        .max_len(max_len),
        .tick_est(tick_est),
        .agree(agree),
        .run_count(run_count),
        .lock_count(lock_count),
        .unlock_count(unlock_count),
        .hold_count(hold_count),
        .err_count(err_count),
        .rx_q(rx_q),
        .run_valid(run_valid),
        .lock_valid(lock_valid),
        .glitch_sticky(glitch_sticky),
        .range_sticky(range_sticky)
    );

endmodule
