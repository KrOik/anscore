`timescale 1ns / 1ps
// ips_rtc_calendar : prescaled civil-time calendar counter with month lengths,
// the Gregorian leap-year rule and a masked once-per-day date alarm.
//
// Written contract.  sim/tb_ips_rtc_calendar.v and models/ips_rtc_calendar.py are
// both derived from this text, and the model computes the civil rules from an
// independent source (Python's calendar module), never from simulation output
// (docs/IP_CORE_SOP.md trap T1).  Every register is gated by clk_en, rst_n is the
// active-low asynchronous reset (trap T2), all datapaths are flat vectors
// (trap T3) and there is no constant multiply anywhere (trap T4).
//
// Time base.  The core is a civil calendar whose finest displayed field is the
// hour of the calendar day.  A programmable prescaler divides enabled beats into
// calendar ticks: one tick advances the hour by one.  PRESC_DIV = 3'd2 gives a
// tick every three enabled beats and HOUR_LAST = 5'd23 gives 24 hours per day, so
// a whole civil sweep fits in a short verification window while the field
// cascade below stays exactly the one a 1 Hz front-end would drive.
//
// Cascade, evaluated on every tick from the pre-edge state:
//   hour == HOUR_LAST  -> hour <= 0 and the calendar day advanced ("new day")
//   then day == dim    -> day <= 1 and the month advanced ("month entry")
//   then mon == MON_LAST -> mon <= 1
//   then year == YEAR_LAST -> year <= 0, otherwise year <= year + 1
//   otherwise the lowest satisfied level only increments: hour+1, day+1 or mon+1.
// year is the civil year modulo 400 (9 bit, 0..YEAR_LAST); 400 is a multiple of
// both 100 and 4, so the modulo image keeps the leap rule exact.
//
// Month lengths and leap rule:
//   leap(y)  = (y[1:0] == 0) && y != 100 && y != 200 && y != 300
//   dim(m)   = 31,28/29,31,30,31,30,31,31,30,31,30,31 for m = 1..12, February
//              taking 29 in a leap year.  dim and leap are registered alongside
//              the date, so the day roll and the host read-back always agree.
//
// Calendar-date preset (set_stb):
//   Illegal when set_mon == 0, set_mon > MON_LAST, set_day == 0,
//   set_hour > HOUR_LAST or set_year > YEAR_LAST.  An illegal preset changes no
//   date state at all, pulses set_err for that one enabled beat and steps
//   err_count, which saturates at ERR_SAT and is the sticky evidence that a
//   rejection happened.  set_err and set_ack can therefore never be high together.
//   Legal presets load year/mon/hour, clamp day to min(set_day, dim(set_mon)),
//   recompute dim and leap for the loaded date, clear the prescaler (so the first
//   tick after a preset is deterministic), re-arm the alarm one-shot (a preset
//   re-bases the day), pulse set_ack and, when the clamp actually bit, latch
//   clamp_sticky and step clamp_count (4 bit, wraps).  Clamping rather than
//   rejecting a past-the-end preset lets a host ask for "the end of this month"
//   without knowing its length.  A legal preset also suppresses the tick of that
//   same cycle.
//
// Alarm.  al_stb captures al_en/al_mask/al_year/al_mon/al_day/al_hour.  al_mask
// selects which fields must match (bit0 hour, bit1 day, bit2 month, bit3 year);
// a masked-out field is a don't-care.  On every tick the alarm is compared with
// the POST-edge date using the alarm registers as they stood BEFORE that tick,
// so a match reports the day that has just been entered.  The alarm can fire at
// most once per calendar day: hit_latch blocks a second fire until the next new
// day, and a new day clears it before the compare, so the tick that opens the new
// day is allowed to fire.  A legal preset re-arms the same one-shot, because it
// re-bases the day.  al_en == 0 never fires.  A fire pulses alarm_hit for
// one enabled beat, latches alarm_sticky (cleared by alarm_ack) and steps
// alarm_count, which saturates at 8'hFF.
//
// Accounting: tick_count (8 bit, wraps) counts ticks, day_count (8 bit, wraps)
// counts new calendar days, mon_count (4 bit, wraps) counts month entries and
// mon_sticky latches that at least one month boundary was crossed.
//
// Reset state is a defined civil date: year 0, month 1, day 1, hour 0, dim 31,
// leap 1, every counter and flag cleared, alarm disabled.  Nothing can hang: the
// prescaler always advances, every field has a wrap, an illegal preset is
// ignored rather than latched, and the alarm one-shot is cleared by every day.
module ips_rtc_calendar #(
    parameter PRESC_DIV = 3'd2,
    parameter HOUR_LAST = 5'd23,
    parameter MON_LAST  = 4'd12,
    parameter YEAR_LAST = 9'd399
)(
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire        set_stb,
    input  wire [8:0]  set_year,
    input  wire [3:0]  set_mon,
    input  wire [5:0]  set_day,
    input  wire [4:0]  set_hour,

    input  wire        al_stb,
    input  wire        al_en,
    input  wire [3:0]  al_mask,
    input  wire [8:0]  al_year,
    input  wire [3:0]  al_mon,
    input  wire [5:0]  al_day,
    input  wire [4:0]  al_hour,

    input  wire        alarm_ack,

    output reg  [8:0]  year,
    output reg  [3:0]  mon,
    output reg  [5:0]  day,
    output reg  [4:0]  hour,
    output reg  [5:0]  dim,
    output reg         leap,
    output reg         tick,
    output reg  [7:0]  tick_count,
    output reg  [7:0]  day_count,
    output reg  [3:0]  mon_count,
    output reg         mon_sticky,
    output reg         alarm_hit,
    output reg         alarm_sticky,
    output reg  [7:0]  alarm_count,
    output reg         set_ack,
    output reg         set_err,
    output reg  [3:0]  err_count,
    output reg         clamp_sticky,
    output reg  [3:0]  clamp_count
);

localparam [5:0] DIM_31    = 6'd31;
localparam [5:0] DIM_30    = 6'd30;
localparam [5:0] DIM_29    = 6'd29;
localparam [5:0] DIM_28    = 6'd28;
localparam [8:0] CENT_A    = 9'd100;
localparam [8:0] CENT_B    = 9'd200;
localparam [8:0] CENT_C    = 9'd300;
localparam [3:0] ERR_SAT   = 4'd7;
localparam [3:0] MON_JAN   = 4'd1;

reg [2:0] psc;
reg       hit_latch;

reg       al_en_r;
reg [3:0] al_mask_r;
reg [8:0] al_year_r;
reg [3:0] al_mon_r;
reg [5:0] al_day_r;
reg [4:0] al_hour_r;

reg       p;
reg       dset;
reg       serr;
reg       lp;
reg [5:0] dm;
reg       nlp;
reg [5:0] ndm;
reg [8:0] nyr;
reg [3:0] nmo;
reg [5:0] nday;
reg [4:0] nhr;
reg       droll;
reg       mroll;
reg       m_ok;
reg       hl;
reg       hit;

function leap_of;
    input [8:0] yy;
    begin
        leap_of = ((yy[1:0] == 2'b00) &&
                   (yy != CENT_A) && (yy != CENT_B) && (yy != CENT_C));
    end
endfunction

function [5:0] dim_of;
    input [3:0] mm;
    input       q;
    begin
        case (mm)
            4'd2:                dim_of = q ? DIM_29 : DIM_28;
            4'd4, 4'd6,
            4'd9, 4'd11:         dim_of = DIM_30;
            default:             dim_of = DIM_31;
        endcase
    end
endfunction

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        year         <= 9'd0;
        mon          <= 4'd1;
        day          <= 6'd1;
        hour         <= 5'd0;
        dim          <= 6'd31;
        leap         <= 1'b1;
        tick         <= 1'b0;
        tick_count   <= 8'd0;
        day_count    <= 8'd0;
        mon_count    <= 4'd0;
        mon_sticky   <= 1'b0;
        alarm_hit    <= 1'b0;
        alarm_sticky <= 1'b0;
        alarm_count  <= 8'd0;
        set_ack      <= 1'b0;
        set_err      <= 1'b0;
        err_count    <= 4'd0;
        clamp_sticky <= 1'b0;
        clamp_count  <= 4'd0;
        psc          <= 3'd0;
        hit_latch    <= 1'b0;
        al_en_r      <= 1'b0;
        al_mask_r    <= 4'd0;
        al_year_r    <= 9'd0;
        al_mon_r     <= 4'd0;
        al_day_r     <= 6'd0;
        al_hour_r    <= 5'd0;
    end else if (clk_en) begin
        set_ack   <= 1'b0;
        set_err   <= 1'b0;
        alarm_hit <= 1'b0;

        dset = 1'b0;
        serr = 1'b0;
        lp   = 1'b0;
        dm   = 6'd0;
        if (set_stb) begin
            if ((set_mon == 4'd0) || (set_mon > MON_LAST) || (set_day == 6'd0) ||
                (set_hour > HOUR_LAST) || (set_year > YEAR_LAST)) begin
                serr = 1'b1;
            end else begin
                lp   = leap_of(set_year);
                dm   = dim_of(set_mon, lp);
                dset = 1'b1;
            end
        end

        if (al_stb) begin
            al_en_r   <= al_en;
            al_mask_r <= al_mask;
            al_year_r <= al_year;
            al_mon_r  <= al_mon;
            al_day_r  <= al_day;
            al_hour_r <= al_hour;
        end
        if (alarm_ack) begin
            alarm_sticky <= 1'b0;
        end
        if (serr) begin
            set_err <= 1'b1;
            if (err_count != ERR_SAT) begin
                err_count <= err_count + 4'd1;
            end
        end

        p    = (psc == PRESC_DIV) && !dset;
        tick <= p;
        psc  <= dset ? 3'd0 : (p ? 3'd0 : (psc + 3'd1));

        if (dset) begin
            year      <= set_year;
            mon       <= set_mon;
            hour      <= set_hour;
            leap      <= lp;
            dim       <= dm;
            day       <= (set_day > dm) ? dm : set_day;
            hit_latch <= 1'b0;
            set_ack   <= 1'b1;
            if (set_day > dm) begin
                clamp_sticky <= 1'b1;
                clamp_count  <= clamp_count + 4'd1;
            end
        end

        if (p) begin
            tick_count <= tick_count + 8'd1;

            droll = 1'b0;
            mroll = 1'b0;
            nyr   = year;
            nmo   = mon;
            nday  = day;
            nhr   = hour;
            nlp   = leap;
            ndm   = dim;
            if (hour == HOUR_LAST) begin
                nhr   = 5'd0;
                droll = 1'b1;
                if (day == dim) begin
                    nday  = 6'd1;
                    mroll = 1'b1;
                    if (mon == MON_LAST) begin
                        nmo = MON_JAN;
                        if (year == YEAR_LAST) begin
                            nyr = 9'd0;
                        end else begin
                            nyr = year + 9'd1;
                        end
                        nlp = leap_of(nyr);
                    end else begin
                        nmo = mon + 4'd1;
                        nlp = leap;
                    end
                    ndm = dim_of(nmo, nlp);
                end else begin
                    nday = day + 6'd1;
                end
            end else begin
                nhr = hour + 5'd1;
            end

            if (droll) begin
                day_count <= day_count + 8'd1;
            end
            if (mroll) begin
                mon_count  <= mon_count + 4'd1;
                mon_sticky <= 1'b1;
            end

            m_ok = 1'b1;
            if (al_mask_r[0] && (nhr  != al_hour_r)) m_ok = 1'b0;
            if (al_mask_r[1] && (nday != al_day_r))  m_ok = 1'b0;
            if (al_mask_r[2] && (nmo  != al_mon_r))  m_ok = 1'b0;
            if (al_mask_r[3] && (nyr  != al_year_r)) m_ok = 1'b0;

            hl = hit_latch;
            if (droll) begin
                hl = 1'b0;
            end
            hit = al_en_r && !hl && m_ok;
            if (hit) begin
                alarm_hit    <= 1'b1;
                alarm_sticky <= 1'b1;
                if (alarm_count != 8'hFF) begin
                    alarm_count <= alarm_count + 8'd1;
                end
            end
            hit_latch <= hit ? 1'b1 : hl;

            year <= nyr;
            mon  <= nmo;
            day  <= nday;
            hour <= nhr;
            leap <= nlp;
            dim  <= ndm;
        end
    end
end

endmodule
