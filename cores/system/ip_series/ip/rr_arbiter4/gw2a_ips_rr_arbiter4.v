// ---------------------------------------------------------------------------
// gw2a_ips_rr_arbiter4 : packaged, licensable wrapper for the ips_rr_arbiter4 core.
// Family ctrl.  Four-master round-robin arbiter with lock-on-grant, starvation counter and lock-step fairness
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_rr_arbiter4 #(
    parameter STARVE_LIMIT = 6'd20,
    parameter HOLD_MIN = 3'd2,
    parameter PRIO_INIT = 2'd0
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [3:0] req,
    input wire [3:0] ack,
    output wire [3:0] grant,
    output wire grant_valid,
    output wire [1:0] grant_idx,
    output wire fair_ok,
    output wire [2:0] hold_cnt,
    output wire [23:0] starve_all,
    output wire [5:0] starve_max,
    output wire [1:0] prio_ptr,
    output wire [7:0] svc_hist,
    output wire [3:0] starve_hit,
    output wire [7:0] txn_count,
    output wire [1:0] err_cause,
    output wire [3:0] err_seen
);

    ips_rr_arbiter4 #(
        .STARVE_LIMIT(STARVE_LIMIT),
        .HOLD_MIN(HOLD_MIN),
        .PRIO_INIT(PRIO_INIT)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .req(req),
        .ack(ack),
        .grant(grant),
        .grant_valid(grant_valid),
        .grant_idx(grant_idx),
        .fair_ok(fair_ok),
        .hold_cnt(hold_cnt),
        .starve_all(starve_all),
        .starve_max(starve_max),
        .prio_ptr(prio_ptr),
        .svc_hist(svc_hist),
        .starve_hit(starve_hit),
        .txn_count(txn_count),
        .err_cause(err_cause),
        .err_seen(err_seen)
    );

endmodule
