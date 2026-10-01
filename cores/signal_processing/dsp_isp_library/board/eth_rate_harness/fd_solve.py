"""Invert framediff BG-mode board words for the reference value the silicon used.

out = ref + ((cur-ref) >> alpha) is monotone in ref, so a board word pins ref
to a small candidate set.  Classify each candidate against the model's own
references: the correct one, a neighbour raster position, the same pixel one
frame earlier, or the value the pixel itself carries (a bypassed RAM read).
"""
import sys, json
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
from fd_diag import load, NP

def ref_candidates(cur, out, alpha):
    return [r for r in range(256) if ((r + ((cur - r) >> alpha)) & 0xFF) == out]

def main():
    rd = sys.argv[1] if len(sys.argv) > 1 else str(
        HERE / 'evidence/board_v4_framediff_20261003/round_01')
    cases = load(rd)
    tally = {}
    for c in cases:
        mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[c['cfg']]
        if mode != 1:
            continue
        want = ep.model_oracle(c['cfg'], c['inw'], 7)
        bad = [i for i in range(len(want)) if c['board'][i] != want[i]]
        if not bad:
            continue
        print('== %s cfg%d alpha%d' % (c['name'], c['cfg'], alpha))
        for i in bad:
            f, p = divmod(i, NP)
            y, x = divmod(p, 4)
            cur = c['inw'][i] & 0xFF
            vb = c['board'][i] & 0xFF
            vm = want[i] & 0xFF
            mref = None
            # model's entering reference for this pixel: recompute quickly
            # by replaying the model state (uses fd_diag.model_trace recs)
            from fd_diag import model_trace
            if not hasattr(main, 'rec'):
                main.rec = {}
            key = (c['name'], c['cfg'])
            if key not in main.rec:
                _o, recs = model_trace(c['inw'], c['cfg'])
                main.rec[key] = recs
            r = main.rec[key][i]
            mref = r['ref']
            cands = ref_candidates(cur, vb, alpha)
            tags = []
            if mref in cands:
                tags.append('REF-OK(shift-wrong)')
            for cc in cands:
                if cc == (c['inw'][i] & 0xFF):
                    tags.append('ref=cur')
            span = '%d..%d' % (min(cands), max(cands)) if cands else 'none'
            # does the board value correspond to alpha=0 or a >=8 shift?
            alt = []
            for a2 in range(0, 10):
                if ((mref + ((cur - mref) >> a2)) & 0xFF) == vb:
                    alt.append('alpha%d' % a2)
            if vb == cur: alt.append('out=cur')
            if vb == mref: alt.append('out=ref')
            print('  i%-3d f%d y%d x%d cur%3d mref%3d mout%3d bout%3d '
                  'cand[%s] alpha-fit=%s' % (i, f, y, x, cur, mref, vm, vb,
                                             span, ','.join(alt) or '-'))
            for t in set(tags) | set(alt) or {'unexplained'}:
                tally[t] = tally.get(t, 0) + 1
    print('\nTALLY', json.dumps(tally, indent=1))

main()
