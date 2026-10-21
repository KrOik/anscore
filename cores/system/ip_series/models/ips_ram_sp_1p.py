"""Independent golden model for ips_ram_sp_1p.

Implements the core's written contract from scratch: a DEPTH x WIDTH array with a
single access port, per-byte write enable on WIDTH/8 lanes, an OUT_REG-deep
read pipeline and the three counters.  One access is issued per beat; the beat
that carries an access also advances the pipeline by one stage, so the datum the
testbench folds at the end of a beat is the read issued one beat earlier:

    stage0 <= read of the current beat      stage1 <= stage0 of the previous beat

with STAGES = OUT_REG + 1 stages and rdata taken from stage OUT_REG.  The array
is a Python list, so an entry the RTL never wrote would read back as 0 here while
the DUT shows X on its read port; the testbench is required to write before it
reads, exactly as docs/IP_CORE_SOP.md trap T6 demands.

The model never reads simulation output; the gate compares the two digests
(SOP trap T1).  Stimulus contract shared with sim/tb_ips_ram_sp_1p.v: the same
216-beat plan (sweep write, byte-lane write, warm read pass, folded read pass,
top_sel pass, alternating-top_sel pass, deselected-write phase, idle tail) with

    wdat(a) = ((a * 0x01010101) ^ 0x9E3779B9) mod 2**32, replaced at a = 31 by the
              exact MATCH word, at a = 30 by a word that differs only in the byte
              below bit SHIFT and at a = 29 by one that differs above it
    bdat(j) = ((j * 0x00FF00FF) ^ 0xC2B2AE3C) mod 2**32

Folded word order per observed beat, then the tail, matches the testbench fold:
the read datum, the headroom byte of the testbench's over-wide rdata wire (which
carries no data at the shipped WIDTH, so 0), and the reported address.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

WIDTH = 32
ADDR_BITS = 5
DEPTH = 1 << ADDR_BITS
OUT_REG = 1
BYTES = WIDTH // 8
MATCH = 0xA5A55A5A
SHIFT = 8
STAGES = OUT_REG + 1

NW = 16
S_W = 0
S_BW = 32
S_R1 = 64
S_R2 = 96
S_TOP = 128
S_ALT = 160
S_ERR = 192
S_IDL = 208
NBEATS = 216

WMASK = (1 << WIDTH) - 1
AMASK = (1 << ADDR_BITS) - 1
PIPE_MASK = (1 << (STAGES * WIDTH)) - 1
RA_MASK = (1 << (STAGES * ADDR_BITS)) - 1


def wdat(a):
    v = ((a & 0xFF) * 0x01010101) ^ 0x9E3779B9
    if a == 31:
        v = 0xA5A55A5A
    elif a == 30:
        v = 0xA5A55A5B
    elif a == 29:
        v = 0xA5A55B5A
    return v & WMASK


def bdat(j):
    return ((j & 0xFF) * 0x00FF00FF) ^ 0xC2B2AE3C


def stimulus(beat):
    """One beat of the documented plan: (ce, we, be, waddr, raddr, top_sel, wdata, fold)."""
    if beat < S_BW:
        return (1, 1, 0xF, beat % DEPTH, 0, 0, wdat(beat), False)
    if beat < S_R1:
        j = beat - S_BW
        be = 0x5 if j < NW else 0xA
        return (1, 1, be, j % NW, 0, 0, bdat(j), False)
    if beat < S_R2:
        return (1, 0, 0x0, 0, (beat - S_R1) % DEPTH, 0, 0, False)
    if beat < S_TOP:
        return (1, 0, 0x0, 0, (beat - S_R2) % DEPTH, 0, 0, True)
    if beat < S_ALT:
        return (1, 0, 0x0, 0, (beat - S_TOP) % DEPTH, 1, 0, True)
    if beat < S_ERR:
        return (1, 0, 0x0, 0, (beat - S_ALT) % DEPTH, beat & 1, 0, True)
    if beat < S_IDL:
        return (0, 1, 0x0, 0, 0, 0, 0, False)
    return (0, 0, 0x0, 0, 0, 0, 0, False)


def main():
    mem = [0] * DEPTH
    rd_pipe = 0
    ra_pipe = 0
    hit = 0
    guard = 0
    accesses = 0
    error_sticky = 0
    words = []

    for beat in range(NBEATS):
        ce, we, be, waddr, raddr, top_sel, wdata, fold = stimulus(beat)

        if ce and we:
            cell = mem[waddr]
            for lane in range(BYTES):
                if (be >> lane) & 1:
                    shift = lane * 8
                    mask = 0xFF << shift
                    cell = (cell & ~mask) | (wdata & mask)
            mem[waddr] = cell & WMASK

        load = ce and not we
        r_addr = (DEPTH - 1) if top_sel else raddr
        rd_raw = mem[r_addr] & WMASK

        rd_next = (rd_pipe << WIDTH) & PIPE_MASK
        ra_next = (ra_pipe << ADDR_BITS) & RA_MASK
        if load:
            rd_next = (rd_next & ~WMASK) | rd_raw
            ra_next = (ra_next & ~AMASK) | (r_addr & AMASK)
            accesses = (accesses + 1) & 0xFFFF
            if rd_raw == MATCH:
                hit = (hit + 1) & 0xFF
            if (rd_raw >> SHIFT) == (MATCH >> SHIFT):
                guard = (guard + 1) & 0xFF
        if we and not ce:
            error_sticky = 1

        rd_pipe = rd_next
        ra_pipe = ra_next

        rdata = (rd_pipe >> (OUT_REG * WIDTH)) & WMASK
        raddr_q = (ra_pipe >> (OUT_REG * ADDR_BITS)) & AMASK
        if fold:
            words.append(rdata)
            words.append(0)
            words.append(raddr_q)

    words.append((rd_pipe >> (OUT_REG * WIDTH)) & WMASK)
    words.append(0)
    words.append((ra_pipe >> (OUT_REG * ADDR_BITS)) & AMASK)
    words.append(hit)
    words.append(guard)
    words.append(accesses)
    words.append(error_sticky)
    words.append(NBEATS)

    emit('ips_ram_sp_1p', words)


if __name__ == '__main__':
    main()
