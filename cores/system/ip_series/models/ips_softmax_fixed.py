"""Independent golden model for ips_softmax_fixed.

Written from the core's documented contract (three self-scheduled passes over
LANES signed LB-bit logits: a running maximum, a max-subtract exp-LUT sum with the
table index saturated to 0..15, then reciprocal-normalised probabilities
p = clamp((EXP[delta] * REC[rsum >> 8]) >> 8) with a sticky clip flag and a
sum-check residual psum - 255) and never from simulation output
(docs/IP_CORE_SOP.md trap T1).  Integer fixed-point only: the tables below are
design constants restated, not evaluated with a float exponential.

Table constants:
    EXP[d] = round(255 * exp(-d/2))          d = 0..15
    REC[b] = floor(65280 / (b*256 + 128))    b = 0..15
Vector state (rmax, rsum, psum, sat_sticky) reinitialises on the first lane of
pass 0, so the finished sums are still observable on the last pass-2 beat.

Stimulus contract shared with sim/tb_ips_softmax_fixed.v:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0x5C0FFEE1, one
    step per lane at the start of every vector, raw = the stepped state.
    pattern v % 6: 0 lg = 64 - lane, 1 lg = 100, 2 lg = raw & 0xff,
                   3 lg = 0 for lane 0 else -2048, 4 lg = 2047 for lanes 0..2 else
                   -2048, 5 lg = (raw & 0xff) - 128; all truncated to 12 bits.
    Vector i is streamed as PBS = 48 beats, lane = (i % 48) % 16, and every 16th
    beat is followed by one extra beat with in_valid low that must change nothing.
Observed word order per beat, matching the testbench fold:
    rmax, rsum, {exp_last, p}, {ph_last, p_vld, sat_sticky}, resid, cfg_id,
    then clip_count and the beat count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

LANES = 16
LB = 12
PB = 8
PBS = 48
NVEC = 8
NB = NVEC * PBS
SEED = 0x5C0FFEE1

EXP = (255, 155, 94, 57, 35, 21, 13, 8, 5, 3, 2, 1, 1, 0, 0, 0)
REC = (510, 170, 102, 72, 56, 46, 39, 34, 30, 26, 24, 22, 20, 18, 17, 16)

IDEAL = 255
RAIL = (1 << PB) - 1
CFG_ID = ((LANES << 24) | (LB << 16) | (PB << 8) | 0x5F) & MASK32


def delta_of(rmax, lg):
    """The saturated exp-LUT index, mirroring dif = rmax - lg in LB+1 bits."""
    d = rmax - lg
    if d < 0:
        return 0
    if d > 15:
        return 15
    return d


def main():
    state = SEED
    lane = 0
    ph = 0
    rmax = 0
    rsum = 0
    psum = 0
    exp_last = 0
    p = 0
    p_vld = 0
    sat = 0
    clip = 0
    lga = [0] * LANES
    words = []
    nb = 0

    for i in range(NB):
        if i % PBS == 0:
            v = i // PBS
            for l in range(LANES):
                state = lcg32(state)
                if v % 6 == 0:
                    lga[l] = u(64 - l, LB)
                elif v % 6 == 1:
                    lga[l] = u(100, LB)
                elif v % 6 == 2:
                    lga[l] = u(state & 0xFF, LB)
                elif v % 6 == 3:
                    lga[l] = u(0 if l == 0 else -2048, LB)
                elif v % 6 == 4:
                    lga[l] = u(2047 if l < 3 else -2048, LB)
                else:
                    lga[l] = u((state & 0xFF) - 128, LB)

        lg = s(lga[(i % PBS) % LANES], LB)
        ph_last = ph
        p_vld = 0

        if ph == 0:
            if lane == 0:
                rmax = lg
                rsum = 0
                psum = 0
                sat = 0
            elif lg > rmax:
                rmax = lg
        else:
            exp_last = EXP[delta_of(rmax, lg)]
            if ph == 1:
                rsum = (rsum + exp_last) & 0x1FFF
            else:
                rrec = REC[(rsum >> 8) & 0xF]
                praw = (exp_last * rrec) >> 8
                if praw > RAIL:
                    pfin = RAIL
                    sat = 1
                    clip = (clip + 1) & 0xFF
                else:
                    pfin = praw & RAIL
                p = pfin
                p_vld = 1
                psum = (psum + u(pfin, 13)) & 0x1FFF

        if lane == LANES - 1:
            lane = 0
            ph = 0 if ph == 2 else ph + 1
        else:
            lane += 1

        words.append(u(rmax, LB))
        words.append(u(rsum, 13))
        words.append((u(exp_last, 8) << PB) | u(p, PB))
        words.append((u(ph_last, 2) << 2) | (u(p_vld, 1) << 1) | u(sat, 1))
        words.append(u(psum - IDEAL, 14))
        words.append(CFG_ID)
        nb += 1

        if i % 16 == 15:
            # in_valid low: every published value simply repeats.
            words.append(u(rmax, LB))
            words.append(u(rsum, 13))
            words.append((u(exp_last, 8) << PB) | u(p, PB))
            words.append((u(ph_last, 2) << 2) | (u(p_vld, 1) << 1) | u(sat, 1))
            words.append(u(psum - IDEAL, 14))
            words.append(CFG_ID)
            nb += 1

    words.append(clip)
    words.append(nb)

    emit('ips_softmax_fixed', words)


if __name__ == '__main__':
    main()
