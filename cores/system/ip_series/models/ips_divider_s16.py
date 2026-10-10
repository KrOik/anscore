"""Independent golden model for ips_divider_s16.

Written from the core's documented contract: signed 16/16 restoring division
carried out on unsigned magnitudes, ITER shift/subtract steps with one step per
enabled beat, truncation toward zero with the remainder taking the dividend sign,
a 17-bit quotient because -32768 / -1 = +32768 is not a signed 16-bit value, and
a sticky divz flag that aborts a zero-divisor operation at capture (its collected
quotient and remainder are both zero).  Pipeline stages: 0 idle, 1 restore loop,
2 collect, PIPE output pulse.  Nothing here is read from simulation; the gate
compares this digest with the RTL one (docs/IP_CORE_SOP.md trap T1).

Stimulus contract shared with sim/tb_ips_divider_s16.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0xD1E1DE00, every beat
    dividend = state[15:0], divisor = state[31:16] (signed)
    start on beat 0 of each OPB-beat window; op index % 6 forces
    (-32768,-1), (7,0), (-32768,3), (100,-7), (32767,32767), else random
Observed word order per beat, matching the testbench fold:
    {divz, valid, busy, stage, iter}, quotient, remainder,
then one final flags word and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, s, u

ITER = 16
PIPE = 4
S_IDLE, S_RUN, S_COL = 0, 1, 2
BEATS = 288
OPB = 24
SEED = 0xD1E1DE00
M17 = 0x1FFFF
CORNER = ((-32768, -1), (7, 0), (-32768, 3), (100, -7), (32767, 32767))


def main():
    state = SEED
    quotient = 0
    remainder = 0
    divz = 0
    valid = 0
    stage = S_IDLE
    it = 0
    rem = 0
    qsr = 0
    dsv = 0
    sgn_q = 0
    sgn_r = 0
    words = []

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        a = s(state & 0xFFFF, 16)
        b = s((state >> 16) & 0xFFFF, 16)
        k = i % OPB
        if k == 0 and (i // OPB) % 6 < 5:
            a, b = CORNER[(i // OPB) % 6]
        start = 1 if k == 0 else 0

        am = -a if a < 0 else a
        bm = -b if b < 0 else b
        zero = 1 if bm == 0 else 0

        if start and stage == S_IDLE:
            valid, it, rem = 0, 0, 0
            qsr = 0 if zero else am
            dsv = bm
            sgn_q = (1 if a < 0 else 0) ^ (1 if b < 0 else 0)
            sgn_r = 1 if a < 0 else 0
            stage = S_COL if zero else S_RUN
            if zero:
                divz = 1
        elif stage == S_RUN:
            shifted = ((rem << 1) | ((qsr >> 15) & 1)) & M17
            fits = 1 if shifted >= dsv else 0
            rem = (shifted - dsv) & M17 if fits else shifted
            qsr = ((qsr << 1) & 0xFFFF) | fits
            last = (it == ITER - 1)
            it = (it + 1) & 0x1F
            if last:
                stage = S_COL
        elif stage == S_COL:
            quotient = -qsr if sgn_q else qsr
            remainder = -rem if sgn_r else rem
            stage = PIPE
        else:
            if stage == PIPE:
                valid = 1
                stage = S_IDLE
            else:
                valid = 0

        busy = 1 if stage != S_IDLE else 0
        words.append(((divz & 1) << 11) | ((valid & 1) << 10)
                     | ((busy & 1) << 9) | ((stage & 0xF) << 5) | (it & 0x1F))
        words.append(u(quotient, 17))
        words.append(u(remainder, 16))

    words.append(((divz & 1) << 11) | ((valid & 1) << 10)
                 | ((busy & 1) << 9) | ((stage & 0xF) << 5) | (it & 0x1F))
    words.append(BEATS)
    emit('ips_divider_s16', words)


if __name__ == '__main__':
    main()
