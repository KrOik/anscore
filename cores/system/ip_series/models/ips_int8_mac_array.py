"""Independent golden model for ips_int8_mac_array.

Written from the core's documented contract (per-lane signed int8 product,
rounded requantise (p+1)>>2, per-row bias load or previous accumulator, sum in
ACCW+GUARD bits, saturating clamp to the signed ACCW rails, guard-slice headroom,
one saturating-beat count per beat) and never from simulation output
(docs/IP_CORE_SOP.md trap T1).  Lane 0 is the most significant slice of every
packed vector, which is how the RTL packs its per-lane results.

Stimulus contract shared with sim/tb_ips_int8_mac_array.v, one LCG step per lane:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0x1AC53B79
    x_lane = state[7:0], w_lane = state[23:16], bias_lane = state[31:0]
    load beat every 7th beat (i % 7 == 2), corner overrides as in the TB.
Observed word order per beat, matching the testbench fold:
    acc lane0..lane3, packed headroom, packed sat, geom_id,
    then clip_count and BEATS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

LANES = 4
ACCW = 32
GUARD = 2
SUMW = ACCW + GUARD
BEATS = 320
SEED = 0x1AC53B79

INT_MAX = (1 << (ACCW - 1)) - 1
INT_MIN = -(1 << (ACCW - 1))
SUM_MASK = (1 << SUMW) - 1
GEOM_ID = ((LANES << 24) | (ACCW << 16) | (GUARD << 8) | 0xB7) & MASK32


def main():
    state = SEED
    acc = [0] * LANES
    clip = 0
    words = []

    for i in range(BEATS):
        xs = []
        ws = []
        bs = []
        for _lane in range(LANES):
            state = lcg32(state)
            xs.append(state & 0xFF)
            ws.append((state >> 16) & 0xFF)
            bs.append(state & MASK32)

        load = (i % 7) == 2

        if i % 32 == 0:
            xs[0] = 0x00
            ws[0] = 0x00
        if i % 16 == 5:
            xs[1] = 0x80
            ws[1] = 0x80
        if i % 16 == 12:
            xs[2] = 0x80
            ws[2] = 0x7F
        if i % 4 == 1:
            xs[3] = 0x03
            ws[3] = 0x01

        if load:
            xs[0] = 0x7F
            ws[0] = 0x02
            xs[1] = 0x80
            ws[1] = 0x03
            xs[3] = 0x80
            ws[3] = 0x7F
            bs[0] = (0x7FFFFF80 + (bs[0] & 0xFF)) & MASK32
            bs[1] = (0x80000080 - (bs[1] & 0xFF)) & MASK32
            bs[2] = bs[2] & 0xFFF
            bs[3] = (0x80000010 - (bs[3] & 0x0F)) & MASK32

        hword = 0
        sword = 0
        any_ovf = 0

        for g in range(LANES):
            p = s(xs[g], 8) * s(ws[g], 8)
            term = s((s(p, 16) + 1) & 0x1FFFF, 17) >> 2
            base = s(bs[g], 32) if load else acc[g]
            tot = s((base + term) & SUM_MASK, SUMW)
            low = s(tot, ACCW)
            ovf = 1 if tot != low else 0
            acc[g] = (INT_MIN if tot < 0 else INT_MAX) if ovf else low
            hword |= ((u(tot, SUMW) >> ACCW) & ((1 << GUARD) - 1)) << (GUARD * (LANES - 1 - g))
            sword |= ovf << (LANES - 1 - g)
            any_ovf |= ovf

        if any_ovf:
            clip = (clip + 1) & 0xFF

        for g in range(LANES):
            words.append(u(acc[g], 32))
        words.append(hword)
        words.append(sword)
        words.append(GEOM_ID)

    words.append(clip)
    words.append(BEATS)

    emit('ips_int8_mac_array', words)


if __name__ == '__main__':
    main()
