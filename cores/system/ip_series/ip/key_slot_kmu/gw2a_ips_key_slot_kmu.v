// ---------------------------------------------------------------------------
// gw2a_ips_key_slot_kmu : packaged, licensable wrapper for the ips_key_slot_kmu core.
// Family sec.  Eight key slots with write-once load, access-permission binding and zeroisation on violation
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_key_slot_kmu #(
    parameter SLOTS = 8,
    parameter WORD_BITS = 16,
    parameter KEY_SALT = 16'hA534
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire ld_valid,
    input wire lock_req,
    input wire unlock_req,
    input wire rd_req,
    input wire clr_req,
    input wire [$clog2(SLOTS)-1:0] slot,
    input wire [WORD_BITS-1:0] ld_data,
    input wire [WORD_BITS-1:0] attestation,
    input wire [3:0] ld_priv,
    input wire [3:0] att_priv,
    input wire [3:0] rd_priv,
    output wire [WORD_BITS-1:0] rd_data,
    output wire rd_valid,
    output wire rd_denied,
    output wire [SLOTS-1:0] locked,
    output wire [SLOTS-1:0] loaded,
    output wire [SLOTS-1:0] poisoned,
    output wire [SLOTS-1:0] slot_tamper,
    output wire [7:0] tamper_cnt,
    output wire [2:0] err_code,
    output wire err_any
);

    ips_key_slot_kmu #(
        .SLOTS(SLOTS),
        .WORD_BITS(WORD_BITS),
        .KEY_SALT(KEY_SALT)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .ld_valid(ld_valid),
        .lock_req(lock_req),
        .unlock_req(unlock_req),
        .rd_req(rd_req),
        .clr_req(clr_req),
        .slot(slot),
        .ld_data(ld_data),
        .attestation(attestation),
        .ld_priv(ld_priv),
        .att_priv(att_priv),
        .rd_priv(rd_priv),
        .rd_data(rd_data),
        .rd_valid(rd_valid),
        .rd_denied(rd_denied),
        .locked(locked),
        .loaded(loaded),
        .poisoned(poisoned),
        .slot_tamper(slot_tamper),
        .tamper_cnt(tamper_cnt),
        .err_code(err_code),
        .err_any(err_any)
    );

endmodule
