"""Deal catalog cores into board groups, keeping every proven group frozen.

tools/group_order.json is a list of lists: each list is one explicit group and
is frozen exactly as placed. This script reads the newest measured per-core size
from the isolated-synthesis evidence and packs the cores the file does not name
into the spare groups so no group exceeds the LUT/DSP/BRAM budget.

Dry run by default; --write is the only mode that touches group_order.json, and
it refuses unless every new core has been synthesized in isolation and the
predicted layout is inside budget. Family authors must never run this.
"""
import argparse
import json

from catalog import CORES
from groups import MAX_UNITS, ROOT, group_sizes
from build import LUT_BUDGET, DSP_BUDGET, BRAM_BUDGET

ORDER = ROOT / 'tools' / 'group_order.json'
# Packing target is deliberately below the acceptance budget: the per-core
# numbers come from isolated synthesis, and a group also carries the board
# harness and its vector ROM, and nextpnr needs routing headroom to close 50
# MHz at all. Round 1 measured 3.8k-7.1k LUT per group against 18000, so these
# targets are generous for well-behaved cores and still reject a group of eight
# four-multiplier cores (8x4=32 > 28) that would sit exactly on the hard limit.
SAFE = dict(lut=int(0.83 * LUT_BUDGET), dsp=28, bram=40)


def frozen_rows():
    raw = json.loads(ORDER.read_text(encoding='utf-8'))
    if not all(isinstance(row, list) for row in raw):
        raise SystemExit('group_order.json must be a list of explicit groups '
                         '(lists of core names) before dealing')
    return raw


def measured():
    """Newest isolated-synthesis metrics per core name across all build evidence."""
    best = {}
    for summary in sorted((ROOT / 'evidence').glob('build_*/summary.json')):
        try:
            data = json.loads(summary.read_text(encoding='utf-8'))
        except (ValueError, OSError):
            continue
        for row in data.get('isolated', []):
            best[row['name']] = (data['timestamp'], row['lut_class'], row['dsp_class'],
                                 row['bram_blocks'], summary.parent.name)
    return best


def pack(items, sizes, family):
    """Largest-processing-time-first into the emptiest feasible group.

    Spreading families across groups is a tie-break: one group holding eight
    cores of one family hides a family-level pathology inside one bitstream and
    makes an outlier group impossible to attribute.
    """
    groups = [[] for _ in sizes]
    load = [dict(lut=0, dsp=0, bram=0) for _ in sizes]
    for name, lut, dsp, bram in sorted(items, key=lambda i: (-i[1], i[0])):
        options = []
        for index, members in enumerate(groups):
            if len(members) == sizes[index]:
                continue
            if (load[index]['lut'] + lut > SAFE['lut']
                    or load[index]['dsp'] + dsp > SAFE['dsp']
                    or load[index]['bram'] + bram > SAFE['bram']):
                continue
            same = sum(1 for other in members if family[other[0]] == family[name])
            options.append((load[index]['lut'], same, index))
        if not options:
            raise SystemExit(f'{name}: no group can take lut={lut} dsp={dsp} '
                             f'bram={bram} within the packing target '
                             f'{SAFE}; it needs a smaller core or more groups')
        index = min(options)[2]
        groups[index].append((name, lut, dsp, bram))
        load[index]['lut'] += lut
        load[index]['dsp'] += dsp
        load[index]['bram'] += bram
    return groups, load


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--write', action='store_true', help='update group_order.json')
    args = ap.parse_args()
    rows = frozen_rows()
    placed = {name for row in rows for name in row}
    family = {entry['name']: entry['family'] for entry in CORES}
    pending = [entry['name'] for entry in CORES if entry['name'] not in placed]
    metrics = measured()
    unmeasured = [name for name in pending if name not in metrics]
    print(f'frozen: {len(rows)} groups holding {len(placed)} cores; '
          f'{len(pending)} cores await a deal; '
          f'{len(pending) - len(unmeasured)} of them measured')
    for name in unmeasured:
        print(f'  no isolated synthesis yet: {name}')
    if not pending:
        print('nothing to deal')
        return 0
    if unmeasured:
        raise SystemExit('refusing to deal: every pending core needs a measured size')
    total = len(pending)
    items = [(name, metrics[name][1], metrics[name][2], metrics[name][3])
             for name in pending]
    # Start from the fewest groups that can physically hold the cores (8 units
    # each) and add groups until the measured LUT/DSP/BRAM loads fit the packing
    # target. Round 2 has several hand-instantiating multiplier families, so
    # group DSP is the limit that binds first, not unit count.
    first = -(-total // MAX_UNITS)
    packed = load = None
    for count in range(first, total + 1):
        try:
            packed, load = pack(items, group_sizes(total, count), family)
        except SystemExit as exc:
            print(f'{count} groups of {total // count}: {exc}')
            continue
        if count > first:
            print(f'needed {count} groups, not {first}: the packing target binds')
        break
    if packed is None:
        raise SystemExit(f'{total} cores cannot be dealt at all')
    layout = list(rows)
    for index, members in enumerate(packed):
        group = len(rows) + index
        layout.append([name for name, _, _, _ in members])
        print(f'GROUP {group}: units={len(members)} lut={load[index]["lut"]} '
              f'dsp={load[index]["dsp"]} bram={load[index]["bram"]} '
              f'families={sorted({family[name] for name, _, _, _ in members})}')
    worst_lut = max(row['lut'] for row in load)
    worst_dsp = max(row['dsp'] for row in load)
    worst_bram = max(row['bram'] for row in load)
    print(f'predicted worst: {worst_lut}/{LUT_BUDGET} LUT, {worst_dsp}/{DSP_BUDGET} DSP, '
          f'{worst_bram}/{BRAM_BUDGET} BRAM over {len(layout)} groups and '
          f'{sum(len(row) for row in layout)} cores')
    if not args.write:
        print('dry run; nothing written')
        return 0
    ORDER.write_text(json.dumps(layout, indent=1) + '\n', encoding='utf-8')
    print('wrote tools/group_order.json')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
