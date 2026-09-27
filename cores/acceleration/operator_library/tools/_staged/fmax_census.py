"""Read-only Fmax census for every dealt group.

build.py aborts a shard at the first group that misses the 50 MHz gate, so the
release has no timing data for the groups that sat behind a failure. This walks
every group, runs the same yosys/nextpnr commands build.py uses, and records the
frequency plus which unit owns the critical path. It writes only into its own
evidence directory and never raises: the point is the complete table.
"""
import argparse
import concurrent.futures as cf
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import build
from groups import plan

ROOT = Path(build.__file__).resolve().parent.parent


def critical_unit(text):
    """Unit instance ('u5') that owns the worst path, from nextpnr's report."""
    blocks = re.findall(r'Critical path report.*?(?=\nInfo: (?:Slack|Max|Device)|\Z)',
                        text, re.S)
    tally = {}
    for block in blocks:
        names = re.findall(r'g\d+\.st\.(u\d+)\.', block)
        for name in names:
            tally[name] = tally.get(name, 0) + 1
    if not tally:
        return None
    return max(tally, key=lambda k: (tally[k], k))


def path_split(text):
    """The worst reported path's (logic, routing) split, not the last line."""
    pairs = [(float(a), float(b)) for a, b in re.findall(
        r'Info:\s+([\d.]+) ns logic,\s+([\d.]+) ns routing', text)]
    if not pairs:
        return None, None
    return max(pairs, key=lambda p: p[0] + p[1])


def one(group, out):
    row = {'group': group, 'route': 'NOT_RUN'}
    try:
        planned = next(r for r in plan() if r['group'] == group)
        row['units'] = planned['units']
        row['cores'] = planned['names']
        sources = [f'rtl/acc_{name}.v' for name in planned['names']]
        sources += [f'board/acc_board_group_{g}.v' for g in
                    sorted(r['group'] for r in plan())]
        sources += ['board/acc_top.v', 'board/acc_uart_tx.v']
        netlist = out / f'group_{group}.json'
        script = out / f'group_{group}.ys'
        script.write_text(
            f'read_verilog -lib {build.GOWIN_CELLS.as_posix()}\n'
            'read_verilog ' + ' '.join(sources) + '\n'
            f'chparam -set GROUP {group} acc_top\n'
            f'synth_gowin -family gw5a -noalu -top acc_top '
            f'-json {netlist.as_posix()}\nstat\n', encoding='utf-8')
        build.command(['yosys', '-s', script], out / f'group_{group}_yosys.log',
                      timeout=3600)
        row.update(build.metrics(netlist, 'acc_top'))
        row.pop('cells', None)
        routed = out / f'group_{group}_pnr.json'
        log = out / f'group_{group}_nextpnr.log'
        try:
            build.command(['nextpnr-himbaechel', '--json', netlist, '--write', routed,
                           '--device', 'GW5A-LV25MG121NES', '--vopt', 'family=GW5A-25A',
                           '--vopt', 'cst=board/tang25k.cst', '--vopt', 'sspi_as_gpio',
                           '--freq', str(build.TARGET_MHZ)], log, timeout=2400)
        finally:
            # nextpnr writes the full report before exiting nonzero on a timing
            # failure, so attribution has to survive the failure path; without
            # this a failing group reported no frequency and no critical unit.
            if log.is_file():
                text = log.read_text(encoding='utf-8', errors='replace')
                row['max_frequency_mhz'] = build.max_frequency(text)
                row['logic_ns'], row['routing_ns'] = path_split(text)
                row['critical_unit'] = critical_unit(text)
        row['route'] = ('PASS' if row['max_frequency_mhz']
                        and row['max_frequency_mhz'] >= build.TARGET_MHZ
                        else 'FAIL')
    except Exception as exc:                                  # census never dies
        row['error'] = f'{type(exc).__name__}: {exc}'[:300]
    return row


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--groups', default='')
    ap.add_argument('--workers', type=int, default=3)
    ap.add_argument('--stamp', default=datetime.now(timezone.utc).strftime(
        '%Y%m%dT%H%M%SZ'))
    args = ap.parse_args()
    out = ROOT / 'evidence' / f'fmax_census_{args.stamp}'
    out.mkdir(parents=True, exist_ok=True)
    groups = ([int(v) for v in args.groups.split(',') if v != '']
              or sorted(r['group'] for r in plan()))
    done = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        for row in pool.map(lambda g: one(g, out), groups):
            done.append(row)
            print(f"CENSUS g{row['group']} units={row.get('units')} "
                  f"lut={row.get('lut_class')} route={row.get('route')} "
                  f"fmax={row.get('max_frequency_mhz')} "
                  f"logic={row.get('logic_ns')} rout={row.get('routing_ns')} "
                  f"crit={row.get('critical_unit')} {row.get('error', '')}",
                  flush=True)
    done.sort(key=lambda r: r['group'])
    (out / 'census.json').write_text(json.dumps(done, indent=2) + '\n',
                                     encoding='utf-8')
    bad = [r['group'] for r in done if r.get('route') != 'PASS']
    print(f'CENSUS DONE groups={len(done)} below_gate={bad}', flush=True)


if __name__ == '__main__':
    main()
