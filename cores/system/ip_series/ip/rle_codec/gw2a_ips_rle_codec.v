// ---------------------------------------------------------------------------
// gw2a_ips_rle_codec : packaged, licensable wrapper for the ips_rle_codec core.
// Family pkt.  Run-length encode and decode over a byte stream with literal/run token packing
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_rle_codec #(
    parameter MAX_RUN = 20
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire dir,
    input wire in_valid,
    input wire in_last,
    input wire [7:0] in_byte,
    input wire out_ready,
    output wire in_ready,
    output wire busy,
    output wire out_tok_infl,
    output wire out_valid,
    output wire [7:0] out_byte,
    output wire [7:0] run_len,
    output wire [5:0] tok_cnt,
    output wire [4:0] lit_cnt,
    output wire [4:0] run_ovf,
    output wire [4:0] tok_ovf,
    output wire [7:0] exp_cnt,
    output wire [3:0] err_proto,
    output wire [2:0] err_sticky,
    output wire [4:0] cnt_sat
);

    ips_rle_codec #(
        .MAX_RUN(MAX_RUN)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .dir(dir),
        .in_valid(in_valid),
        .in_last(in_last),
        .in_byte(in_byte),
        .out_ready(out_ready),
        .in_ready(in_ready),
        .busy(busy),
        .out_tok_infl(out_tok_infl),
        .out_valid(out_valid),
        .out_byte(out_byte),
        .run_len(run_len),
        .tok_cnt(tok_cnt),
        .lit_cnt(lit_cnt),
        .run_ovf(run_ovf),
        .tok_ovf(tok_ovf),
        .exp_cnt(exp_cnt),
        .err_proto(err_proto),
        .err_sticky(err_sticky),
        .cnt_sat(cnt_sat)
    );

endmodule
