// ---------------------------------------------------------------------------
// gw2a_ips_rtc_calendar : packaged, licensable wrapper for the ips_rtc_calendar core.
// Family ctrl.  Prescaler plus civil-time counter with month lengths, leap-year rule and alarm match
// Gowin GW2A-18C / Sipeed Tang Primer 20K flow.  See ip_manifest.json.
// ---------------------------------------------------------------------------
module gw2a_ips_rtc_calendar #(
    parameter PRESC_DIV = 3'd2,
    parameter HOUR_LAST = 5'd23,
    parameter MON_LAST = 4'd12,
    parameter YEAR_LAST = 9'd399
) (
    input wire clk,
    input wire clk_en,
    input wire rst_n,
    input wire set_stb,
    input wire [8:0] set_year,
    input wire [3:0] set_mon,
    input wire [5:0] set_day,
    input wire [4:0] set_hour,
    input wire al_stb,
    input wire al_en,
    input wire [3:0] al_mask,
    input wire [8:0] al_year,
    input wire [3:0] al_mon,
    input wire [5:0] al_day,
    input wire [4:0] al_hour,
    input wire alarm_ack,
    output wire [8:0] year,
    output wire [3:0] mon,
    output wire [5:0] day,
    output wire [4:0] hour,
    output wire [5:0] dim,
    output wire leap,
    output wire tick,
    output wire [7:0] tick_count,
    output wire [7:0] day_count,
    output wire [3:0] mon_count,
    output wire mon_sticky,
    output wire alarm_hit,
    output wire alarm_sticky,
    output wire [7:0] alarm_count,
    output wire set_ack,
    output wire set_err,
    output wire [3:0] err_count,
    output wire clamp_sticky,
    output wire [3:0] clamp_count
);

    ips_rtc_calendar #(
        .PRESC_DIV(PRESC_DIV),
        .HOUR_LAST(HOUR_LAST),
        .MON_LAST(MON_LAST),
        .YEAR_LAST(YEAR_LAST)
    ) u_core (
        .clk(clk),
        .clk_en(clk_en),
        .rst_n(rst_n),
        .set_stb(set_stb),
        .set_year(set_year),
        .set_mon(set_mon),
        .set_day(set_day),
        .set_hour(set_hour),
        .al_stb(al_stb),
        .al_en(al_en),
        .al_mask(al_mask),
        .al_year(al_year),
        .al_mon(al_mon),
        .al_day(al_day),
        .al_hour(al_hour),
        .alarm_ack(alarm_ack),
        .year(year),
        .mon(mon),
        .day(day),
        .hour(hour),
        .dim(dim),
        .leap(leap),
        .tick(tick),
        .tick_count(tick_count),
        .day_count(day_count),
        .mon_count(mon_count),
        .mon_sticky(mon_sticky),
        .alarm_hit(alarm_hit),
        .alarm_sticky(alarm_sticky),
        .alarm_count(alarm_count),
        .set_ack(set_ack),
        .set_err(set_err),
        .err_count(err_count),
        .clamp_sticky(clamp_sticky),
        .clamp_count(clamp_count)
    );

endmodule
