// ---------------------------------------------------------------------------
// gw2a_ips_perf_event_ctr : packaged, licensable wrapper for the ips_perf_event_ctr core.
// Family obs.  Eight programmable event counters with strobe AND/OR mux, snapshot and overflow capture
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_perf_event_ctr (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire en,
    input wire [3:0] strb,
    input wire cfg_we,
    input wire [2:0] cfg_idx,
    input wire [7:0] cfg_amask,
    input wire [7:0] cfg_omask,
    input wire cnt_we,
    input wire [2:0] cnt_widx,
    input wire [7:0] cnt_wval,
    input wire snap,
    input wire clr,
    input wire ov_clr,
    output wire [63:0] cnt,
    output wire [63:0] shd,
    output wire [7:0] ev,
    output wire [7:0] wrap,
    output wire [7:0] ovf,
    output wire [7:0] ov_seq,
    output wire [3:0] snap_n
);

    ips_perf_event_ctr u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .en(en),
        .strb(strb),
        .cfg_we(cfg_we),
        .cfg_idx(cfg_idx),
        .cfg_amask(cfg_amask),
        .cfg_omask(cfg_omask),
        .cnt_we(cnt_we),
        .cnt_widx(cnt_widx),
        .cnt_wval(cnt_wval),
        .snap(snap),
        .clr(clr),
        .ov_clr(ov_clr),
        .cnt(cnt),
        .shd(shd),
        .ev(ev),
        .wrap(wrap),
        .ovf(ovf),
        .ov_seq(ov_seq),
        .snap_n(snap_n)
    );

endmodule
