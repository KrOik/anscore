"""Independent golden model for ips_quant_int8_sym.

Written from the core's documented contract (one value per beat, dir selecting the
direction and ch the channel scale, a single signed product, round-half-away from
zero on the magnitude, symmetric clipping to int8 / int16 rails, the signed payload
rebuilt from the published magnitude, per-direction and dead-zone stickies and a
saturating-beat counter) and never from simulation output (docs/IP_CORE_SOP.md
trap T1).  Integer fixed-point only -- no float, no numpy.

Scale / shift tables restate the RTL wires and the combinational shift table:
    MQ = (0x040, 0x009, 0x006, 0x020)   MD = (0x07FF, 0x0040, 0x0200, 0x000A)
    SH = (0, 1, 2, 3)                   BQ, BD = 9, 1
For a beat:
    a    = dir ? sext8(x[7:0]) : sext12(x)
    m    = dir ? MD[ch] : MQ[ch]
    P    = a*m                                   (24-bit signed container)
    V    = (|P| + (1 << (base + SH[ch] - 1))) >> (base + SH[ch])
    mv   = min(V, rail), rail = dir ? 32767 : 127
    yq   = (+-mv) mod 256, ydq = (+-mv) mod 65536, sign taken when P < 0 and mv != 0

Stimulus contract shared with sim/tb_ips_quant_int8_sym.v:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0x7A1F00D5, one step
    per beat; x = state[11:0], ch = i % 4, dir = (i // 5) % 2, with the slot corners
    of i % 64 (3 zero, 7 +2047, 15 -2048, 23 +127, 31 -127, 39 ch1 quantise tie at
    x = 512, 47 ch2 dead zone at x = 40, 55/59 ch0 quantise rails at +-1200,
    61/63 ch0 dequantise rails) overriding ch / dir / x.
    Every beat is observed once, and beats with i % 23 == 22 are followed by one
    held beat (in_valid low) that repeats the published payload with y_vld = 0.
Observed word order per beat, matching the testbench fold:
    ymag, yq, ydq, {sat_q, sat_d, udf_sticky, clipped_last, y_neg, y_vld}, cfg_id,
    then clip_count and the observation count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

XB = 12
MB = 12
YB = 8
BEATS = 300
SEED = 0x7A1F00D5

MQ = (0x040, 0x009, 0x006, 0x020)
MD = (0x7FF, 0x040, 0x200, 0x00A)
SH = (0, 1, 2, 3)
BQ = 9
BD = 1
RAIL_Q = 127
RAIL_D = 32767
CFG_ID = ((XB << 24) | (MB << 16) | (YB << 8) | 0x9A) & MASK32


def main():
    state = SEED
    ymag = 0
    yq = 0
    ydq = 0
    y_neg = 0
    y_vld = 0
    clipped_last = 0
    sat_q = 0
    sat_d = 0
    udf_sticky = 0
    clip_count = 0
    words = []
    nb = 0

    def fold():
        words.append(ymag)
        words.append(u(yq, 8))
        words.append(u(ydq, 16))
        words.append(
            (((((sat_q * 2 + sat_d) * 2 + udf_sticky) * 2 + clipped_last) * 2 + y_neg) * 2 + y_vld)
        )
        words.append(CFG_ID)

    for i in range(BEATS):
        state = lcg32(state)
        ch = i % 4
        dirv = (i // 5) % 2
        xpat = state & 0xFFF
        slot = i % 64

        if slot == 3:
            xpat = 0x000
        if slot == 7:
            xpat = 0x7FF
        if slot == 15:
            xpat = 0x800
        if slot == 23:
            xpat = 0x07F
        if slot == 31:
            xpat = 0x081
        if slot == 39:
            ch, dirv, xpat = 1, 0, 0x200
        if slot == 47:
            ch, dirv, xpat = 2, 0, 0x028
        if slot == 55:
            ch, dirv, xpat = 0, 0, u(1200, 12)
        if slot == 59:
            ch, dirv, xpat = 0, 0, u(-1200, 12)
        if slot == 61:
            ch, dirv, xpat = 0, 1, 0x081
        if slot == 63:
            ch, dirv, xpat = 0, 1, 0x07F

        a = s(xpat & 0xFF, 8) if dirv else s(xpat, 12)
        m = s(MD[ch] if dirv else MQ[ch], 12)
        sh = SH[ch]
        prod = s(a * m, 24)
        mag = u(-prod, 24) if prod < 0 else prod
        base = BD if dirv else BQ
        w = u((mag & 0x7FFFFF) + (1 << (base + sh - 1)), 23)
        v = (w >> base) >> sh
        rail = RAIL_D if dirv else RAIL_Q
        clipped = 1 if v > rail else 0
        mv = rail if clipped else (v & 0xFFFF)
        neg = 1 if (prod < 0 and mv != 0) else 0
        udf = 1 if (mv == 0 and a != 0) else 0

        ymag = mv
        yq = u(-mv if neg else mv, 8)
        ydq = u(-mv if neg else mv, 16)
        y_neg = neg
        clipped_last = clipped
        y_vld = 1
        if udf:
            udf_sticky = 1
        if clipped:
            clip_count = u(clip_count + 1, 8)
            if dirv:
                sat_d = 1
            else:
                sat_q = 1

        fold()
        nb += 1

        if i % 23 == 22:
            # Held beat: in_valid low, so only the valid echo falls back.
            y_vld = 0
            fold()
            nb += 1

    words.append(clip_count)
    words.append(nb)

    emit('ips_quant_int8_sym', words)


if __name__ == '__main__':
    main()
