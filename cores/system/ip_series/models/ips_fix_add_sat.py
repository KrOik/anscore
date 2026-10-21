"""Independent golden model for ips_fix_add_sat.

Written from the core's documented contract (three signed Q15 operands summed in
a WIDTH+GUARD word, clamped to WIDTH, headroom = the guard slice of the unclipped
sum, running min/max over clamped results, 8-bit saturating-beat counter).  It
never reads simulation output: the gate compares this digest against the RTL one
(docs/IP_CORE_SOP.md trap T1).

Stimulus contract shared with sim/tb_ips_fix_add_sat.v:
    state = state * 1664525 + 1013904223  (mod 2**32), starting from 0xC0FFEE11
    a = state[15:0], b = state[31:16], k = state[22:7]   (all read as signed Q15)
Observed word order per beat, matching the testbench fold:
    y, headroom, {sat_pos, sat_neg}, y_max, y_min, then clip_count and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, headroom_bits, s, u

WIDTH = 16
GUARD = 2
TB_HEADROOM_BITS = 3          # the testbench samples one bit wider than GUARD
BEATS = 512
SEED = 0xC0FFEE11

Q_LO = -(1 << (WIDTH - 1))
Q_HI = (1 << (WIDTH - 1)) - 1


def main():
    state = SEED
    y = 0
    sat_pos = 0
    sat_neg = 0
    clip = 0
    y_max = Q_LO
    y_min = Q_HI
    words = []

    for _ in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        a = s(state & 0xFFFF, WIDTH)
        b = s((state >> 16) & 0xFFFF, WIDTH)
        k = s((state >> 7) & 0xFFFF, WIDTH)

        total = a + b + k
        overflow = total < Q_LO or total > Q_HI
        if total > Q_HI:
            y = Q_HI
        elif total < Q_LO:
            y = Q_LO
        else:
            y = total

        sat_pos = 1 if (overflow and total > Q_HI) else 0
        sat_neg = 1 if (overflow and total < Q_LO) else 0
        headroom = headroom_bits(total, WIDTH, GUARD) & ((1 << TB_HEADROOM_BITS) - 1)
        if overflow:
            clip = (clip + 1) & 0xFF
        if y > y_max:
            y_max = y
        if y < y_min:
            y_min = y

        words.append(u(y, 32))
        words.append(u(headroom, 32))
        words.append(((sat_pos & 1) << 1) | (sat_neg & 1))
        words.append(u(y_max, 32))
        words.append(u(y_min, 32))

    words.append(clip)
    words.append(BEATS)

    emit('ips_fix_add_sat', words)


if __name__ == '__main__':
    main()
