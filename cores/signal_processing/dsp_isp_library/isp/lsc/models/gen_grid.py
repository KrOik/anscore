"""LSC gain-grid generation / import tool.

Generates per-phase GW x GH gain tables (unsigned Q4.12) for lsc_stream and
emits the packed write-port transaction list used by tests/tb_lsc.sv and by
host download software.

Usage examples:
  python gen_grid.py --width 32 --height 24 --gw 9 --gh 7 \
      --bayer 1 --order 0 --g-center 1.05 --g-edge 2.2 --out demo
      -> demo.gains.mem (one packed write word per line) + demo.params.json
  python gen_grid.py --import mesh.csv --gw 9 --gh 7 --bayer 1 --out demo
      CSV columns: phase,row,col,gain   (float gain, or raw Q4.12 with --raw)

The packed word layout is {err[27],phase[26:25],row[24:21],col[20:16],
data[15:0]}; the trig/scheduling field used in simulation is prepended by the
test driver, not by this tool.
"""
import argparse
import csv
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from model import Config, UNITY, GW_MAX, GH_MAX, kexp  # noqa: E402

QMAX = (1 << 16) - 1


def quantize_gain(g):
    """Float gain -> unsigned Q4.12 word, clamped to [0, 0xffff]."""
    return max(0, min(QMAX, int(round(g * UNITY))))


def radial_gain(u, v, phase, g_center=1.05, g_edge=2.2, phase_tilt=None):
    """Classic vignette mesh: quadratic falloff compensation.

    u,v are node coordinates normalized to [0,1] over the grid. Corners get
    the largest gain. phase_tilt gives a small per-channel scale so Bayer
    phases carry distinct tables.
    """
    if phase_tilt is None:
        phase_tilt = (1.0, 1.0, 1.0, 1.0)
    r2 = ((u - 0.5) ** 2 + (v - 0.5) ** 2) / 0.5   # 0 center -> 1 corner
    return (g_center + (g_edge - g_center) * min(r2, 4.0)) * phase_tilt[phase]


def make_table(cfg, gfun):
    """gfun(u_norm, v_norm, phase) -> float gain. Returns [4][gh][gw] ints."""
    tab = []
    for p in range(4):
        rows = []
        for j in range(cfg.gh):
            v = j / (cfg.gh - 1)
            rows.append([quantize_gain(gfun(i / (cfg.gw - 1), v, p))
                         for i in range(cfg.gw)])
        tab.append(rows)
    return tab


def flat_table(cfg, g=1.0):
    return make_table(cfg, lambda u, v, p: g)


def pack_entry(phase, row, col, data):
    return ((phase & 3) << 25) | ((row & 0xf) << 21) | ((col & 0x1f) << 16) \
        | (data & 0xffff)


def table_entries(cfg, tab, phases=None):
    """Packed write-port words for the given (or all used) phases."""
    if phases is None:
        phases = range(4) if cfg.bayer else (0,)
    out = []
    for p in phases:
        for j in range(cfg.gh):
            for i in range(cfg.gw):
                out.append(pack_entry(p, j, i, tab[p][j][i]))
    return out


def import_csv(path, cfg):
    """CSV columns phase,row,col,gain. Missing nodes default to unity."""
    tab = [[[UNITY for _ in range(cfg.gw)] for _ in range(cfg.gh)]
           for _ in range(4)]
    with open(path, newline='') as f:
        for row in csv.reader(f):
            if not row or row[0].strip().startswith('#'):
                continue
            p, j, i, g = int(row[0]), int(row[1]), int(row[2]), float(row[3])
            if not (0 <= p < 4 and 0 <= j < cfg.gh and 0 <= i < cfg.gw):
                raise ValueError(f'node out of range: {row}')
            tab[p][j][i] = quantize_gain(g)
    return tab


def import_memh(path, cfg):
    """Raw Q4.12 words, linear order phase-major: p*gh*gw + j*gw + i."""
    words = [int(t, 16) for t in Path(path).read_text().split()]
    need = 4 * cfg.gh * cfg.gw
    if len(words) != need:
        raise ValueError(f'memh has {len(words)} words, need {need}')
    tab = []
    for p in range(4):
        rows = []
        for j in range(cfg.gh):
            rows.append([words[(p * cfg.gh + j) * cfg.gw + i]
                         for i in range(cfg.gw)])
        tab.append(rows)
    return tab


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--width', type=int, required=True)
    ap.add_argument('--height', type=int, required=True)
    ap.add_argument('--gw', type=int, required=True)
    ap.add_argument('--gh', type=int, required=True)
    ap.add_argument('--kx', type=int, default=None,
                    help='node spacing exponent; default = minimal covering')
    ap.add_argument('--ky', type=int, default=None)
    ap.add_argument('--bayer', type=int, default=0)
    ap.add_argument('--order', type=int, default=0)
    ap.add_argument('--bits', type=int, default=8)
    ap.add_argument('--gmax', type=lambda s: int(s, 0), default=0xffff)
    ap.add_argument('--g-center', type=float, default=1.05)
    ap.add_argument('--g-edge', type=float, default=2.2)
    ap.add_argument('--phase-tilt', type=str, default='1.0,1.0,1.0,1.0')
    ap.add_argument('--import', dest='import_csv', default=None)
    ap.add_argument('--import-memh', dest='import_memh', default=None)
    ap.add_argument('--out', required=True, help='output file prefix')
    a = ap.parse_args()
    kx = a.kx if a.kx is not None else kexp(
        (a.width + 1) >> 1 if a.bayer else a.width, a.gw)
    ky = a.ky if a.ky is not None else kexp(
        (a.height + 1) >> 1 if a.bayer else a.height, a.gh)
    cfg = Config(width=a.width, height=a.height, gw=a.gw, gh=a.gh,
                 kx=kx, ky=ky, bayer=a.bayer, order=a.order,
                 gmax=a.gmax, bits=a.bits)
    if a.import_csv:
        tab = import_csv(a.import_csv, cfg)
    elif a.import_memh:
        tab = import_memh(a.import_memh, cfg)
    else:
        tilt = tuple(float(t) for t in a.phase_tilt.split(','))
        tab = make_table(cfg, lambda u, v, p: radial_gain(
            u, v, p, a.g_center, a.g_edge, tilt))
    prefix = Path(a.out)
    entries = table_entries(cfg, tab)
    prefix.with_suffix('.gains.mem').write_text(
        ''.join(f'{e:07x}\n' for e in entries))
    params = dict(width=a.width, height=a.height, gw=a.gw, gh=a.gh,
                  kx=kx, ky=ky, bayer=a.bayer, order=a.order,
                  gmax=a.gmax, bits=a.bits, entries=len(entries))
    prefix.with_suffix('.params.json').write_text(json.dumps(params, indent=2))
    print(json.dumps(params))


if __name__ == '__main__':
    main()
