"""framediff board-vs-model divergence: does it start at a frame boundary?

For every failing block, dump the per-frame state the model tracks (changed
pixel count, scene-change decision, bg_valid/fast-adapt entering the frame)
next to how many of that frame's 16 words the board got wrong, and score the
two state-level explanations:

  seed(f)  -- the board entered frame f with bg_valid=0 (masks all zero in
              DIFF/MOTION, output = cur in BG)
  fa(f)    -- the board entered frame f with the fast-adapt flag set
              (reference updated to cur while real diffs still leave)

If a case's board words equal the model's words under one of those two
one-frame state injections, the divergence is a state-decode bug, not a
per-pixel arithmetic bug.
"""
import json, struct, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import eth_protocol as ep
from fd_diag import load, NP


def trace(words, sel, inject=None):
    """Model pass with an optional per-frame state injection at frame start."""
    mode, thr, alpha, scn, pol = ep.protocol.FD_BUNDLES[sel]
    ref = [[0] * 4 for _ in range(4)]
    bg_valid, fa = 0, 0
    out, frames = [], []
    for f in range(len(words) // NP):
        if inject and f in inject:
            bg_valid, fa = inject[f]
        chg = 0
        rows = []
        for p in range(NP):
            y, x = divmod(p, 4)
            cur = words[f * NP + p] & 0xFF
            r = ref[y][x]
            sd = cur - r
            ad = abs(sd)
            al = 0 if fa else alpha
            step = sd >> al
            nbg = (r + step) & 0xFF
            new_ref = cur if (not bg_valid or mode == 0) else nbg
            ad_e = ad if bg_valid else 0
            moved = 1 if ad_e > thr else 0
            outpix = new_ref if mode == 1 else (0xFF if moved else 0)
            ref[y][x] = new_ref
            chg += moved
            eot = (p == NP - 1)
            scn_hit = eot and bg_valid and ((chg << 7) > 16 * scn)
            rows.append((cur, r, ad, outpix, moved, bg_valid, fa))
            sof, eol = (1 if p == 0 else 0), (1 if x == 3 else 0)
            out.append((outpix & 0xFF) | (sof << 8) | (eol << 9)
                       | ((1 if scn_hit else 0) << 11))
            if eot:
                if scn_hit:
                    bg_valid, fa = pol, pol
                else:
                    bg_valid, fa = 1, 0
        frames.append(dict(f=f, chg=chg, scn=scn, last_hit=scn_hit,
                           enter_bg=rows[0][5], enter_fa=rows[0][6]))
    return out, frames, rows


def main():
    rd = sys.argv[1] if len(sys.argv) > 1 else str(
        HERE / 'evidence/board_v4_framediff_20261003/round_01')
    cases = load(rd)
    print('%-16s %4s %5s  %s' % ('case', 'cfg', 'wrong',
                                 'per-frame: chg/hit/enter-bg/enter-fa/wrong'
                                 '  [seed-fit, fa-fit]'))
    scored = []
    for c in cases:
        want, frames, _ = trace(c['inw'], c['cfg'])
        bad = [i for i in range(len(want)) if c['board'][i] != want[i]]
        if not bad:
            continue
        mode = ep.protocol.FD_BUNDLES[c['cfg']][0]
        per = []
        for fr in frames:
            w = sum(1 for i in bad if i // NP == fr['f'])
            per.append('%d:chg%d%s bg%d fa%d bad%d'
                       % (fr['f'], fr['chg'], 'HIT' if fr['last_hit'] else '-',
                          fr['enter_bg'], fr['enter_fa'], w))
        # state-injection scores: try every start frame
        fits = []
        for f0 in range(1, len(c['inw']) // NP):
            for tag, inj in (('seed', {f0: (0, 0)}), ('fa', {f0: (1, 1)}),
                             ('seed+fa', {f0: (0, 1)})):
                cand, _, _ = trace(c['inw'], c['cfg'], inj)
                same = sum(1 for i in range(len(want)) if cand[i] == c['board'][i])
                if same == len(want):
                    fits.append('%s@%d EXACT' % (tag, f0))
                elif same > len(want) - len(bad):
                    fits.append('%s@%d +%d' % (tag, f0, same - (len(want) - len(bad))))
        print('%-16s cfg%-2d %4d  %s   | %s' % (c['name'], c['cfg'], len(bad),
                                                '  '.join(per),
                                                ', '.join(fits) or 'no state fit'))
        scored.append((c['name'], len(bad), fits))
    print("\nmode legend: 0 DIFF 1 BG 2 MOTION; bg/fa are the model's state at "
          'each frame start')


if __name__ == '__main__':
    main()
