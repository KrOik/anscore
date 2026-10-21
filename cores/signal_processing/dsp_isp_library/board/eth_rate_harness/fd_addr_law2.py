"""framediff: which reference-RAM address law reproduces the board?

The RTL reads pixel p's reference and commits pixel p-1's write on the SAME
clock edge, so a faithful model must apply each write one cycle after the
matching read (read-old).  With that timing right, a candidate law is just a
transform of the read address and/or the write address.  Every archived board
block is replayed through each law and scored against the recorded words; the
identity law is first checked to reproduce the shipped model bit for bit.
"""
import json, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
from fd_diag import load, NP, model_trace


def run_addr(words, sel, rd_f=lambda a: a, wr_f=lambda a: a, depth=16):
    mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[sel]
    ram = [0] * depth
    bg_valid, fa = 0, 0
    out, prev = [], []          # prev: write queued for next cycle
    for f in range(len(words) // NP):
        chg = 0
        for p in range(NP):
            y, x = divmod(p, 4)
            cur = words[f * NP + p] & 0xFF
            if prev:                        # commit the previous pixel's write
                wa, v = prev[0]
                ram[wa & (depth - 1)] = v
                prev = []
            r = ram[rd_f(p) & (depth - 1)]
            sd = cur - r
            ad = abs(sd)
            nbg = (r + (sd >> (0 if fa else alpha))) & 0xFF
            new_ref = cur if (not bg_valid or mode == 0) else nbg
            moved = 1 if (bg_valid and ad > thr) else 0
            outpix = new_ref if mode == 1 else (0xFF if moved else 0)
            prev.append((wr_f(p), new_ref))
            chg += moved
            hit = (p == NP - 1) and bg_valid and ((chg << 7) > 16 * scn)
            out.append((outpix & 0xFF) | (1 if p == 0 else 0) << 8
                       | (1 if x == 3 else 0) << 9 | ((1 if hit else 0) << 11))
            if p == NP - 1:
                bg_valid, fa = (pol, pol) if hit else (1, 0)
    return out


LAWS = [
    ('identity',      lambda a: a,            lambda a: a),
    ('rd&~1',         lambda a: a & ~1,       lambda a: a),
    ('rd&~3',         lambda a: a & ~3,       lambda a: a),
    ('rd|1',          lambda a: a | 1,        lambda a: a),
    ('wr&~1',         lambda a: a,            lambda a: a & ~1),
    ('both&~1',       lambda a: a & ~1,       lambda a: a & ~1),
    ('rd<<1',         lambda a: (a << 1) & 15, lambda a: a),
    ('rd^1',          lambda a: a ^ 1,        lambda a: a),
    ('rd bitrev0-1',  lambda a: (a & ~3) | ((a << 1) & 3), lambda a: a),
]


def main():
    rounds = [Path(a) for a in sys.argv[1:]] or [
        HERE / 'evidence/board_v4_framediff_20261003/round_01']
    allc = [(rd.parent.name, c) for rd in rounds for c in load(str(rd))]
    # self-check: the faithful identity model must equal the shipped oracle
    bad_self = 0
    for rnd, c in allc:
        if run_addr(c['inw'], c['cfg']) != ep.model_oracle(c['cfg'], c['inw'], 7):
            bad_self += 1
    print('faithful-identity vs shipped oracle: %d/%d cases differ'
          % (bad_self, len(allc)))
    print('%-28s %-16s %s' % ('round', 'case',
                               ' '.join('%-10s' % l for l, _, _ in LAWS)))
    tot = [0] * len(LAWS)
    exact = [0] * len(LAWS)
    for rnd, c in allc:
        counts = []
        for k, (l, rf, wf) in enumerate(LAWS):
            pred = run_addr(c['inw'], c['cfg'], rf, wf)
            counts.append(sum(1 for i in range(len(pred))
                              if pred[i] != c['board'][i]))
            tot[k] += counts[-1]
            exact[k] += int(counts[-1] == 0)
        print('%-28s %-16s %s' % (rnd, c['name'],
                                  ' '.join('%10d' % v for v in counts)))
    print('\ntotals:')
    for k, (l, _, _) in enumerate(LAWS):
        print('  %-14s words=%5d exact cases=%d/%d' % (l, tot[k], exact[k], len(allc)))


main()
