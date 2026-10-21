"""Independent golden model for ips_iir_biquad.

Written from the core's documented contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1).  Transposed direct-form II biquad with the negated
denominator coefficients folded into the feedback terms:

    y(n)  = b0*x(n) + s1(n-1)
    s1(n) = b1*x(n) + s2(n-1) + c1*y(n)
    s2(n) = b2*x(n) + c2*y(n)

Signals are signed Q11 (12 bit), coefficients signed Q6 (8 bit, LSB 1/64).  Every
product is rounded to nearest and rescaled by QDIV, t = (x*c + PRND) >> QDIV with
PRND = 2**(QDIV-1) = 32, and is kept in a 14-bit slice.  The three terms of the
active step are summed in a 16-bit accumulator; an out-of-range sum (bits 15..11
not all equal to bit 11, judged on the wrapped 16-bit value) clamps to -2048 when
bit 15 is set and to +2047 otherwise, increments sat_cnt and latches the sticky
satur flag.  headroom is the GUARD slice sum[11+GUARD:12] of that unclipped sum.
One sample takes six enabled beats: capture, three accumulation steps (step 0, 1,
2), collect and the output pulse; stages 0 idle, 1 accumulate, 2 collect, 3 out;
nsmp counts completed samples; start is ignored while busy.

Stimulus contract shared with sim/tb_ips_iir_biquad.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x2C0DE5E5, every beat
    x_in = state[15:4] (signed Q11), forced on beat 0 of each OPB-beat window to
    CORNER[window % 6] = 2047, -2048, 0, 1024, -1481, 341
    start on beats 0 and 3 of every window (beat 3 collides with a running sample)
Observed word order per beat, matching the testbench fold:
    {satur, valid, busy, stage, step, headroom, y_out},
    {state1, state2}, {nsmp, sat_cnt},
then one final first word and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, s, u

B0, B1, B2, C1, C2 = 6, 13, 6, 90, -38
QDIV = 6
GUARD = 3
PRND = 32
TB_HEADROOM_BITS = 4        # the testbench samples one bit wider than GUARD
Q_MAX = 2047
Q_MIN = -2048
S_IDLE, S_STEP, S_COL, S_OUT = 0, 1, 2, 3
BEATS = 288
OPB = 6
SEED = 0x2C0DE5E5
CORNER = (2047, -2048, 0, 1024, -1481, 341)


def product(value, coef):
    """One coefficient tap: 20-bit signed product, rounded, rescaled, 14-bit slice."""
    p = s(u(value * coef, 20), 20)
    t = s(u(p + PRND, 20), 20) >> QDIV
    return s(u(t, 14), 14)


def accumulate(terms):
    """Shared 16-bit accumulator: returns (sum, clamped, overflow, headroom)."""
    total = s(u(sum(terms), 16), 16)
    low12 = total & 0xFFF
    sext = u((0xF000 if (total >> 15) & 1 else 0) | low12, 16)
    overflow = u(total, 16) != sext
    if overflow:
        clamped = Q_MIN if (total >> 15) & 1 else Q_MAX
    else:
        clamped = s(low12, 12)
    head = (u(total, 16) >> 12) & ((1 << GUARD) - 1)
    return total, clamped, 1 if overflow else 0, head


def main():
    state = SEED
    lx = 0
    yr = 0
    y_out = 0
    st1 = 0
    st2 = 0
    head = 0
    sat_cnt = 0
    nsmp = 0
    satur = 0
    valid = 0
    stage = S_IDLE
    step = 0
    words = []

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        x = s((state >> 4) & 0xFFF, 12)
        k = i % OPB
        if k == 0:
            x = CORNER[(i // OPB) % 6]
        start = 1 if (k == 0 or k == 3) else 0

        if start and stage == S_IDLE:
            lx, yr, stage, step, valid = x, 0, S_STEP, 0, 0
        else:
            valid = 0
            if stage == S_STEP:
                if step == 0:
                    terms = (product(lx, B0), st1, 0)
                elif step == 1:
                    terms = (product(lx, B1), st2, product(yr, C1))
                else:
                    terms = (product(lx, B2), 0, product(yr, C2))
                _, clamped, overflowed, head = accumulate(terms)
                if overflowed:
                    sat_cnt = u(sat_cnt + 1, 8)
                    satur = 1
                if step == 0:
                    yr = clamped
                elif step == 1:
                    st1 = clamped
                else:
                    st2 = clamped
                if step == 2:
                    stage, step = S_COL, 0
                else:
                    step += 1
            elif stage == S_COL:
                y_out = yr
                stage = S_OUT
            elif stage == S_OUT:
                valid = 1
                nsmp = u(nsmp + 1, 8)
                stage = S_IDLE
            else:
                stage = S_IDLE

        busy = 1 if stage != S_IDLE else 0
        words.append((u(y_out, 12))
                     | ((head & ((1 << TB_HEADROOM_BITS) - 1)) << 12)
                     | ((step & 3) << 16) | ((stage & 7) << 18)
                     | (busy << 21) | (valid << 22) | ((satur & 1) << 23))
        words.append((u(st1, 12) << 12) | u(st2, 12))
        words.append((u(nsmp, 8) << 8) | u(sat_cnt, 8))

    words.append((u(y_out, 12))
                 | ((head & ((1 << TB_HEADROOM_BITS) - 1)) << 12)
                 | ((step & 3) << 16) | ((stage & 7) << 18)
                 | (busy << 21) | (valid << 22) | ((satur & 1) << 23))
    words.append(BEATS)
    emit('ips_iir_biquad', words)


if __name__ == '__main__':
    main()
