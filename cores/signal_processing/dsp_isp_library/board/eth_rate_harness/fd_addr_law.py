"""Test read/write address-transform laws for framediff against archived board words.

The board's BG-mode words decode to a reference value stored at the PRECEDING
even address, which says the distributed-RAM read port lost its LSB in the
mapped netlist.  Score candidate transforms by replaying each archived block
through the model with the transform applied and counting exact case matches.
"""
import json, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
from fd_diag import load, NP


def run_addr(words, sel, rd_mask=None, wr_mask=None, depth=16):
    """Model pass with an address transform: addr -> (addr & ~mask) | ..."""
    mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[sel]
    ram = [0] * depth
    bg_valid, fa = 0, 0
    out = []
    for f in range(len(words) // NP):
        chg = 0
        for p in range(NP):
            y, x = divmod(p, 4)
            cur = words[f * NP + p] & 0xFF
            ra = p if rd_mask is None else (p & ~rd_mask)
            wa = p if wr_mask is None else (p & ~wr_mask)
            r = ram[ra]
            sd = cur - r
            ad = abs(sd)
            step = sd >> (0 if fa else alpha)
            nbg = (r + step) & 0xFF
            new_ref = cur if (not bg_valid or mode == 0) else nbg
            ad_e = ad if bg_valid else 0
            moved = 1 if ad_e > thr else 0
            ram[wa] = new_ref
            outpix = new_ref if mode == 1 else (0xFF if moved else 0)
            chg += moved
            eot = (p == NP - 1)
            hit = eot and bg_valid and ((chg << 7) > 16 * scn)
            sof, eol = (1 if p == 0 else 0), (1 if x == 3 else 0)
            out.append((outpix & 0xFF) | (sof << 8) | (eol << 9)
                       | ((1 if hit else 0) << 11))
            if eot:
                bg_valid, fa = (pol, pol) if hit else (1, 0)
    return out


LAWS = [('clean      ', None, None),
        ('rd bit0->0 ', 1, None),
        ('wr bit0->0 ', None, 1),
        ('both bit0  ', 1, 1),
        ('rd bit1->0 ', 2, None),
        ('rd bit2->0 ', 4, None),
        ('rd bit3->0 ', 8, None),
        ('rd bit0|1  ', 3, None)]


def main():
    rounds = [Path(a) for a in sys.argv[1:]] or [
        HERE / 'evidence/board_v4_framediff_20261003/round_01']
    allcases = []
    for rd in rounds:
        for c in load(str(rd)):
            allcases.append((rd.parent.name, c))
    print('cases with replies: %d' % len(allcases))
    hdr = '%-11s' % 'law'
    for law in LAWS:
        hdr = ''
        break
    for name, c in allcases[:1]:
        pass
    rows = []
    for rnd, c in allcases:
        want = ep.model_oracle(c['cfg'], c['inw'], 7)
        base_bad = sum(1 for i in range(len(want)) if c['board'][i] != want[i])
        res = []
        for label, rm, wm in LAWS:
            pred = run_addr(c['inw'], c['cfg'], rm, wm)
            bad = sum(1 for i in range(len(want)) if pred[i] != c['board'][i])
            res.append(bad)
        rows.append((rnd, c['name'], base_bad, res))
    print('%-30s %-16s %6s  %s' % ('round', 'case', 'clean',
                                   ' '.join('%-10s' % l for l, _, _ in LAWS)))
    for rnd, name, base_bad, res in rows:
        marks = ['%10d' % r for r in res]
        print('%-30s %-16s %6d  %s' % (rnd, name, base_bad, ' '.join(marks)))
    tot = [sum(r[3][k] for r in rows) for k in range(len(LAWS))]
    exact = [sum(1 for r in rows if r[3][k] == 0) for k in range(len(LAWS))]
    print('\ntotal wrong words per law:')
    for (label, _, _), t, e in zip(LAWS, tot, exact):
        print('  %-11s words=%5d  exact cases=%d/%d' % (label, t, e, len(rows)))


main()
