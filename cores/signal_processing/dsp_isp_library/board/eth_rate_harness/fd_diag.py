"""Structural analysis of framediff board-vs-model word mismatches.

Rebuilds the per-pixel arithmetic the RTL performs (cur, ref, |diff|, step)
for every block in an archived board round, then asks what single change of
input would turn the model word into the board word: a stale/shifted
reference, a wrong shift amount, a marker bit, or a borderline compare.
"""
import json, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep

FD_W = FD_H = 4
NP = FD_W * FD_H


def model_trace(words, sel):
    """Per-pixel records plus the emitted word, using the RTL equations."""
    mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[sel]
    ref = [[0] * FD_W for _ in range(FD_H)]
    bg_valid = 0
    fa = 0
    out, recs = [], []
    for f in range(len(words) // NP):
        chg = 0
        for p in range(NP):
            y, x = divmod(p, FD_W)
            cur = words[f * NP + p] & 0xFF
            r = ref[y][x]
            sd = cur - r
            ad = abs(sd)
            al = 0 if fa else alpha
            step = sd >> al                    # arithmetic, floor
            nbg = (r + step) & 0xFF
            new_ref = cur if (not bg_valid or mode == 0) else nbg
            ad_e = ad if bg_valid else 0
            moved = 1 if ad_e > thr else 0
            outpix = new_ref if mode == 1 else (0xFF if moved else 0)
            ref[y][x] = new_ref
            chg += moved
            eot = (p == NP - 1)
            scn_hit = eot and bg_valid and ((chg << 7) > NP * scn)
            recs.append(dict(f=f, y=y, x=x, p=p, cur=cur, ref=r, ad=ad,
                             thr=thr, alpha=al, step=step, nbg=nbg,
                             new_ref=new_ref, mode=mode, bg_valid=bg_valid,
                             fa=fa, moved=moved, out=outpix, eot=eot,
                             scn=scn_hit))
            sof = 1 if p == 0 else 0
            eol = 1 if x == FD_W - 1 else 0
            scnb = 1 if (scn_hit) else 0
            out.append((outpix & 0xFF) | (sof << 8) | (eol << 9) | (scnb << 11))
            if eot:
                if scn_hit:
                    bg_valid = pol
                    fa = pol
                else:
                    bg_valid = 1
                    fa = 0
    return out, recs


def load(round_dir):
    rd = Path(round_dir)
    verdict = json.loads((rd / 'verdict.json').read_text(encoding='utf-8'))
    cases = []
    for c in verdict['cases']:
        req = rd / 'frames' / ('%s_req.bin' % c['name'])
        resp = rd / 'frames' / ('%s_resp.bin' % c['name'])
        if not (req.exists() and resp.exists()):
            continue
        payload = req.read_bytes()
        tag, cfg, n, stall, out_exp, rsvd = struct.unpack(
            ep.HDR, payload[4:16])
        inw = list(struct.unpack('<%dI' % n, payload[16:16 + 4 * n]))
        board = list(struct.unpack('<%dI' % min(out_exp, ep.MAX_RESULT_WORDS),
                                 resp.read_bytes()[20:20 + 4 * min(out_exp, ep.MAX_RESULT_WORDS)]))
        cases.append(dict(name=c['name'], cfg=cfg, inw=inw, board=board,
                          stall=stall, rsvd=rsvd))
    return cases


def main():
    rd = sys.argv[1] if len(sys.argv) > 1 else str(
        HERE / 'evidence/board_v4_framediff_20261003/round_01')
    cases = load(rd)
    tot = dict(cases=0, wrong=0, mark=0, value=0)
    per_xy, per_f, dist = {}, {}, []
    for c in cases:
        want, recs = model_trace(c['inw'], c['cfg'])
        if [w & 0xFFFF for w in want] != [w & 0xFFFF for w in c['board']][:len(want)]:
            pass
        bad = [i for i in range(len(want))
               if (c['board'][i] if i < len(c['board']) else None) != want[i]]
        if not bad:
            continue
        tot['cases'] += 1
        mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[c['cfg']]
        print('%-16s cfg%-2d mode%d thr%-3d al%d scn%d pol%d  %d/%d wrong'
              % (c['name'], c['cfg'], mode, thr, alpha, scn, pol,
                 len(bad), len(want)))
        for i in bad:
            b, m = c['board'][i], want[i]
            r = recs[i]
            mk_b, mk_m = b >> 8, m >> 8
            vb, vm = b & 0xFF, m & 0xFF
            tot['wrong'] += 1
            if mk_b != mk_m:
                tot['mark'] += 1
            if vb != vm:
                tot['value'] += 1
            per_xy[(r['f'], r['y'], r['x'])] = per_xy.get((r['f'], r['y'], r['x']), 0) + 1
            per_f[r['f']] = per_f.get(r['f'], 0) + 1
            # candidate explanations
            cand = []
            if vb == vm:
                cand.append('markers-only')
            if mode in (0, 2):
                if vb == 0xFF and vm == 0:
                    cand.append('extra-move(ad>%d?)' % thr)
                if vb == 0 and vm == 0xFF:
                    cand.append('lost-move')
            else:
                if vb == r['cur']:
                    cand.append('out=cur(alpha0)')
                if vb == r['ref']:
                    cand.append('out=ref(step0)')
                if vb == ((r['ref'] + (r['cur'] - r['ref']) // 1) & 0xFF):
                    cand.append('out=cur')
            dist.append((c['name'], i, r['f'], r['y'], r['x'], r['cur'],
                         r['ref'], r['ad'], r['thr'], vb, vm, ','.join(cand)))
    print('\nTOTAL', tot)
    print('\nwrong by frame:', dict(sorted(per_f.items())))
    print('wrong by (frame,y,x) count>1:',
          {k: v for k, v in sorted(per_xy.items()) if v > 1})
    print('\n%-16s %3s %2s %2s %2s %4s %4s %4s %3s %4s %4s %s'
          % ('case', 'i', 'f', 'y', 'x', 'cur', 'ref', 'ad', 'thr', 'brd',
             'mod', 'explanation'))
    for d in dist[:120]:
        print('%-16s %3d %2d %2d %2d %4d %4d %4d %3d %4d %4d %s' % d)
    if len(dist) > 120:
        print('... %d more' % (len(dist) - 120))
    (HERE / 'framediff_diag.json').write_text(json.dumps(dist, indent=1))


if __name__ == '__main__':
    main()
