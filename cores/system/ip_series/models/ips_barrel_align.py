"""Independent golden model for ips_barrel_align (ip_series_20k).

The contract being modelled is the one written in the spec sentence and in the
module header of src/ips_barrel_align.v: a 64-bit stream word `cur` and its
neighbour `nxt` are re-aligned by a bit offset `amt` (0..MAXOFF = 7) under a
numeric function mode fmode = {dir, rot}:

    00  extract right : (cur >> amt) | (nxt[amt-1:0] << (64-amt))
    01  rotate right  : (cur >> amt) | (cur << (64-amt))
    10  shift left    : cur << amt
    11  rotate left   : (cur << amt) | (cur >> (64-amt))

This file reaches that behaviour with plain integer shifts and masks; the RTL
gets there by placing cur inside a 79-bit guard window and running one
4-stage shrinking-width extract cascade (71, 67, 65, 64 muxes) whose read index
is s = PLACE +/- amt.  Neither side copies the other's structure, which is the
point of the golden-model station (docs/IP_CORE_SOP.md trap T1).

Everything the core registers is reproduced here, on enabled clocks only, and
folded in the exact word order the testbench folds.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ips_model_common import emit, u  # noqa: E402

# --- shipped parameter defaults (mirrored from src/ips_barrel_align.v) --------
WIDTH = 64
MAXOFF = WIDTH // 8 - 1          # 7
PLACE = MAXOFF + 1               # 8
MARK_VALUE = 0x5C1A7E3D
MARK_SHIFT = 0
MARK_MASK = 0x000000FF

DBITS = WIDTH // 8               # 8 reported dropped bits
M64 = (1 << WIDTH) - 1
GUARD_HI = MAXOFF                # bits of nxt that can be refilled

# --- testbench phase table ----------------------------------------------------
NBEATS = 208
S_P1, S_P2, S_P3, S_P4, S_P5 = 16, 32, 48, 64, 80
S_P6, S_P7, S_P8, S_P9, S_P10 = 96, 112, 128, 144, 160
S_P11, S_P12 = 176, 192
MARK_BYTE = MARK_VALUE & 0xFF    # 0x3D


def swrd(k):
    """Stream word n: two 32-bit halves, the same split the TB uses."""
    k &= 0xFFFF
    lo = (((k * 0x01017A57) & 0xFFFFFFFF) ^ 0x9E3779B9) & 0xFFFFFFFF
    hi = (((k * 0xC2B2AE3D) & 0xFFFFFFFF) ^ 0x85EBCA6B) & 0xFFFFFFFF
    return u((hi << 32) | lo, WIDTH)


def stimulus(beat):
    """(clk_en, cur, nxt, amt, fmode) driven on this beat."""
    if beat < S_P1:
        return 1, swrd(beat), swrd(beat + 1), beat % 8, 0
    j = beat - S_P1
    if beat < S_P2:
        return 1, swrd(beat + 3), swrd(beat + 4), 7 - (j % 8), 1
    j = beat - S_P2
    if beat < S_P3:
        return 1, swrd(beat + 7), swrd(beat), j % 8, 2
    j = beat - S_P3
    if beat < S_P4:
        return 1, swrd(beat + 11), swrd(beat + 5), (j * 3) % 8, 3
    j = beat - S_P4
    if beat < S_P5:
        return 1, swrd(beat), swrd(beat + 1), (j * 5) % 8, j % 4
    j = beat - S_P5
    if beat < S_P6:
        return 1, 1 << (7 - (j % 8)), 0, j % 8, 0
    j = beat - S_P6
    if beat < S_P7:
        a = j % 8
        field = MARK_BYTE << a
        base = swrd(beat)
        if j < 8:
            cur = (base & ~field) | field
        else:
            cur = base & ~field
        return 1, u(cur, WIDTH), swrd(beat + 1), a, 0
    j = beat - S_P7
    if beat < S_P8:
        k = j % 8
        return 1, (1 << 63) >> k, swrd(beat + 2), 7 - k, 2
    j = beat - S_P8
    if beat < S_P9:
        return 0, swrd(beat + 13), swrd(beat), (j * 7) % 8, j % 4
    j = beat - S_P9
    if beat < S_P10:
        return 1, swrd(beat + 5), swrd(beat + 6), j % 8, (0 if j < 8 else 2)
    j = beat - S_P10
    if beat < S_P11:
        return 1, M64, 0, 7, j % 4
    j = beat - S_P11
    if beat < S_P12:
        return 1, 0, M64, j % 8, (0 if j < 8 else 1)
    j = beat - S_P12
    return 1, swrd(beat + 17), swrd(beat + 19), j % 8, 1


def ealign(cur, nxt, amt, fmode):
    """Aligned word, from the spec sentence."""
    direction = (fmode >> 1) & 1
    rotate = fmode & 1
    low = (1 << amt) - 1
    if direction == 0:
        src = cur if rotate else (nxt & low)
        return u((cur >> amt) | ((src & low) << (WIDTH - amt)), WIDTH)
    src = cur if rotate else 0
    return u(((cur << amt) | (src >> (WIDTH - amt))) & M64, WIDTH)


def edrop(cur, amt, fmode):
    """Value of the bits that left the datapath (MSB aligned for dir=1)."""
    if fmode & 1:
        return 0
    mask = ((1 << amt) - 1) & u(0xFF, DBITS)
    if (fmode >> 1) & 1:
        return u((cur >> (WIDTH - DBITS)) & (mask << (DBITS - amt)), DBITS)
    return u(cur & mask, DBITS)


def epos(amt, fmode):
    """Extract index the window geometry implies."""
    return u(PLACE - amt if (fmode >> 1) & 1 else PLACE + amt, 4)


def mark_ok(align):
    aline = align & 0xFFFFFFFF
    fld = u(aline >> MARK_SHIFT, 32) & MARK_MASK
    ref = u(MARK_VALUE >> MARK_SHIFT, 32) & MARK_MASK
    return 1 if fld == ref else 0


def fold(words, st):
    align = st["align"]
    words.append(u(align, 32))
    words.append(u(align >> 32, 32))
    words.append(0)                                  # align_q headroom nibble
    words.append(u(st["pos"], 32))
    words.append(u(st["drop"], 32))
    words.append(u((st["hits"] << 4) | st["beats"], 32))
    words.append(u((st["cfg"] << 3) | (st["mstick"] << 2) | (st["dstick"] << 1), 32))


def main():
    st = dict(align=0, pos=0, drop=0, dstick=0, beats=0, hits=0, mstick=0, cfg=0)
    words = []
    for beat in range(NBEATS):
        clk_en, cur, nxt, amt, fmode = stimulus(beat)
        if clk_en:
            align = ealign(u(cur, WIDTH), u(nxt, WIDTH), amt, fmode)
            drop = edrop(u(cur, WIDTH), amt, fmode)
            st["align"] = align
            st["pos"] = epos(amt, fmode)
            st["drop"] = drop
            if drop:
                st["dstick"] = 1
                if st["beats"] != 0xF:
                    st["beats"] += 1
            if mark_ok(align):
                st["mstick"] = 1
                if st["hits"] != 0xF:
                    st["hits"] += 1
            if amt > MAXOFF:
                st["cfg"] = 1
        # the TB folds every observed state except the one produced by beat 0
        if beat >= 1:
            fold(words, st)

    # tail: the settled flags the testbench folds one more time unconditionally
    fold(words, st)
    words.append(NBEATS)

    emit("ips_barrel_align", words)


if __name__ == "__main__":
    main()
