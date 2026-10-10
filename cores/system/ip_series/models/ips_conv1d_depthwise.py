"""Independent golden model for ips_conv1d_depthwise.

Written from the core's documented contract (one tap per beat, tap TAPS-1 being
the most significant byte of a channel weight row, an 18-bit signed tap sum that
restarts from the single product on tap 0, round-then-shift requantise on the
closing tap only, clamp to the signed YB rails with a saturating-beat counter, and
every published value held while in_valid is low) and never from simulation output
(docs/IP_CORE_SOP.md trap T1).  Integer fixed-point only -- no float, no numpy.

Table constants restate the RTL initial block:
    wrom[0] = {8'h02, 8'hfe, 8'h05, 8'h7f}  srom[0] = 4
    wrom[1] = {8'hfb, 8'h03, 8'h03, 8'h80}  srom[1] = 2
    wrom[2] = {8'h7f, 8'h81, 8'h04, 8'h02}  srom[2] = 6
    wrom[3] = {8'h04, 8'hfc, 8'h7f, 8'h01}  srom[3] = 0
Index tap 0 is the most significant byte of the row, tap TAPS-1 the least.

Stimulus contract shared with sim/tb_ips_conv1d_depthwise.v:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0xBEEF1234, one
    step per tap beat; xv = state[7:0], padv = state[23:16].
    Sample o (0..NOS-1) uses ch = o % 4 and tcfg = 1 + ((o // 4) % 4), its taps
    0..tcfg-1, then one held beat with in_valid low.
Observed word order per beat, matching the testbench fold:
    acc (18 bits), y (8 bits), {out_valid, sat_last},
    then clip_count, cfg_id and the beat count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

TAPS = 4
YB = 8
NOS = 96
SEED = 0xBEEF1234

WROM = (
    (0x02, 0xFE, 0x05, 0x7F),
    (0xFB, 0x03, 0x03, 0x80),
    (0x7F, 0x81, 0x04, 0x02),
    (0x04, 0xFC, 0x7F, 0x01),
)
SROM = (4, 2, 6, 0)

Y_MAX = (1 << (YB - 1)) - 1
Y_MIN = -(1 << (YB - 1))
ACC_MASK = (1 << 18) - 1
CFG_ID = ((TAPS << 8) | YB) & 0xFFFF


def main():
    state = SEED
    acc = 0
    y = 0
    out_valid = 0
    sat_last = 0
    clip = 0
    words = []
    nb = 0

    for o in range(NOS):
        ch = o % 4
        tc = 1 + ((o // 4) % 4)

        for tp in range(tc):
            state = lcg32(state)
            xv = state & 0xFF
            padv = (state >> 16) & 0xFF

            pad_en = 0
            if tp == 0 and o % 7 == 3:
                pad_en = 1
            if tp == tc - 1 and o % 9 == 4:
                pad_en = 1

            if tp == 0 and o % 17 == 0:
                xv = 0x00
            if tp == 2 and o % 23 == 5:
                xv = 0x00
            if o % 15 == 6:
                xv = 0x80
            if o % 15 == 7:
                xv = 0x7F
            if tp == 0 and o % 11 == 2:
                xv = 0x01
            if pad_en and o % 19 == 5:
                padv = 0x80

            xt = s(padv if pad_en else xv, 8)
            wt = s(WROM[ch][tp], 8)
            if tp == 0:
                accn = s(xt * wt, 18)
            else:
                accn = s((acc + xt * wt) & ACC_MASK, 18)
            acc = accn

            if tp == tc - 1:
                rnd = s((accn + 8) & ACC_MASK, 18)
                sft = rnd >> SROM[ch]
                low = s(sft, YB)
                if sft != low:
                    sat_last = 1
                    y = Y_MIN if sft < 0 else Y_MAX
                    clip = (clip + 1) & 0xFF
                else:
                    sat_last = 0
                    y = low
                out_valid = 1
            else:
                out_valid = 0

            words.append(u(acc, 18))
            words.append(u(y, YB))
            words.append((out_valid << 1) | sat_last)
            nb += 1

        # The held beat: in_valid low, so acc / y / sat_last stay put while the
        # one-beat publish pulse falls back.
        words.append(u(acc, 18))
        words.append(u(y, YB))
        words.append(sat_last)
        nb += 1

    words.append(clip)
    words.append(CFG_ID)
    words.append(nb)

    emit('ips_conv1d_depthwise', words)


if __name__ == '__main__':
    main()
