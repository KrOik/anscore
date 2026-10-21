// ---------------------------------------------------------------------------
// gw2a_ips_secded64_ecc : packaged, licensable wrapper for the ips_secded64_ecc core.
// Family path.  SECDED(72,64) Hamstone encoder and decoder: corrects single-bit, detects double-bit, reports syndrome
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_secded64_ecc (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire mode,
    input wire [71:0] code_in,
    output wire done,
    output wire ce,
    output wire ue,
    output wire [63:0] data_out,
    output wire [7:0] chk_out,
    output wire [71:0] code_out,
    output wire [7:0] syndrome,
    output wire [3:0] syn_wt,
    output wire [6:0] err_pos,
    output wire [3:0] ce_cnt,
    output wire [3:0] ue_cnt,
    output wire [1:0] err_sticky
);

    ips_secded64_ecc u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .mode(mode),
        .code_in(code_in),
        .done(done),
        .ce(ce),
        .ue(ue),
        .data_out(data_out),
        .chk_out(chk_out),
        .code_out(code_out),
        .syndrome(syndrome),
        .syn_wt(syn_wt),
        .err_pos(err_pos),
        .ce_cnt(ce_cnt),
        .ue_cnt(ue_cnt),
        .err_sticky(err_sticky)
    );

endmodule
