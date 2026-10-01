"""Census: which core's own state arrays landed in a Gowin 18 Kb BSRAM, and how
that image performed on silicon.

Why this question: the shipped Gowin simulation deck has DPX9B/SDPX9B/DPB/SP as
EMPTY BLACK BOXES (the same defect already established for MULT18X18), so any
memory the synthesiser puts in a BSRAM is invisible to every simulation in the
flow -- RTL sim, the harness ETH SIM, and a netlist differential alike.  A core
whose state lives in a BSRAM is therefore only ever checked by hardware.  The
build gate made this worse: it counted BSRAMs with `k.startswith('BSRAM')`, a
cell name yosys never emits, so every build_summary.json said bsram=0.

  python bsram_census.py            # table, newest image per board round

The table joins each board round's verdict (verified/planned, clock) to the exact
image it ran (verdict.json's 'build' path, confirmed by bitstream sha256) and to
the BSRAM/LUT-RAM primitives that image inferred, separated into the ones the
DUT core owns and the ones the Ethernet harness owns.  The harness-owned blocks
are a control: every core, including the ones that pass 20/20, moves its payload
through the same BSRAM-backed input/output stores.
"""
import collections, hashlib, json, re, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
EV = HERE / 'evidence'
BRAM = ('DPX9B', 'DPB', 'SDPX9B', 'SDPB', 'SPX9', 'SP')
DRAM = re.compile(r'^(RAM(16|[DS])|RAMW)')
CORE_MARK = re.compile(r'\.core\.|g_[a-z0-9_]+\.core')


def owner(name):
    return 'core' if CORE_MARK.search(name) else 'harness'


def cells_of(image_dir):
    net = json.loads((image_dir / 'top.json').read_text())
    top = net['modules']['eth_rate_harness']
    out = collections.defaultdict(int)
    for cname, c in top['cells'].items():
        if c['type'] in BRAM:
            out[('bsram', owner(cname))] += 1
            out[('bsram_name', cname)] += 1
        elif DRAM.match(c['type']):
            out[('dram', owner(cname))] += 1
    return out


def main():
    rows = []
    for rd in sorted(EV.glob('board_*')):
        v = rd / 'verdict.json'
        if not v.exists():
            continue
        try:
            meta = json.loads(v.read_text(encoding='utf-8'))
        except Exception:
            continue
        core = meta.get('core_name') or meta.get('build', '')
        build = Path(meta.get('build') or '')
        if not (build / 'top.json').exists():
            build = None
        rounds = sorted(rd.glob('round_*/verdict.json'))
        rep = None
        for r in rounds:
            try:
                d = json.loads(r.read_text(encoding='utf-8'))
            except Exception:
                continue
            s = d.get('summary') or {}
            rep = dict(status=d.get('status'), ok=s.get('verified'),
                       planned=s.get('planned'), clock=d.get('clock_mhz'),
                       name=r.parent.name)
        # Which image actually ran: the round records the bitstream sha256, so
        # find the build directory that produced it rather than trusting a path
        # that may have been re-pointed at a later rebuild.
        sha = meta.get('sha256')
        img = None
        if sha:
            for cand in EV.glob('*/eth.fs'):
                if hashlib.sha256(cand.read_bytes()).hexdigest() == sha:
                    img = cand.parent
                    break
        if img is None and build is not None:
            img = build
        n_core = n_harn = n_dram = None
        names = []
        if img is not None:
            c = cells_of(img)
            n_core = c[('bsram', 'core')]
            n_harn = c[('bsram', 'harness')]
            n_dram = c[('dram', 'core')] + c[('dram', 'harness')]
            names = sorted(k[1] for k, x in c.items() if k[0] == 'bsram_name')
        rows.append(dict(round=rd.name, core=core, status=(rep or {}).get('status'),
                         ok=(rep or {}).get('ok'), planned=(rep or {}).get('planned'),
                         clock=(rep or {}).get('clock'),
                         image=(img.name if img else None), core_bram=n_core,
                         harness_bram=n_harn, lutram=n_dram, names=names))
    hdr = ('%-34s %-10s %-6s %-7s %-8s %-6s %-6s %-6s %s'
           % ('board round', 'core', 'stat', 'ok/plan', 'MHz', 'BSRAM', 'harnBS',
              'LUTR', 'core-owned BSRAM instances'))
    print(hdr)
    print('-' * len(hdr))
    for r in rows:
        if r['ok'] is None:
            continue
        print('%-34s %-10s %-6s %-7s %-8s %-6s %-6s %-6s %s'
              % (r['round'][:34], r['core'], r['status'],
                 '%s/%s' % (r['ok'], r['planned']), r['clock'],
                 r['core_bram'], r['harness_bram'], r['lutram'],
                 ' '.join(n for n in r['names'] if '.core.' in n)[:70]))
    print()
    print('core-owned BSRAM count vs board pass rate is the correlation of '
          'interest: a core whose state array the tool moved into an '
          'unmodellable 18 Kb block is the one part of an image no simulation '
          'in this flow can see.')


if __name__ == '__main__':
    main()
