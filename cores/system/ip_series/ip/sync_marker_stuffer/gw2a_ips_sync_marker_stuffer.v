// ---------------------------------------------------------------------------
// gw2a_ips_sync_marker_stuffer : packaged, licensable wrapper for the ips_sync_marker_stuffer core.
// Family pkt.  Inserts and removes a byte-oriented sync marker with escape/unescape transparency
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_sync_marker_stuffer #(
    parameter SYNC_BYTE = 8'h7A,
    parameter ESC_BYTE = 8'h7D,
    parameter XOR_MASK = 8'h20,
    parameter FRAME_ESC_MAX = 8'd24
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire mode,
    input wire in_valid,
    input wire [7:0] in_byte,
    input wire sync_req,
    output wire in_ready,
    output wire out_valid,
    output wire out_sof,
    output wire [7:0] out_byte,
    input wire out_ready,
    output wire [7:0] cnt_in,
    output wire [7:0] cnt_out,
    output wire [7:0] cnt_esc,
    output wire [7:0] cnt_sync,
    output wire [3:0] cnt_spur,
    output wire [2:0] queue_level,
    output wire [7:0] frame_esc,
    output wire [3:0] err_sticky,
    output wire [4:0] cnt_sat
);

    ips_sync_marker_stuffer #(
        .SYNC_BYTE(SYNC_BYTE),
        .ESC_BYTE(ESC_BYTE),
        .XOR_MASK(XOR_MASK),
        .FRAME_ESC_MAX(FRAME_ESC_MAX)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .mode(mode),
        .in_valid(in_valid),
        .in_byte(in_byte),
        .sync_req(sync_req),
        .in_ready(in_ready),
        .out_valid(out_valid),
        .out_sof(out_sof),
        .out_byte(out_byte),
        .out_ready(out_ready),
        .cnt_in(cnt_in),
        .cnt_out(cnt_out),
        .cnt_esc(cnt_esc),
        .cnt_sync(cnt_sync),
        .cnt_spur(cnt_spur),
        .queue_level(queue_level),
        .frame_esc(frame_esc),
        .err_sticky(err_sticky),
        .cnt_sat(cnt_sat)
    );

endmodule
