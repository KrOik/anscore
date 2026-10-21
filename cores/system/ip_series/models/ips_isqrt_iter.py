"""Independent golden model for ips_isqrt_iter.

Written from the core's documented contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1): the 16-bit signed radicand is scanned most
significant bit-pair first and the restoring radix-4 loop then runs FRAST + 1 = 8
further steps over zero pairs, so the 16 iterations root the value (radicand << 16)
and the reported root is the Q8 fixed-point square root, root[15:8] being the
integer root.  Each digit step is

    shifted = 4 * rem + next_bit_pair
    test    = 4 * root + 1
    rem     = shifted - test, root = 2 * root + 1   when shifted >= test
    rem     = shifted,       root = 2 * root        otherwise

which leaves rem = (radicand << 16) - root ** 2 at all times.  When the last
integer digit finishes (iteration index FRAST) the integer residual
radicand - iroot ** 2 is captured into irem and `exact` reports that capture being
zero, i.e. a perfect square.  A negative radicand aborts at capture, sets the
sticky invalid flag and leaves root and irem zero with exact low.  Stages: 0 idle,
1 digit loop, 2 collect, 4 output pulse.

Stimulus contract shared with sim/tb_ips_isqrt_iter.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x15A7E5D0, every beat
    radicand = state[15:0] (signed), forced on beat 0 of each OPB-beat window to
    CORNER[window % 7] = 9, 2, 32761 (181*181), -32768, 32767, 0, 1
    start on beats 0 and 1 of every window (beat 1 collides with a running op)
Observed word order per beat, matching the testbench fold:
    {invalid, exact, valid, busy, stage, iter}, root, irem,
then one final flags word and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, s, u

ITER = 16
FRAST = 7
S_IDLE, S_RUN, S_COL, S_OUT = 0, 1, 2, 4
BEATS = 480
OPB = 20
SEED = 0x15A7E5D0
M17 = 0x1FFFF
M19 = 0x7FFFF
CORNER = (9, 2, 32761, -32768, 32767, 0, 1)


def main():
    state = SEED
    root = 0
    irem = 0
    exact = 0
    invalid = 0
    valid = 0
    stage = S_IDLE
    it = 0
    rem = 0
    rad = 0
    abort = 0
    words = []

    for i in range(BEATS):
        state = (state * 1664525 + 1013904223) & MASK32
        rc = s(state & 0xFFFF, 16)
        k = i % OPB
        if k == 0:
            rc = CORNER[(i // OPB) % 7]
        start = 1 if (k == 0 or k == 1) else 0

        neg = 1 if rc < 0 else 0
        mag = u(-rc, 16) if neg else u(rc, 16)

        shifted = u((rem << 2) | ((rad >> 14) & 3), 19)
        test = u((root << 2) + 1, 19)
        fits = 1 if shifted >= test else 0
        rem_new = u(shifted - test, 19) if fits else shifted

        if start and stage == S_IDLE:
            valid, it, rem, root, irem, exact = 0, 0, 0, 0, 0, 0
            rad = mag
            abort = neg
            stage = S_COL if neg else S_RUN
            if neg:
                invalid = 1
        elif stage == S_RUN:
            rem = u(rem_new, 17)
            root = u((root << 1) | fits, 16)
            rad = u(rad << 2, 16)
            last = (it == FRAST)
            term = (it == ITER - 1)
            it = u(it + 1, 5)
            if last:
                irem = u(rem_new, 10)
            if term:
                stage = S_COL
        elif stage == S_COL:
            exact = 1 if (irem == 0 and not abort) else 0
            stage = S_OUT
        else:
            if stage == S_OUT:
                valid = 1
                stage = S_IDLE
            else:
                valid = 0

        busy = 1 if stage != S_IDLE else 0
        words.append(((invalid & 1) << 12) | ((exact & 1) << 11)
                     | ((valid & 1) << 10) | ((busy & 1) << 9)
                     | ((stage & 0xF) << 5) | (it & 0x1F))
        words.append(u(root, 16))
        words.append(u(irem, 10))

    words.append(((invalid & 1) << 12) | ((exact & 1) << 11)
                 | ((valid & 1) << 10) | ((busy & 1) << 9)
                 | ((stage & 0xF) << 5) | (it & 0x1F))
    words.append(BEATS)
    emit('ips_isqrt_iter', words)


if __name__ == '__main__':
    main()
