// ---------------------------------------------------------------------------
// gw2a_ips_debounce_matrix : packaged, licensable wrapper for the ips_debounce_matrix core.
// Family ctrl.  N-input per-key debounce with stable-count and change-event ledger word
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_debounce_matrix #(
    parameter KEY_N = 4'd8,
    parameter SAMPLE_DIV = 3'd1,
    parameter STABLE_MAX = 4'd3,
    parameter LED_SLOTS = 4'd6
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire [11:0] raw_in,
    input wire clear_led,
    output wire [11:0] key_state,
    output wire [11:0] key_change,
    output wire [11:0] chg_sticky,
    output wire [47:0] cnt_flat,
    output wire sample_tick,
    output wire event_valid,
    output wire [7:0] event_rec,
    output wire [63:0] ledger,
    output wire [3:0] led_count,
    output wire [2:0] seq_tag,
    output wire led_full,
    output wire [3:0] drop_count,
    output wire [3:0] multi_count,
    output wire multi_sticky,
    output wire [3:0] bounce_count,
    output wire [7:0] event_total,
    output wire [7:0] tick_total
);

    ips_debounce_matrix #(
        .KEY_N(KEY_N),
        .SAMPLE_DIV(SAMPLE_DIV),
        .STABLE_MAX(STABLE_MAX),
        .LED_SLOTS(LED_SLOTS)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .raw_in(raw_in),
        .clear_led(clear_led),
        .key_state(key_state),
        .key_change(key_change),
        .chg_sticky(chg_sticky),
        .cnt_flat(cnt_flat),
        .sample_tick(sample_tick),
        .event_valid(event_valid),
        .event_rec(event_rec),
        .ledger(ledger),
        .led_count(led_count),
        .seq_tag(seq_tag),
        .led_full(led_full),
        .drop_count(drop_count),
        .multi_count(multi_count),
        .multi_sticky(multi_sticky),
        .bounce_count(bounce_count),
        .event_total(event_total),
        .tick_total(tick_total)
    );

endmodule
