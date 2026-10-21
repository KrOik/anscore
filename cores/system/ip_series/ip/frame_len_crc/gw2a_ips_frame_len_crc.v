// ---------------------------------------------------------------------------
// gw2a_ips_frame_len_crc : packaged, licensable wrapper for the ips_frame_len_crc core.
// Family pkt.  Length-prefixed packet framer/deframer with embedded CRC and malformed-frame rejection counter
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_frame_len_crc #(
    parameter CRC_POLY = 8'h07,
    parameter CRC_SEED = 8'hFF,
    parameter MAX_LEN = 20
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire in_valid,
    input wire in_start,
    input wire in_last,
    input wire [7:0] in_byte,
    output wire in_ready,
    output wire out_valid,
    output wire out_ok,
    output wire [7:0] out_len,
    output wire [7:0] out_crc,
    output wire [7:0] out_recv_crc,
    output wire [7:0] crc_run,
    output wire [3:0] err_sticky,
    output wire [3:0] cnt_good,
    output wire [3:0] cnt_bad_crc,
    output wire [3:0] cnt_over_len,
    output wire [3:0] cnt_trunc,
    output wire [3:0] cnt_restart,
    output wire [4:0] cnt_sat
);

    ips_frame_len_crc #(
        .CRC_POLY(CRC_POLY),
        .CRC_SEED(CRC_SEED),
        .MAX_LEN(MAX_LEN)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .in_valid(in_valid),
        .in_start(in_start),
        .in_last(in_last),
        .in_byte(in_byte),
        .in_ready(in_ready),
        .out_valid(out_valid),
        .out_ok(out_ok),
        .out_len(out_len),
        .out_crc(out_crc),
        .out_recv_crc(out_recv_crc),
        .crc_run(crc_run),
        .err_sticky(err_sticky),
        .cnt_good(cnt_good),
        .cnt_bad_crc(cnt_bad_crc),
        .cnt_over_len(cnt_over_len),
        .cnt_trunc(cnt_trunc),
        .cnt_restart(cnt_restart),
        .cnt_sat(cnt_sat)
    );

endmodule
