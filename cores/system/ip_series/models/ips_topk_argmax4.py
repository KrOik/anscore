"""Independent golden model for ips_topk_argmax4.

Written from the core's documented contract (one candidate score per beat, NSC beats
per vector, a four-lane descending insertion list built from compares and muxes only,
an empty lane always accepting, an equal score accepted only when its index is
smaller, every lane above the insertion point shifting down by one, a vector's first
beat starting from an empty list whose other lanes read the sentinel pair, and the
list holding still when a score does not make it) and never from simulation output
(docs/IP_CORE_SOP.md trap T1).  Integer comparisons only -- no float, no numpy, no
arithmetic wider than the counters.

Geometry rewrites the RTL defaults:
    SW, NSC, IB = 12, 16, 4          MIN_SC = -2048 (12'h800), MAX_IX = 15 (4'hf)

Stimulus contract shared with sim/tb_ips_topk_argmax4.v:
    state = state*1664525 + 1013904223 (mod 2**32), seeded with 0x7AC10003, one step
    per consumed beat; p = b % 16, vec = b // 16, idx = (p*5 + vec) % 16 and the score
    pattern of vec % 6 (0 full random 12 bits, 1 nibble-coarse, 2 three-bit-coarse with
    the low bits set, 3 all +2047, 4 all -2048, 5 two levels +-(100) split at p = 8),
    with p = 3, 7, 11, 13 overriding the score with 0, +2047, -2048 and +1.
    Every consumed beat is observed once and beats with b % 27 == 26 are followed by
    one held beat (in_valid low) that repeats every published value with in_last = 0.
Observed word order per beat, matching the testbench fold:
    {i3,i2,i1,i0}, {t3,t2}, {t1,t0},
    {v3,v2,v1,v0,done,rep_last,drop_last,in_last}, {beat_last,pos_last}, cfg_id,
    then drop_count, rep_count and the observation count.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ips_model_common import MASK32, emit, lcg32, s, u

SW = 12
NSC = 16
IB = 4
NW = 4
CB = 256
SEED = 0x7AC10003

MIN_SC = s(0x800, SW)
MAX_IX = (1 << IB) - 1
CFG_ID = ((SW << 24) | (NSC << 16) | (IB << 8) | 0x7D) & MASK32


def main():
    state = SEED
    t = [MIN_SC] * NW
    ix = [MAX_IX] * NW
    v = [0] * NW
    beat = 0
    drop_count = 0
    rep_count = 0
    done = 0
    rep_last = 0
    drop_last = 0
    in_last = 0
    pos_last = NW
    beat_last = 0
    words = []
    nb = 0

    def fold():
        ws = [
            ((ix[3] & 0xF) << 12) | ((ix[2] & 0xF) << 8)
            | ((ix[1] & 0xF) << 4) | (ix[0] & 0xF),
            (u(t[3], SW) << SW) | u(t[2], SW),
            (u(t[1], SW) << SW) | u(t[0], SW),
            ((v[3] & 1) << 7) | ((v[2] & 1) << 6) | ((v[1] & 1) << 5) | ((v[0] & 1) << 4)
            | ((done & 1) << 3) | ((rep_last & 1) << 2) | ((drop_last & 1) << 1) | (in_last & 1),
            ((beat_last & 0x1F) << 3) | (pos_last & 0x7),
            CFG_ID,
        ]
        if os.environ.get('IPSDBG'):
            print('S ' + ' '.join('%08x' % w for w in ws))
        for w in ws:
            words.append(w)

    for b in range(CB):
        state = lcg32(state)
        p = b % NSC
        vec = b // NSC
        idx = (p * 5 + vec) % NSC

        pv = vec % 6
        if pv == 0:
            xpat = state & 0xFFF
        elif pv == 1:
            xpat = ((state >> 8) & 0xF) << 8
        elif pv == 2:
            xpat = ((state >> 9) & 0x7) << 9
        elif pv == 3:
            xpat = 0x7FF
        elif pv == 4:
            xpat = 0x800
        else:
            xpat = u(100 if p < 8 else -100, SW)
        if p == 3:
            xpat = 0x000
        if p == 7:
            xpat = 0x7FF
        if p == 11:
            xpat = 0x800
        if p == 13:
            xpat = 0x001
        sc = s(xpat, SW)

        first = beat == 0
        ev = [0 if first else v[k] for k in range(NW)]
        gt = [1 if sc > t[k] else 0 for k in range(NW)]
        tie = [
            1 if (ev[k] and sc == t[k] and idx < ix[k]) else 0
            for k in range(NW)
        ]
        acc = [1 if (not ev[k]) or gt[k] or tie[k] else 0 for k in range(NW)]

        pos = NW
        for k in range(NW):
            if acc[k]:
                pos = k
                break
        ins = pos < NW
        rep = 1 if (ins and tie[pos]) else 0
        drop = 1 if pos == NW else 0

        nt = [0] * NW
        ni = [0] * NW
        nv = [0] * NW
        for k in range(NW):
            if pos == k:
                nt[k] = sc
                ni[k] = idx
                nv[k] = 1
            elif k == 0:
                nt[k] = t[k]
                ni[k] = ix[k]
                nv[k] = ev[k]
            elif first:
                nt[k] = MIN_SC
                ni[k] = MAX_IX
                nv[k] = 0
            elif pos < k:
                nt[k] = t[k - 1]
                ni[k] = ix[k - 1]
                nv[k] = ev[k - 1]
            else:
                nt[k] = t[k]
                ni[k] = ix[k]
                nv[k] = ev[k]

        last_beat = beat
        beat = 0 if beat == NSC - 1 else beat + 1
        t, ix, v = nt, ni, nv
        pos_last = pos
        beat_last = last_beat
        done = 1 if last_beat == NSC - 1 else 0
        rep_last = rep
        drop_last = drop
        in_last = 1
        if rep:
            rep_count = u(rep_count + 1, 8)
        if drop:
            drop_count = u(drop_count + 1, 8)

        fold()
        nb += 1

        if b % 27 == 26:
            # Held beat: in_valid low, so only the valid echo and the done pulse
            # fall back; the entries and the last-beat flags stay put.
            in_last = 0
            done = 0
            fold()
            nb += 1

    words.append(drop_count)
    words.append(rep_count)
    words.append(nb)
    if os.environ.get('IPSDBG'):
        print('T %08x %08x %08x' % (drop_count, rep_count, nb & MASK32))

    emit('ips_topk_argmax4', words)


if __name__ == '__main__':
    main()
