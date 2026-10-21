"""Independent golden model for ips_ram_dp_1w2r.

Rebuilds the core's written contract from scratch, in Python, without reference to
the RTL structure: an image of the memory duplicated into two banks, one write port
that updates both banks and two read ports that each watch their own bank.  A write
and a read of the same cell in the same access resolves to the newly written word
(write-through) on the port that hits, and all three ports on one cell latches the
conflict flag.  Each port carries its own OUT_REG-deep chain of data, address and
valid slots; an access issued at one beat is what the port reports one beat later,
and a slot of the chain that carried no access reads back as zero.

The model never reads simulation output; the gate compares the two digests
(docs/IP_CORE_SOP.md trap T1).  Stimulus contract shared with
sim/tb_ips_ram_dp_1w2r.v, 208 beats in 13 phases of 16 beats (P0 write sweep,
P1 port-0 read pass, P2 dual opposing passes, P3 both ports on the top override,
P4 port-0 top with port 1 on the guard cell, P5 write/read collision, P6 all three
ports on one cell, P7 dual read-back, P8 port 0 only, P9 port 1 only, P10 clk_en
low with live stimulus, P11 dual read-back again, P12 idle), with

    cell_init(a) = ((a * 0x01010101) ^ 0x9E3779B9) mod 2**32, overridden at
                   a = 15 by the exact MATCH word, a = 14 by a word that differs
                   only in the byte below GUARD_SHIFT, a = 13 by one that differs
                   above it and a = 12 by the collision cell's initial value
    cdat(k)      = ((k * 0x01010101) ^ 0x85EBCA6B) mod 2**32

folded as eight words per folded beat (per port: datum, the headroom byte of the
testbench's over-wide data wire, the reported address, the reported valid flag)
and the tail below.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

WIDTH = 32
ADDR_BITS = 4
DEPTH = 1 << ADDR_BITS
OUT_REG = 1
GUARD_SHIFT = 8
MATCH = 0xA5A55A5A
IDX_BITS = ADDR_BITS + 2
STAGES = OUT_REG + 1

CELL = 12
NPAY = 12
TOPA = DEPTH - 1

S_P0 = 0
S_P1 = 16
S_P2 = 32
S_P3 = 48
S_P4 = 64
S_P5 = 80
S_P6 = 96
S_P7 = 112
S_P8 = 128
S_P9 = 144
S_P10 = 160
S_P11 = 176
S_P12 = 192
NBEATS = 208

WMASK = (1 << WIDTH) - 1
AMASK = (1 << ADDR_BITS) - 1
IMASK = (1 << IDX_BITS) - 1
PMASK = (1 << (STAGES * WIDTH)) - 1
QMASK = (1 << (STAGES * IDX_BITS)) - 1
VMASK = (1 << STAGES) - 1


def cell_init(a):
    v = ((a & 0xFF) * 0x01010101) ^ 0x9E3779B9
    if a == 15:
        v = 0xA5A55A5A
    elif a == 14:
        v = 0xA5A55A5B
    elif a == 13:
        v = 0xA5A55B5A
    elif a == 12:
        v = 0x0C0C0C0C
    return v & WMASK


def cdat(k):
    return (((k & 0xFF) * 0x01010101) ^ 0x85EBCA6B) & WMASK


def phase_start(b):
    if b < S_P1:
        return S_P0
    if b < S_P2:
        return S_P1
    if b < S_P3:
        return S_P2
    if b < S_P4:
        return S_P3
    if b < S_P5:
        return S_P4
    if b < S_P6:
        return S_P5
    if b < S_P7:
        return S_P6
    if b < S_P8:
        return S_P7
    if b < S_P9:
        return S_P8
    if b < S_P10:
        return S_P9
    if b < S_P11:
        return S_P10
    if b < S_P12:
        return S_P11
    return S_P12


def stimulus(b):
    """One beat: (clk_en, wr, waddr, wdata, r0_en, r0_addr, r0_top,
    r1_en, r1_addr, r1_top, fold)."""
    p = phase_start(b)
    k = b - p
    en = 1 if p != S_P10 else 0
    fold = (p != S_P0) and (p != S_P12) and (b >= p + 3)
    wr, wa, wd = 0, 0, 0
    r0e, r0a, r0t = 0, 0, 0
    r1e, r1a, r1t = 0, 0, 0
    if p == S_P0:
        wr, wa, wd = 1, b, cell_init(b)
    elif p == S_P1:
        r0e, r0a = 1, k
    elif p == S_P2:
        r0e, r0a = 1, k
        r1e, r1a = 1, TOPA - k
    elif p == S_P3:
        r0e, r0t = 1, 1
        r1e, r1t = 1, 1
    elif p == S_P4:
        r0e, r0t = 1, 1
        r1e, r1a = 1, 14
    elif p == S_P5:
        wr, wa, wd = 1, CELL, cdat(k)
        r0e, r0a = 1, CELL
        r1e, r1a = 1, (TOPA - k) % NPAY
    elif p == S_P6:
        wr, wa, wd = 1, CELL, cdat(16 + k)
        r0e, r0a = 1, CELL
        r1e, r1a = 1, CELL
    elif p == S_P7:
        r0e, r0a = 1, k
        r1e, r1a = 1, TOPA - k
    elif p == S_P8:
        r0e, r0a = 1, k
    elif p == S_P9:
        r1e, r1a = 1, k
    elif p == S_P10:
        wr, wa, wd = 1, k, cdat(k)
        r0e, r0a = 1, TOPA - k
        r1e, r1a = 1, k % NPAY
    elif p == S_P11:
        r0e, r0a = 1, k
        r1e, r1a = 1, TOPA - k
    return (en, wr, wa, wd, r0e, r0a, r0t, r1e, r1a, r1t, fold)


def main():
    bank0 = [0] * DEPTH
    bank1 = [0] * DEPTH
    p0 = p1 = q0 = q1 = v0 = v1 = 0
    hit = 0
    guard = 0
    reads = 0
    writes = 0
    collides = 0
    conflict = 0
    words = []

    for b in range(NBEATS):
        en, wr, wa, wd, r0e, r0a, r0t, r1e, r1a, r1t, fold = stimulus(b)

        if en:
            a0 = (TOPA if r0t else r0a) & IMASK
            a1 = (TOPA if r1t else r1a) & IMASK
            wfull = wa & IMASK
            col0 = 1 if (wr and r0e and wfull == a0) else 0
            col1 = 1 if (wr and r1e and wfull == a1) else 0
            d0 = wd if col0 else (bank0[a0] & WMASK)
            d1 = wd if col1 else (bank1[a1] & WMASK)

            # both banks take the same write, so they keep one image
            if wr:
                bank0[wa & AMASK] = wd & WMASK
                bank1[wa & AMASK] = wd & WMASK

            np0 = (p0 << WIDTH) & PMASK
            np1 = (p1 << WIDTH) & PMASK
            nq0 = (q0 << IDX_BITS) & QMASK
            nq1 = (q1 << IDX_BITS) & QMASK
            nv0 = (v0 << 1) & VMASK
            nv1 = (v1 << 1) & VMASK
            if r0e:
                np0 = (np0 & ~WMASK) | d0
                nq0 = (nq0 & ~IMASK) | a0
                nv0 |= 1
                if d0 == MATCH:
                    hit = (hit + 1) & 0xFF
            if r1e:
                np1 = (np1 & ~WMASK) | d1
                nq1 = (nq1 & ~IMASK) | a1
                nv1 |= 1
                if (d1 >> GUARD_SHIFT) == (MATCH >> GUARD_SHIFT):
                    guard = (guard + 1) & 0xFF
            reads = (reads + r0e + r1e) & 0xFFFF
            if wr:
                writes = (writes + 1) & 0xFF
            if col0 or col1:
                collides = (collides + 1) & 0xFF
            if col0 and col1:
                conflict = 1
            p0, p1, q0, q1, v0, v1 = np0, np1, nq0, nq1, nv0, nv1

        r0_data = (p0 >> (OUT_REG * WIDTH)) & WMASK
        r0_addr = (q0 >> (OUT_REG * IDX_BITS)) & AMASK
        r0_val = (v0 >> OUT_REG) & 1
        r1_data = (p1 >> (OUT_REG * WIDTH)) & WMASK
        r1_addr = (q1 >> (OUT_REG * IDX_BITS)) & AMASK
        r1_val = (v1 >> OUT_REG) & 1

        if fold:
            words.extend([r0_data, 0, r0_addr, r0_val,
                          r1_data, 0, r1_addr, r1_val])

    words.extend([r0_data, 0, r0_addr, r0_val, r1_data, 0, r1_addr, r1_val])
    words.extend([hit, guard, reads, writes, collides, conflict, NBEATS])

    emit('ips_ram_dp_1w2r', words)


if __name__ == '__main__':
    main()
