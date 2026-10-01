"""For each framediff board word that is wrong, solve the reference value the
silicon must have used (BG mode is invertible in ref) and ask which known
quantity it equals: the model's reference at this or a neighbouring raster
position, the previous frame's reference, the current or previous pixel value,
or the uninitialised zero.  The tally is the evidence for or against an
address law versus a per-pixel arithmetic fault.
"""
import json, sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
from fd_diag import load, NP, model_trace


def implied_refs(cur, out, alpha):
    return {r for r in range(256) if ((r + ((cur - r) >> alpha)) & 0xFF) == out}


def main():
    rounds = [Path(a) for a in sys.argv[1:]] or [
        HERE / 'evidence/board_v4_framediff_20261003/round_01']
    tally = {}
    detail = []
    for rd in rounds:
        for c in load(str(rd)):
            mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[c['cfg']]
            if mode != 1:
                continue
            want, recs = model_trace(c['inw'], c['cfg'])
            for i in range(len(want)):
                if c['board'][i] == want[i]:
                    continue
                r = recs[i]
                f, a = r['f'], i % NP
                cur = c['inw'][i] & 0xFF
                outb = c['board'][i] & 0xFF
                S = implied_refs(cur, outb, alpha)
                # reference values the silicon could legitimately have had
                prev_frame = recs[i - NP]['ref'] if i >= NP else None
                nxt_frame = recs[i + NP]['ref'] if i + NP < len(recs) else None
                cands = {
                    'ref[a]': r['ref'],
                    'ref[a-1]': recs[i - 1]['ref'] if a else None,
                    'ref[a+1]': recs[i + 1]['ref'] if a + 1 < NP and (i + 1) % NP else None,
                    'ref[a]^1': recs[(i & ~NP + ((a ^ 1) if False else (a ^ 1))) + f * NP]['ref'] if False else None,
                    'prev-frame ref[a]': prev_frame,
                    'next-frame ref[a]': nxt_frame,
                    'cur[a-1]': c['inw'][i - 1] & 0xFF if a else None,
                    'cur[a+1]': c['inw'][i + 1] & 0xFF if (i + 1) % NP else None,
                    'cur[a]': cur,
                    'zero': 0,
                    'ff': 255,
                }
                hits = [k for k, v in cands.items() if v is not None and v in S]
                key = ','.join(hits) or ('NO-CANDIDATE(|S|=%d)' % len(S))
                tally[key] = tally.get(key, 0) + 1
                detail.append((rd.parent.name, c['name'], i, f, a, cur,
                               r['ref'], want[i] & 0xFF, outb, key))
    print('BG-mode wrong words: %d' % len(detail))
    for k, v in sorted(tally.items(), key=lambda kv: -kv[1]):
        print('  %5d  %s' % (v, k))
    (HERE / 'fd_ref_rel.json').write_text(json.dumps(detail, indent=1))
    print('\nsample rows (case idx f addr cur ref mout bout relation):')
    for d in detail[:25]:
        print('  %-22s %3d f%d a%-2d cur%3d ref%3d m%3d b%3d  %s'
              % (d[1], d[2], d[3], d[4], d[5], d[6], d[7], d[8], d[9]))


main()
