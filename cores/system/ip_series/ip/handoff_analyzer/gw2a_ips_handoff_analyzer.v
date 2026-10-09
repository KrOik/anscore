// ---------------------------------------------------------------------------
// gw2a_ips_handoff_analyzer : packaged, licensable wrapper for the ips_handoff_analyzer core.
// Family obs.  Valid/ready interface analyser: max handoff edges, dead cycles, underrun and overrun ledger per burst
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_handoff_analyzer (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire win,
    input wire valid,
    input wire ready,
    output wire [7:0] hnd,
    output wire [7:0] dead,
    output wire [7:0] stall,
    output wire [7:0] mxstall,
    output wire [7:0] undr,
    output wire [7:0] ovr,
    output wire [7:0] flags,
    output wire [7:0] lhnd,
    output wire [7:0] ldead,
    output wire [7:0] lmxstall,
    output wire [7:0] lundr,
    output wire [7:0] lovr,
    output wire [7:0] lflags,
    output wire [7:0] burst_n,
    output wire [7:0] top_hnd,
    output wire busy,
    output wire done,
    output wire opening_r
);

    ips_handoff_analyzer u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .win(win),
        .valid(valid),
        .ready(ready),
        .hnd(hnd),
        .dead(dead),
        .stall(stall),
        .mxstall(mxstall),
        .undr(undr),
        .ovr(ovr),
        .flags(flags),
        .lhnd(lhnd),
        .ldead(ldead),
        .lmxstall(lmxstall),
        .lundr(lundr),
        .lovr(lovr),
        .lflags(lflags),
        .burst_n(burst_n),
        .top_hnd(top_hnd),
        .busy(busy),
        .done(done),
        .opening_r(opening_r)
    );

endmodule
