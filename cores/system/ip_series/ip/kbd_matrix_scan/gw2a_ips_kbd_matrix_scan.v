// ---------------------------------------------------------------------------
// gw2a_ips_kbd_matrix_scan : packaged, licensable wrapper for the ips_kbd_matrix_scan core.
// Family ctrl.  8x8 keyboard matrix scanner with key-roll-over capture and ghost detection
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_kbd_matrix_scan #(
    parameter CODE_BASE = 8'h21,
    parameter NKR_MAX = 4'd6,
    parameter ROW_POL = 8'h00
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [7:0] row_in,
    output wire [7:0] col_drv,
    output wire [3:0] scan_col,
    output wire [1:0] phase,
    output wire [7:0] key_code,
    output wire code_valid,
    output wire [6:0] code_slot,
    output wire [6:0] key_count,
    output wire press_col,
    output wire rel_col,
    output wire [7:0] press_code,
    output wire [7:0] rel_code,
    output wire [5:0] press_cnt,
    output wire [5:0] rel_cnt,
    output wire ghost_flag,
    output wire [7:0] phantom_code,
    output wire nk_over,
    output wire stuck_flag,
    output wire report_done,
    output wire [7:0] scan_cnt
);

    ips_kbd_matrix_scan #(
        .CODE_BASE(CODE_BASE),
        .NKR_MAX(NKR_MAX),
        .ROW_POL(ROW_POL)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .row_in(row_in),
        .col_drv(col_drv),
        .scan_col(scan_col),
        .phase(phase),
        .key_code(key_code),
        .code_valid(code_valid),
        .code_slot(code_slot),
        .key_count(key_count),
        .press_col(press_col),
        .rel_col(rel_col),
        .press_code(press_code),
        .rel_code(rel_code),
        .press_cnt(press_cnt),
        .rel_cnt(rel_cnt),
        .ghost_flag(ghost_flag),
        .phantom_code(phantom_code),
        .nk_over(nk_over),
        .stuck_flag(stuck_flag),
        .report_done(report_done),
        .scan_cnt(scan_cnt)
    );

endmodule
