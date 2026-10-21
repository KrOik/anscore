`timescale 1ns / 1ps
// ips_timer4_pwm_cap : four-channel timer block -- period PWM with glitch-free
// duty update, plus a shared input-capture path and a compare IRQ.
//
// Written contract (src/ips_timer4_pwm_cap.v and models/ips_timer4_pwm_cap.py are
// both derived from this text; docs/IP_CORE_SOP.md trap T1).  Every register is
// gated by clk_en, rst_n is the active-low asynchronous reset, and the block uses
// only narrow shift/mask comparisons -- no constant multiplies
// (docs/IP_CORE_SOP.md trap T4) -- to stay inside its LUT budget.
//
// Register widths: the per-channel period datapath (pre/per/dty/dta/prc/pwc) is
// 4 bit, the capture helpers (wdc/hld) are 4 and 2 bit, the two event accumulators
// (tick_count/cap_count) and the read bus (rd_data) are 8 bit.
//
// Per channel c in 0..3, evaluated on every enabled beat from the pre-edge state:
//   prescaler    ph[c] = (prc[c] == pre[c]);  prc[c] <= ph[c] ? 0 : prc[c] + 1
//   start/stop   a rising run_req[c] re-bases the channel: run_r<=1, arm_r<=0,
//                prc/pwc cleared and the channel ledger (cap_pend, ovf_pend,
//                trans_pend) cleared.  The capture accounting (cap_max, cap_min,
//                cap_count, last_width, cur_ch) is block-global and survives a
//                single-channel restart.  A falling run_req[c] stops the channel
//                and clears run_r, arm_r and pwc.
//   arming       a re-based channel is silent until it has completed one full
//                period: while run_r && !arm_r each ph[c] tick steps pwc and, at
//                pwc == per, the channel arms, pwc wraps to 0 and the shadow duty
//                transfers (dta <= dty).  Nothing is emitted during that silent
//                period, so a restart can never show a partial period.
//   period tick  when arm_r && ph[c]: ovf = (pwc[c] == per[c]).  On ovf the
//                counter wraps to 0, the shadow duty transfers (dta <= dty),
//                trans_pend[c] is set only when the transferred value differs,
//                ovf_pend[c] latches, tick_count steps and cmp_irq pulses.
//                Otherwise pwc[c] increments.
//   pwm output   pwm_out[c] <= arm_r[c] && (pwc[c] < dta[c]) -- registered, so a
//                duty change only becomes visible after the wrap that transferred
//                the shadow value (glitch-free by construction).
//
// Capture path (one shared engine, attributed to a channel):
//   cap_pin is 2-flop synchronised (cap_m, cap_q) and cap_d holds the previous
//   sample; sedge = (cap_q != cap_d).  mask = arm_r & ch_sel selects the channels
//   that may own a measurement, and att is its lowest set index.  A measurement
//   starts when mask is non-empty, cap_q is high, no measurement is running and
//   the hold window has expired (ris<=1, wdc<=0, cur_ch<=att).  wdc counts enabled
//   beats while a measurement runs, so a width is expressed in enabled beats of
//   the core (the prescaler only drives the PWM half of the block).
//   A synchronised sample change closes it: wdc<=0, ris<=0, hld<=CAP_HOLD,
//   cap_pend[cur_ch]<=1 and the global accounting updates (cap_max/cap_min/
//   last_width, cap_count steps).  CAP_HOLD enabled beats of re-trigger
//   suppression follow every close.  If no sample change arrives while
//   wdc >= WDT_PRE the measurement is abandoned: ris<=0 and ovf_pend[cur_ch]<=1.
//   vec_out = cur_ch ^ CH_BIAS is the attribution word the host reads back; the
//   bias lets a bus tell "no capture yet" (cur_ch==0) from a real channel 0 close.
//   cap_busy mirrors ris and cap_hold mirrors the remaining CAP_HOLD suppression
//   window, so the host can poll the capture engine's state.
//
// Register map, addressed by wr_addr = {channel[1:0], select[1:0]}:
//   select 0 PRE  write pre[ch] = wr_data[3:0]
//   select 1 PER  write per[ch] = wr_data[3:0]
//   select 2 DTY  write dty[ch] = wr_data[3:0] (shadow, lands on the next wrap)
//   select BAD_SEL  ILLEGAL: err_count steps (saturating at ERR_SAT), err_sticky
//                 latches, no register changes and the read returns INVALID_RD.
//                 With BAD_SEL == 3 the illegal addresses are 3, 7, 11 and 15.
//   rd_data is registered and returns the pre-edge image of the addressed
//   register (or INVALID_RD), so the host always sees a consistent snapshot.
//
// No state can hang: a stopped or un-armed channel still advances its prescaler,
// hld only counts down to zero, a running capture always either closes or reaches
// the watchdog, and every register has a defined reset value.
module ips_timer4_pwm_cap (
    input  wire        clk,
    input  wire        clk_en,
    input  wire        rst_n,

    input  wire [3:0]  ch_sel,
    input  wire        cap_pin,
    input  wire [3:0]  run_req,
    input  wire [3:0]  wr_addr,
    input  wire        wr_stb,
    input  wire [7:0]  wr_data,

    output reg  [3:0]  pwm_out,
    output reg  [7:0]  rd_data,
    output reg  [3:0]  cap_pend,
    output reg  [3:0]  ovf_pend,
    output reg  [3:0]  trans_pend,
    output reg  [3:0]  run_r,
    output reg  [3:0]  arm_r,
    output reg         cap_busy,
    output reg  [3:0]  ph_r,
    output reg  [3:0]  vec_out,
    output reg  [1:0]  cap_hold,
    output reg  [1:0]  cur_ch,
    output reg  [7:0]  tick_count,
    output reg  [7:0]  cap_count,
    output reg  [3:0]  cap_max,
    output reg  [3:0]  cap_min,
    output reg  [3:0]  last_width,
    output reg  [3:0]  err_count,
    output reg         err_sticky,
    output reg         cmp_irq
);

localparam [1:0] CAP_HOLD   = 2'd2;
localparam [7:0] INVALID_RD = 8'hE4;
localparam [3:0] ERR_SAT    = 4'd7;
localparam [3:0] WDT_PRE    = 4'd3;
localparam [3:0] CH_BIAS    = 4'h6;
localparam [1:0] BAD_SEL    = 2'd3;

reg [3:0] pre  [0:3];
reg [3:0] per  [0:3];
reg [3:0] dty  [0:3];
reg [3:0] dta  [0:3];
reg [3:0] prc  [0:3];
reg [3:0] pwc  [0:3];
reg [3:0] wdc;
reg [1:0] hld;
reg       cap_m, cap_q, cap_d, ris;

integer c;
reg       ph;
reg       ovf;
reg       ovf_any;
reg       err_step;
reg       sedge;
reg       started;
reg       closed;
reg       aborted;
reg       wren;
reg       rd_legal;
reg [1:0] wsel;
reg [1:0] wch;
reg [1:0] att;
reg [3:0] wval;
reg [3:0] rd_v;
reg [3:0] mask;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pwm_out    <= 4'h0;
        rd_data    <= 8'h00;
        cap_pend   <= 4'h0;
        ovf_pend   <= 4'h0;
        trans_pend <= 4'h0;
        run_r      <= 4'h0;
        arm_r      <= 4'h0;
        cap_busy   <= 1'b0;
        ph_r       <= 4'h0;
        vec_out    <= 4'h6;
        cap_hold   <= 2'h0;
        cur_ch     <= 2'd0;
        tick_count <= 8'h00;
        cap_count  <= 8'h00;
        cap_max    <= 4'h0;
        cap_min    <= 4'hF;
        last_width <= 4'h0;
        err_count  <= 4'h0;
        err_sticky <= 1'b0;
        cmp_irq    <= 1'b0;
        cap_m      <= 1'b0;
        cap_q      <= 1'b0;
        cap_d      <= 1'b0;
        ris        <= 1'b0;
        wdc        <= 4'h0;
        hld        <= 2'h0;
        for (c = 0; c < 4; c = c + 1) begin
            pre[c]  <= 4'h1;
            per[c]  <= 4'h1;
            dty[c]  <= 4'h0;
            dta[c]  <= 4'h0;
            prc[c]  <= 4'h0;
            pwc[c]  <= 4'h0;
        end
    end else if (clk_en) begin
        ovf_any  = 1'b0;
        err_step = (wr_stb && (wr_addr[1:0] == BAD_SEL));
        rd_legal = (wr_addr[1:0] != BAD_SEL);
        wsel     = wr_addr[1:0];
        wch      = wr_addr[3:2];
        wval     = wr_data[3:0];
        rd_v     = 4'h0;
        sedge    = (cap_q != cap_d);
        cap_m    <= cap_pin;
        cap_q    <= cap_m;
        cap_d    <= cap_q;
        for (c = 0; c < 4; c = c + 1) begin
            ph      = (prc[c] == pre[c]);
            prc[c]  <= ph ? 4'h0 : (prc[c] + 4'h1);
            wren    = (wr_stb && (wch == c));
            if (wren) begin
                if (wsel == 2'd0) begin
                    pre[c] <= wval;
                end
                if (wsel == 2'd1) begin
                    per[c] <= wval;
                end
                if (wsel == 2'd2) begin
                    dty[c] <= wval;
                end
            end
            if (wch == c) begin
                rd_v = (wsel == 2'd0) ? pre[c] :
                       ((wsel == 2'd1) ? per[c] : dty[c]);
            end
            if (run_req[c] && !run_r[c]) begin
                run_r[c]      <= 1'b1;
                arm_r[c]      <= 1'b0;
                prc[c]        <= 4'h0;
                pwc[c]        <= 4'h0;
                cap_pend[c]   <= 1'b0;
                ovf_pend[c]   <= 1'b0;
                trans_pend[c] <= 1'b0;
            end else if (!run_req[c] && run_r[c]) begin
                run_r[c] <= 1'b0;
                arm_r[c] <= 1'b0;
                pwc[c]   <= 4'h0;
            end else if (run_r[c] && !arm_r[c] && ph) begin
                if (pwc[c] == per[c]) begin
                    arm_r[c] <= 1'b1;
                    pwc[c]   <= 4'h0;
                    dta[c]   <= dty[c];
                end else begin
                    pwc[c] <= pwc[c] + 4'h1;
                end
            end else if (arm_r[c] && ph) begin
                ovf = (pwc[c] == per[c]);
                if (ovf) begin
                    pwc[c] <= 4'h0;
                    dta[c] <= dty[c];
                    if (dty[c] != dta[c]) begin
                        trans_pend[c] <= 1'b1;
                    end
                    ovf_pend[c] <= 1'b1;
                    ovf_any      = 1'b1;
                end else begin
                    pwc[c] <= pwc[c] + 4'h1;
                end
            end
            ph_r[c]    <= ph;
            pwm_out[c] <= arm_r[c] && (pwc[c] < dta[c]);
        end
        mask    = arm_r & ch_sel;
        att     = mask[0] ? 2'd0 : (mask[1] ? 2'd1 : (mask[2] ? 2'd2 : 2'd3));
        started = (mask != 4'h0) && cap_q && !ris && (hld == 2'h0);
        closed  = ris && sedge && (hld == 2'h0);
        aborted = ris && !closed && (wdc >= WDT_PRE);
        if (ris && !closed) begin
            wdc <= wdc + 4'h1;
        end
        if (closed) begin
            wdc             <= 4'h0;
            ris             <= 1'b0;
            hld             <= CAP_HOLD;
            cap_pend[cur_ch] <= 1'b1;
            last_width      <= wdc;
            if (wdc > cap_max) begin
                cap_max <= wdc;
            end
            if (wdc < cap_min) begin
                cap_min <= wdc;
            end
            if (cap_count != 8'hFF) begin
                cap_count <= cap_count + 8'h01;
            end
        end else if (started) begin
            ris    <= 1'b1;
            wdc    <= 4'h0;
            cur_ch <= att;
        end else if (aborted) begin
            ris             <= 1'b0;
            ovf_pend[cur_ch] <= 1'b1;
        end
        if ((hld != 2'h0) && !closed) begin
            hld <= hld - 2'h1;
        end
        cap_busy <= ris;
        cap_hold <= hld;
        if (err_step) begin
            err_sticky <= 1'b1;
            if (err_count < ERR_SAT) begin
                err_count <= err_count + 4'h1;
            end
        end
        if (ovf_any) begin
            tick_count <= tick_count + 8'h01;
        end
        cmp_irq <= ovf_any;
        vec_out <= {2'd0, cur_ch} ^ CH_BIAS;
        rd_data <= rd_legal ? {4'h0, rd_v} : INVALID_RD;
    end
end

endmodule
