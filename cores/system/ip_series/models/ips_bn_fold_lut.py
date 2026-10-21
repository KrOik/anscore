"""Independent golden model for ips_bn_fold_lut.

Written from the core's documented contract (one channel slot per beat, a 12-bit
signed multiplier and a 16-bit signed addend read out of constant LUT rows, a single
signed product, round half up on the SH-bit shifted value, the addend folding into
the bias path only, symmetric clamping of the narrowed value to the WB / BB rails and
each path refreshing only its own register) and never from simulation output
(docs/IP_CORE_SOP.md trap T1).  Integer fixed-point only -- no float, no numpy.

Tables restate the RTL row wires (16-bit fields, slot 3 left-most):
    MULA = {0x01a0, 0x0200, 0x00c0, 0x0380}   MULB = {0x0f80, 0x00ff, 0x02c0, 0x0060}
    ADDA = {0x7ff0, 0x0fc0, 0xff80, 0x0020}   ADDB = {0x8010, 0xf040, 0x0380, 0x0000}
so that, per slot:
    MULT = (0x380, 0x0c0, 0x200, 0x1a0, 0x060, 0x2c0, 0x0ff, 0x0f80)  -> low 12 bits
    ADDT = (0x020, 0xff80, 0x0fc0, 0x7ff0, 0x0000, 0x0380, 0xf040, 0x8010)

For a beat:
    P  = s(w) * s(MULT[ch])                      (24-bit signed container)
    R  = (P + (1 << (SH-1))) mod 2**24, signed   (round half up)
    Q  = R >> SH                                 (arithmetic / floor shift)
    fs = sel ? Q + s(ADDT[ch]) : Q               (24-bit signed)
    fits = sign_extend(fs, WB or BB) == fs
    yw = fs if fits(WB) else (-128 if fs < 0 else 127)
    yb = fs if fits(BB) else (-32768 if fs < 0 else 32767)

Stimulus contract shared with sim/tb_ips_bn_fold_lut.v:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0xC0FFEE11, one step
    per beat; w = state[11:0], ch = i % 8, sel = (i // 3) % 2, with the slot corners
    of i % 64 (3 zero, 7 +2047, 15 -2048, 23/25 ch0 weight rails, 31/33 ch3 and ch7
    bias rails, 39/41 the positive half-way residue at w = 8 on ch3, 47 the negative
    half-way residue at w = -8 on ch3, 53 zero operand with the ch2 addend, 59 ch7
    weight, 61 ch6 bias) overriding ch / sel / w.
    Every beat is observed once and beats with i % 29 == 28 are followed by one held
    beat (in_valid low) that repeats every published value with y_vld = 0.
Observed word order per beat, matching the testbench fold:
    fs_last, yw, yb, {oor_w, oor_b, oor, ch_last, sel_last, y_vld}, cfg_id,
    then clip_count and the observation count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

SH = 9
WB = 8
BB = 16
PW = 24
BEATS = 280
SEED = 0xC0FFEE11

MULT = (0x380, 0x0C0, 0x200, 0x1A0, 0x060, 0x2C0, 0x0FF, 0x0F80)
ADDT = (0x0020, 0xFF80, 0x0FC0, 0x7FF0, 0x0000, 0x0380, 0xF040, 0x8010)
CFG_ID = ((SH << 24) | (WB << 16) | (BB << 8) | 0x2C) & MASK32


def main():
    state = SEED
    yw = 0
    yb = 0
    fs_last = 0
    y_vld = 0
    sel_last = 0
    ch_last = 0
    oor_last = 0
    oor_w = 0
    oor_b = 0
    clip_count = 0
    words = []
    nb = 0

    def fold():
        flags = (
            ((oor_w & 1) << 7)
            | ((oor_b & 1) << 6)
            | ((oor_last & 1) << 5)
            | ((ch_last & 7) << 2)
            | ((sel_last & 1) << 1)
            | (y_vld & 1)
        )
        words.append(u(fs_last, PW))
        words.append(u(yw, WB))
        words.append(u(yb, BB))
        words.append(flags)
        words.append(CFG_ID)

    for i in range(BEATS):
        state = lcg32(state)
        ch = i % 8
        sel = (i // 3) % 2
        xpat = state & 0xFFF
        slot = i % 64

        if slot == 3:
            xpat = 0x000
        if slot == 7:
            xpat = 0x7FF
        if slot == 15:
            xpat = 0x800
        if slot == 23:
            ch, sel, xpat = 0, 0, 0x7FF
        if slot == 25:
            ch, sel, xpat = 0, 0, 0x800
        if slot == 31:
            ch, sel, xpat = 3, 1, 0x200
        if slot == 33:
            ch, sel, xpat = 7, 1, 0x201
        if slot == 39:
            ch, sel, xpat = 3, 0, 0x008
        if slot == 41:
            ch, sel, xpat = 3, 1, 0x008
        if slot == 47:
            ch, sel, xpat = 3, 0, u(-8, 12)
        if slot == 53:
            ch, sel, xpat = 2, 1, 0x000
        if slot == 59:
            ch, sel, xpat = 7, 0, 0x800
        if slot == 61:
            ch, sel, xpat = 6, 1, 0x7FF

        a = s(xpat, 12)
        m = s(MULT[ch], 12)
        prod = s(a * m, PW)
        rnd = s(prod + (1 << (SH - 1)), PW)
        q = rnd >> SH
        fs = s(q + s(ADDT[ch], 16), PW) if sel else s(q, PW)

        wfit = s(s(fs, WB), WB) == fs
        bfit = s(s(fs, BB), BB) == fs
        oor = 0 if (wfit if not sel else bfit) else 1

        if wfit:
            wval = s(fs, WB)
        else:
            wval = -(1 << (WB - 1)) if fs < 0 else (1 << (WB - 1)) - 1
        if bfit:
            bval = s(fs, BB)
        else:
            bval = -(1 << (BB - 1)) if fs < 0 else (1 << (BB - 1)) - 1
        # Each path refreshes only its own register, so the other one holds.
        if sel:
            yb = bval
        else:
            yw = wval

        fs_last = fs
        sel_last = sel
        ch_last = ch
        oor_last = oor
        y_vld = 1
        if oor:
            clip_count = u(clip_count + 1, 8)
            if sel:
                oor_b = 1
            else:
                oor_w = 1

        fold()
        nb += 1

        if i % 29 == 28:
            # Held beat: in_valid low, so only the valid echo falls back.
            y_vld = 0
            fold()
            nb += 1

    words.append(clip_count)
    words.append(nb)

    emit('ips_bn_fold_lut', words)


if __name__ == '__main__':
    main()
