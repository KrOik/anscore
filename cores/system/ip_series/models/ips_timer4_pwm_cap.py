"""Independent golden model for ips_timer4_pwm_cap.

Implements the timer / capture / register-map semantics of the core straight from
the contract written in the header of src/ips_timer4_pwm_cap.v.  It never reads
simulation output; the gate compares this digest against the RTL one
(docs/IP_CORE_SOP.md trap T1).

Stimulus contract shared with sim/tb_ips_timer4_pwm_cap.v (one step per enabled
beat; clk_en comes from the testbench divisor and is not part of the model):
    state = state * 1664525 + 1013904223  (mod 2**32), starting from 0x3E91A705
    ch_sel   = state[3:0]
    pin_hold = state[3] ^ state[1], re-rolled every 8 beats, drives cap_pin
    cap_pin  = pin_hold
    run_hold = state[7:4], re-rolled only on beats 0, 32, 64, ...
    run_req  = run_hold | 0xC
    wr_addr  = state[13:10]
    wr_stb   = state[14]
    wr_data  = {4'h0, ~state[1:0]}        so wr_data[3:0] = ~state[1:0]

Beat semantics mirror the RTL register-update rules exactly: every right-hand
side reads the pre-edge image, and when several writes target the same register
inside one beat the last one executed wins.  The per-channel period datapath
(pre/per/dty/dta/prc/pwc) is 4 bit, wdc is 4 bit, hld is 2 bit, and
tick_count/cap_count/rd_data are 8 bit.

Folded word order per beat, matching the testbench:
    {24'h0, rd_data},
    {3'h0, cap_busy, run_r, arm_r, ph_r, cap_pend, ovf_pend, trans_pend, pwm_out},
    {12'h0, cap_max, cap_min, last_width, cap_count},
    {24'h0, cap_hold, vec_out, err_sticky, cmp_irq},
    {24'h0, tick_count},
    plus {28'h0, err_count} on every beat with (i % 8) == 7,
then after the loop: err_count, tick_count, BEATS.
"""

import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import emit, lcg32, u

BEATS = 260
SEED = 0x3E91A705

# Contract constants (mirrors the core's localparams).
CAP_HOLD = 2
INVALID_RD = 0xE4
ERR_SAT = 7
WDT_PRE = 3
CH_BIAS = 6
BAD_SEL = 3

M8 = 0xFF
M4 = 0xF


class Timer(object):
    """Register file of the timer block, at its reset values."""

    def __init__(self):
        self.pre = [1] * 4
        self.per = [1] * 4
        self.dty = [0] * 4
        self.dta = [0] * 4
        self.prc = [0] * 4
        self.pwc = [0] * 4
        self.wdc = 0
        self.hld = 0
        self.cap_m = 0
        self.cap_q = 0
        self.cap_d = 0
        self.ris = 0
        self.pwm_out = 0
        self.rd_data = 0
        self.cap_pend = 0
        self.ovf_pend = 0
        self.trans_pend = 0
        self.run_r = 0
        self.arm_r = 0
        self.cap_busy = 0
        self.ph_r = 0
        self.vec_out = CH_BIAS
        self.cap_hold = 0
        self.cur_ch = 0
        self.tick_count = 0
        self.cap_count = 0
        self.cap_max = 0
        self.cap_min = M4
        self.last_width = 0
        self.err_count = 0
        self.err_sticky = 0
        self.cmp_irq = 0


def set_bit(word, bit, value):
    """Return `word` with `bit` driven to `value`, mirroring word[c] <= ..."""
    if value:
        return word | (1 << bit)
    return word & ~(1 << bit)


def lowest_index(mask):
    """Lowest set bit index of a 4-bit mask, 3 when the mask is empty."""
    for bit in range(4):
        if (mask >> bit) & 1:
            return bit
    return 3


def beat(t, ch_sel, cap_pin, run_req, wr_addr, wr_stb, wr_data):
    """Advance the timer by one enabled beat, exactly as the RTL would."""
    o = copy.deepcopy(t)            # pre-edge image: every read comes from here
    sel = wr_addr & 3
    chan = wr_addr >> 2

    t.cap_m = cap_pin
    t.cap_q = o.cap_m
    t.cap_d = o.cap_q

    ovf_any = 0
    err_step = 1 if (wr_stb and sel == BAD_SEL) else 0
    rd_legal = 1 if sel != BAD_SEL else 0
    sedge = 1 if (o.cap_q != o.cap_d) else 0

    rd_v = o.dty[chan]
    if sel == 0:
        rd_v = o.pre[chan]
    elif sel == 1:
        rd_v = o.per[chan]

    for c in range(4):
        ph = 1 if o.prc[c] == o.pre[c] else 0
        t.prc[c] = 0 if ph else u(o.prc[c] + 1, 4)

        if wr_stb and c == chan:
            if sel == 0:
                t.pre[c] = wr_data & M4
            if sel == 1:
                t.per[c] = wr_data & M4
            if sel == 2:
                t.dty[c] = wr_data & M4

        req = (run_req >> c) & 1
        running = (o.run_r >> c) & 1
        armed = (o.arm_r >> c) & 1

        if req and not running:
            t.run_r = set_bit(t.run_r, c, 1)
            t.arm_r = set_bit(t.arm_r, c, 0)
            t.prc[c] = 0
            t.pwc[c] = 0
            t.cap_pend = set_bit(t.cap_pend, c, 0)
            t.ovf_pend = set_bit(t.ovf_pend, c, 0)
            t.trans_pend = set_bit(t.trans_pend, c, 0)
        elif not req and running:
            t.run_r = set_bit(t.run_r, c, 0)
            t.arm_r = set_bit(t.arm_r, c, 0)
            t.pwc[c] = 0
        elif running and not armed and ph:
            if o.pwc[c] == o.per[c]:
                t.arm_r = set_bit(t.arm_r, c, 1)
                t.pwc[c] = 0
                t.dta[c] = o.dty[c]
            else:
                t.pwc[c] = u(o.pwc[c] + 1, 4)
        elif armed and ph:
            if o.pwc[c] == o.per[c]:
                t.pwc[c] = 0
                t.dta[c] = o.dty[c]
                if o.dty[c] != o.dta[c]:
                    t.trans_pend = set_bit(t.trans_pend, c, 1)
                t.ovf_pend = set_bit(t.ovf_pend, c, 1)
                ovf_any = 1
            else:
                t.pwc[c] = u(o.pwc[c] + 1, 4)

        t.ph_r = set_bit(t.ph_r, c, ph)
        t.pwm_out = set_bit(t.pwm_out, c, armed and (o.pwc[c] < o.dta[c]))

    mask = o.arm_r & ch_sel
    att = lowest_index(mask)
    started = bool(mask) and o.cap_q and (not o.ris) and (o.hld == 0)
    closed = bool(o.ris) and sedge and (o.hld == 0)
    aborted = bool(o.ris) and (not closed) and (o.wdc >= WDT_PRE)

    if o.ris and not closed:
        t.wdc = u(o.wdc + 1, 4)

    if closed:
        t.wdc = 0
        t.ris = 0
        t.hld = CAP_HOLD
        t.cap_pend = set_bit(t.cap_pend, o.cur_ch, 1)
        t.last_width = o.wdc
        if o.wdc > o.cap_max:
            t.cap_max = o.wdc
        if o.wdc < o.cap_min:
            t.cap_min = o.wdc
        if o.cap_count != M8:
            t.cap_count = u(o.cap_count + 1, 8)
    elif started:
        t.ris = 1
        t.wdc = 0
        t.cur_ch = att
    elif aborted:
        t.ris = 0
        t.ovf_pend = set_bit(t.ovf_pend, o.cur_ch, 1)

    if o.hld != 0 and not closed:
        t.hld = u(o.hld - 1, 2)

    t.cap_busy = o.ris
    t.cap_hold = o.hld
    if err_step:
        t.err_sticky = 1
        if o.err_count < ERR_SAT:
            t.err_count = u(o.err_count + 1, 4)

    if ovf_any:
        t.tick_count = u(o.tick_count + 1, 8)
    t.cmp_irq = ovf_any
    t.vec_out = u(o.cur_ch ^ CH_BIAS, 4)
    t.rd_data = u(rd_v, 4) if rd_legal else INVALID_RD


def stimulus():
    """The deterministic input tuples, one per enabled beat (TB contract)."""
    state = SEED
    run_hold = 0
    pin_hold = 0
    for i in range(BEATS):
        state = lcg32(state)
        if (i % 32) == 0:
            run_hold = (state >> 4) & M4
        if (i % 8) == 0:
            pin_hold = ((state >> 3) ^ (state >> 1)) & 1
        yield (u(state, 4),                                   # ch_sel
               pin_hold,                                      # cap_pin
               run_hold | 0xC,                                # run_req
               (state >> 10) & M4,                            # wr_addr
               (state >> 14) & 1,                             # wr_stb
               (~state) & 3)                                  # wr_data[3:0]


def fold(t):
    """The five words the testbench folds on every beat."""
    return [
        t.rd_data,
        ((t.cap_busy << 28) | (t.run_r << 24) | (t.arm_r << 20) | (t.ph_r << 16) |
         (t.cap_pend << 12) | (t.ovf_pend << 8) | (t.trans_pend << 4) | t.pwm_out),
        ((t.cap_max << 16) | (t.cap_min << 12) | (t.last_width << 8) | t.cap_count),
        ((t.cap_hold << 6) | (t.vec_out << 2) | (t.err_sticky << 1) | t.cmp_irq),
        t.tick_count,
    ]


def main():
    t = Timer()
    words = []

    for i, inputs in enumerate(stimulus()):
        beat(t, *inputs)
        words.extend(fold(t))
        if (i % 8) == 7:
            words.append(t.err_count)

    words.append(t.err_count)
    words.append(t.tick_count)
    words.append(BEATS)

    emit('ips_timer4_pwm_cap', words)


if __name__ == '__main__':
    main()
