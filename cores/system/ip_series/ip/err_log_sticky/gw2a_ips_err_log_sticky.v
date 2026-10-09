// ---------------------------------------------------------------------------
// gw2a_ips_err_log_sticky : packaged, licensable wrapper for the ips_err_log_sticky core.
// Family obs.  First-N error capture with timestamp, source code and overflow-protected ring log
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_err_log_sticky #(
    parameter TS_W = 10,
    parameter SRC_W = 4,
    parameter LOG_SLOTS = 2,
    parameter OVF_W = 6
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire err_a_valid,
    input wire [SRC_W-1:0] err_a_src,
    input wire err_b_valid,
    input wire [SRC_W-1:0] err_b_src,
    input wire rd_en,
    input wire clr_all,
    input wire stk_clr,
    output wire [TS_W-1:0] ts_count,
    output wire [OVF_W-1:0] ovf_count,
    output wire [3:0] drop_count,
    output wire [7:0] stk_word,
    output wire [(1 << SRC_W) - 1 : 0] src_sticky,
    output wire [TS_W + SRC_W - 1 : 0] rd_record,
    output wire [TS_W-1:0] rd_ts,
    output wire [SRC_W-1:0] rd_src,
    output wire [LOG_SLOTS-1:0] wr_ptr,
    output wire [LOG_SLOTS-1:0] rd_ptr,
    output wire [LOG_SLOTS:0] n_unread,
    output wire log_full,
    output wire log_empty,
    output wire rd_valid,
    output wire [LOG_SLOTS-1:0] pop_slot,
    output wire [(1 << LOG_SLOTS) - 1 : 0] log_used,
    output wire ovf_sticky,
    output wire dup_sticky,
    output wire full_sticky,
    output wire seen_sticky,
    output wire epop_sticky,
    output wire [((TS_W + SRC_W) << LOG_SLOTS) - 1 : 0] log_flat
);

    ips_err_log_sticky #(
        .TS_W(TS_W),
        .SRC_W(SRC_W),
        .LOG_SLOTS(LOG_SLOTS),
        .OVF_W(OVF_W)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .err_a_valid(err_a_valid),
        .err_a_src(err_a_src),
        .err_b_valid(err_b_valid),
        .err_b_src(err_b_src),
        .rd_en(rd_en),
        .clr_all(clr_all),
        .stk_clr(stk_clr),
        .ts_count(ts_count),
        .ovf_count(ovf_count),
        .drop_count(drop_count),
        .stk_word(stk_word),
        .src_sticky(src_sticky),
        .rd_record(rd_record),
        .rd_ts(rd_ts),
        .rd_src(rd_src),
        .wr_ptr(wr_ptr),
        .rd_ptr(rd_ptr),
        .n_unread(n_unread),
        .log_full(log_full),
        .log_empty(log_empty),
        .rd_valid(rd_valid),
        .pop_slot(pop_slot),
        .log_used(log_used),
        .ovf_sticky(ovf_sticky),
        .dup_sticky(dup_sticky),
        .full_sticky(full_sticky),
        .seen_sticky(seen_sticky),
        .epop_sticky(epop_sticky),
        .log_flat(log_flat)
    );

endmodule
