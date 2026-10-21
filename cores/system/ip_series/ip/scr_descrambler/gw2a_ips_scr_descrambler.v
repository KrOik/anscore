// ---------------------------------------------------------------------------
// gw2a_ips_scr_descrambler : packaged, licensable wrapper for the ips_scr_descrambler core.
// Family path.  Self-synchronising additive scrambler/descrambler pair over a 43-bit LFSR with error-multiplication bound
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_scr_descrambler #(
    parameter TAP_MASK = 43'h40000000001,
    parameter SEED = 43'h1A7F0C3D5E9,
    parameter BURST_WIN = 7'd44,
    parameter ERR_CAP = 8'hFF,
    parameter ONE_CAP = 8'hFF,
    parameter BURST_CAP = 4'hF
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire start,
    input wire data_in,
    input wire chan_in,
    input wire chan_bad,
    input wire restart,
    input wire [42:0] seed_in,
    output wire scr_raw,
    output wire desc_raw,
    output wire done,
    output wire scr_bit,
    output wire desc_bit,
    output wire [42:0] scr_state,
    output wire [42:0] desc_state,
    output wire [7:0] chan_err,
    output wire [7:0] err_tot,
    output wire [7:0] scr_ones,
    output wire [3:0] burst_tot,
    output wire [3:0] burst_prop,
    output wire [3:0] burst_max,
    output wire [3:0] prop_max,
    output wire [6:0] win,
    output wire [6:0] sync_pos,
    output wire [6:0] resync_pos,
    output wire [2:0] err_sticky
);

    ips_scr_descrambler #(
        .TAP_MASK(TAP_MASK),
        .SEED(SEED),
        .BURST_WIN(BURST_WIN),
        .ERR_CAP(ERR_CAP),
        .ONE_CAP(ONE_CAP),
        .BURST_CAP(BURST_CAP)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .start(start),
        .data_in(data_in),
        .chan_in(chan_in),
        .chan_bad(chan_bad),
        .restart(restart),
        .seed_in(seed_in),
        .scr_raw(scr_raw),
        .desc_raw(desc_raw),
        .done(done),
        .scr_bit(scr_bit),
        .desc_bit(desc_bit),
        .scr_state(scr_state),
        .desc_state(desc_state),
        .chan_err(chan_err),
        .err_tot(err_tot),
        .scr_ones(scr_ones),
        .burst_tot(burst_tot),
        .burst_prop(burst_prop),
        .burst_max(burst_max),
        .prop_max(prop_max),
        .win(win),
        .sync_pos(sync_pos),
        .resync_pos(resync_pos),
        .err_sticky(err_sticky)
    );

endmodule
