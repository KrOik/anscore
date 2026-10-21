"""Independent golden model for ips_reciprocal_lut.

Written from the core's documented contract, not from simulation output
(docs/IP_CORE_SOP.md trap T1): a 12-bit denominator is normalised with a
leading-zero shift, a 9-entry reciprocal ROM is read twice and linearly
interpolated to give a seed estimate, one Newton-Raphson step refines it, and a
comparison of the seed product against 2**(2*FRAC) flags exact division.
Denominator zero is the undefined reciprocal: recip/rnshift/nflag/exact publish
0, r0/resid publish the deterministic dn = 0 datapath values, err pulses and
sticky latches.

Contract as implemented by src/ips_reciprocal_lut.v and observed by
sim/tb_ips_reciprocal_lut.v, all unsigned and every register width truncated to
the shipped datapath width DW = FRAC + 2 = 14 bits:
    nsh  = leading zeros of den, dn = den << nsh (bit FRAC-1 set)
    ridx = dn[FRAC-2 -: IDXB],  rwt = dn[WBITS-1:0]
    v(i) = 2**(2*FRAC-1) // (2**(FRAC-1) + 2**(FRAC-1-IDXB) * i)
    diff = v(ridx) - v(ridx+1)
    seed = v(ridx) - BASE - ((diff * rwt) >> WBITS),   BASE = 2**(FRAC-1)
    r0   = (seed << 1) + UNIT,                         UNIT = 2**FRAC
    p12  = (dn * r0) >> FRAC
    resid = UNIT + UNIT - p12
    recip = (r0 * resid) >> FRAC        (0 for the divide-by-zero operation)
    exact = (dn * r0 == EQ),            EQ = 2**(2*FRAC)

Stimulus contract shared with sim/tb_ips_reciprocal_lut.v:
    state = state * 1664525 + 1013904223 (mod 2**32) from 0x2EC1F00D, one draw
    per operation with den = state[11:0]; directed overrides on m = i % 64 are
    0 -> 0x000, 1 -> 0x001, 2 -> 0x800, 3 -> 0xFFF, 7 -> 0x7FF, 11 -> 0x400,
    15 -> 0x008, 19 -> 0xAAA, 23 -> 0xFFE, 27 -> 0x002, 31 -> 0xC00,
    35 -> 0x801, 39 -> 0x401, 43 -> 0x7FE, 47 -> 0x155, 51 -> 0x2AA,
    55 -> 0x5FF, 59 -> 0x040, 63 -> 0x100.

Observed word order per published operation, matching the testbench fold:
    recip, r0, resid, {rnshift, nflag, exact, err, sticky}, {ridx, rwt}, done,
then done, sticky, OPS.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, u

FRAC = 12
IDXB = 3
WBITS = 8
OPS = 256
SEED = 0x2EC1F00D

DW = FRAC + 2                       # the shipped [FRAC+1:0] datapath registers
UNIT = 1 << FRAC                    # 2**FRAC
BASE = 1 << (FRAC - 1)              # 2**(FRAC-1), the ROM bias
EQ = 1 << (2 * FRAC)                # the exact-division target
ROM_TOP = 1 << (2 * FRAC - 1)       # the ROM scale, 2**(2*FRAC-1)
ROM_STEP = 1 << (FRAC - 1 - IDXB)   # one ROM bin width, 256 for the defaults

# the testbench samples recip/r0/resid, ridx and rwt one bit wider than the
# shipped ports, so a width change of FRAC/IDXB/WBITS moves real bits into the
# fold instead of being swallowed by the fixed layout
TB_EXTRA_BITS = 1


def rom(i):
    """v(i) = floor(2**(2*FRAC-1) / (2**(FRAC-1) + 2**(FRAC-1-IDXB) * i))."""
    return ROM_TOP // (BASE + ROM_STEP * i)


def normalize(den):
    """Leading-zero count and normalized denominator of the RTL shift chain."""
    nsh = 0
    while nsh < FRAC and not (den >> (FRAC - 1 - nsh)) & 1:
        nsh += 1
    if nsh == FRAC:                     # den == 0: the RTL chain reaches 8+4+2+1
        return 15, 0                    # and leaves dn at zero
    dn = (den << nsh) & ((1 << FRAC) - 1)
    return nsh, dn


def run_op(den, sticky):
    """One operation; returns the published observables."""
    abrt = 1 if den == 0 else 0
    nsh, dn = normalize(den)
    ridx = (dn >> (FRAC - 1 - IDXB)) & ((1 << IDXB) - 1)
    rwt = dn & ((1 << WBITS) - 1)

    t0 = u(rom(ridx), DW)
    diff = u(t0 - rom(ridx + 1), DW)
    prod0 = diff * rwt
    seed = u(t0 - BASE - (prod0 >> WBITS), DW)
    r0 = u((seed << 1) + UNIT, DW)

    prod1 = u(dn, DW) * r0
    p12 = u(prod1 >> FRAC, DW)
    resid = u(UNIT + UNIT - p12, DW)
    recip = 0 if abrt else u((r0 * resid) >> FRAC, DW)
    exact = 1 if prod1 == EQ else 0

    rnshift = 0 if abrt else nsh
    nflag = 0 if abrt else (1 if nsh != 0 else 0)
    sticky = 1 if (sticky or abrt) else 0
    return dict(recip=recip, r0=r0, resid=resid, ridx=ridx, rwt=rwt,
                rnshift=rnshift, nflag=nflag, exact=exact, err=abrt,
                sticky=sticky)


def den_for(i, state):
    den = state & ((1 << FRAC) - 1)
    m = i % 64
    directed = {0: 0x000, 1: 0x001, 2: 0x800, 3: 0xFFF, 7: 0x7FF, 11: 0x400,
                15: 0x008, 19: 0xAAA, 23: 0xFFE, 27: 0x002, 31: 0xC00,
                35: 0x801, 39: 0x401, 43: 0x7FE, 47: 0x155, 51: 0x2AA,
                55: 0x5FF, 59: 0x040, 63: 0x100}
    if m in directed:
        den = directed[m] & ((1 << FRAC) - 1)
    return den


def main():
    state = SEED
    sticky = 0
    done = 0
    words = []

    for i in range(OPS):
        state = (state * 1664525 + 1013904223) & MASK32
        den = den_for(i, state)
        o = run_op(den, sticky)
        sticky = o['sticky']
        done = (done + 1) & 0xFF

        words.append(u(o['recip'], DW + TB_EXTRA_BITS))
        words.append(u(o['r0'], DW + TB_EXTRA_BITS))
        words.append(u(o['resid'], DW + TB_EXTRA_BITS))
        words.append((o['rnshift'] << 4) | (o['nflag'] << 3) |
                     (o['exact'] << 2) | (o['err'] << 1) | o['sticky'])
        words.append((o['ridx'] << (WBITS + TB_EXTRA_BITS)) | o['rwt'])
        words.append(done)

    words.append(done)
    words.append(sticky)
    words.append(OPS)

    emit('ips_reciprocal_lut', words)


if __name__ == '__main__':
    main()
