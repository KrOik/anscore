"""Resource-gated GW5A builds for accelerator groups.

Budget reflects the GW5A-25 die (23040 LUT4, 56 BSRAM, 56 MULT12X12) with
deliberate headroom: 18000 LUT-class, 32 DSP-class, 48 BSRAM per group of at
most 8 cores. Synthesis and place-and-route must both pass; the route report
must show at least the physical clock rate.
"""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from catalog import CORES
from groups import plan
from verify import ROOT, REPO, environment, source_hashes

SUITE = REPO/'tools/oss-cad-suite/oss-cad-suite'
# Hard-IP prototypes (MULT12X12 and friends) are declared here; without this the
# hand-instantiated cells are unknown modules and yosys silently drops them.
GOWIN_CELLS = SUITE/'share/yosys/gowin/cells_xtra_gw5a.v'
LUT_BUDGET, DSP_BUDGET, BRAM_BUDGET = 18000, 32, 48
TARGET_MHZ = 50


def command(argv, log, timeout=7200):
    program = str(argv[0])
    candidate = SUITE/'bin'/(program+'.exe')
    if candidate.is_file():
        argv = [str(candidate), *argv[1:]]
    log.parent.mkdir(parents=True, exist_ok=True)
    with log.open('wb') as stream:
        proc = subprocess.run([str(v) for v in argv], cwd=ROOT, env=environment(),
                              stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    if proc.returncode:
        raise RuntimeError(f'{program} exit={proc.returncode}; see {log}')


def metrics(netlist, top):
    data = json.loads(netlist.read_text(encoding='utf-8'))
    counts = Counter(cell['type'] for cell in data['modules'][top]['cells'].values())
    lut = sum(n for t, n in counts.items() if re.fullmatch(r'LUT[1-9]|ALU', t))
    dsp = sum(n for t, n in counts.items() if re.search(r'MULT|PADD|ALU54|MULTALU|MULTADD', t))
    bram = sum(n for t, n in counts.items() if re.fullmatch(r'(?:SP|SDP|DP|ROM)(?:X9)?B?', t))
    ff = sum(n for t, n in counts.items() if t.startswith('DFF'))
    return dict(lut_class=lut, dsp_class=dsp, bram_blocks=bram, ff_class=ff,
                cells=dict(sorted(counts.items())),
                under_budget=(lut <= LUT_BUDGET and dsp <= DSP_BUDGET and bram <= BRAM_BUDGET))


def max_frequency(log_text):
    best = None
    for line in log_text.splitlines():
        found = re.search(r'Max frequency for clock[^\d]*([\d.]+) MHz', line)
        if found:
            best = float(found.group(1)) if best is None else min(best, float(found.group(1)))
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--groups', help='comma list, default every group')
    ap.add_argument('--isolated', action='store_true')
    ap.add_argument('--isolated-core')
    ap.add_argument('--family', help='restrict --isolated to one family (parallel bring-up)')
    ap.add_argument('--synth-only', action='store_true')
    ap.add_argument('--no-groups', action='store_true',
                    help='isolated core builds only, for family bring-up')
    ap.add_argument('--stamp', help='evidence directory suffix; give parallel shards '
                    'distinct names, because two builds started in the same second '
                    'would otherwise collide on evidence/build_<stamp> and one dies')
    args = ap.parse_args()
    all_groups = [row['group'] for row in plan()]
    groups = all_groups if not args.groups else [int(v) for v in args.groups.split(',')]
    if any(g not in all_groups for g in groups):
        ap.error(f'groups must be within {all_groups}')
    if args.no_groups:
        groups = []
    by_name = {entry['name']: entry for entry in CORES}
    stamp = args.stamp or datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = ROOT/'evidence'/('build_'+stamp)
    out.mkdir(parents=True, exist_ok=False)
    summary = dict(timestamp=datetime.now(timezone.utc).isoformat(),
                   device='GW5A-LV25MG121NES', family='GW5A-25A',
                   synthesis='synth_gowin -family gw5a -noalu',
                   physical_clock_mhz=50, enabled_beat_mhz=3.125,
                   timing_target_mhz=TARGET_MHZ,
                   budget=dict(lut_class=LUT_BUDGET, dsp_class=DSP_BUDGET,
                               bram_blocks=BRAM_BUDGET),
                   groups=[], isolated=[], sources=source_hashes())

    def checkpoint():
        (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf-8')

    if args.isolated or args.isolated_core:
        selected = [e for e in CORES
                    if (not args.isolated_core or e['name'] == args.isolated_core)
                    and (not args.family or e['family'] == args.family)]
        if not selected:
            ap.error('unknown isolated core')
        for entry in selected:
            name = entry['name']
            script, netlist = out/(name+'.ys'), out/(name+'.json')
            script.write_text(f'read_verilog -lib {GOWIN_CELLS.as_posix()}\n'
                              f'read_verilog rtl/acc_{name}.v\n'
                              f'synth_gowin -family gw5a -noalu -top acc_{name} '
                              f'-json {netlist.as_posix()}\nstat\n')
            command(['yosys', '-s', script], out/(name+'.log'))
            row = dict(name=name, **metrics(netlist, 'acc_'+name))
            if not row['under_budget']:
                raise RuntimeError('isolated IP over budget: '+name)
            summary['isolated'].append(row)
            checkpoint()
            print(f'SYNTH {name}: LUT={row["lut_class"]} FF={row["ff_class"]} '
                  f'DSP={row["dsp_class"]} BRAM={row["bram_blocks"]}', flush=True)
    misses = []
    for group in groups:
        row_plan = next(r for r in plan() if r['group'] == group)
        sources = [f'rtl/acc_{name}.v' for name in row_plan['names']]
        sources += [f'board/acc_board_group_{g}.v' for g in all_groups]
        sources += ['board/acc_top.v', 'board/acc_uart_tx.v']
        netlist = out/f'group_{group}.json'
        script = out/f'group_{group}.ys'
        script.write_text(f'read_verilog -lib {GOWIN_CELLS.as_posix()}\n'
                          'read_verilog ' + ' '.join(sources) + '\n'
                          f'chparam -set GROUP {group} acc_top\n'
                          f'synth_gowin -family gw5a -noalu -top acc_top '
                          f'-json {netlist.as_posix()}\nstat\n')
        command(['yosys', '-s', script], out/f'group_{group}_yosys.log')
        row = dict(group=group, units=row_plan['units'], cores=row_plan['names'],
                   synthesis='PASS', route='NOT_RUN', **metrics(netlist, 'acc_top'))
        summary['groups'].append(row)
        checkpoint()
        if not row['under_budget']:
            raise RuntimeError(f'group {group} exceeds budget '
                               f'{LUT_BUDGET} LUT/{DSP_BUDGET} DSP/{BRAM_BUDGET} BRAM')
        print(f'GROUP {group}: LUT={row["lut_class"]} FF={row["ff_class"]} '
              f'DSP={row["dsp_class"]} BRAM={row["bram_blocks"]}', flush=True)
        if args.synth_only:
            continue
        routed = out/f'group_{group}_pnr.json'
        command(['nextpnr-himbaechel', '--json', netlist, '--write', routed,
                 '--device', summary['device'], '--vopt', 'family=GW5A-25A',
                 '--vopt', 'cst=board/tang25k.cst', '--vopt', 'sspi_as_gpio',
                 '--freq', str(TARGET_MHZ)], out/f'group_{group}_nextpnr.log')
        route_text = (out/f'group_{group}_nextpnr.log').read_text(encoding='utf-8', errors='replace')
        freq = max_frequency(route_text)
        row['max_frequency_mhz'] = freq
        row['timing_lines'] = [line for line in route_text.splitlines()
                               if 'Max frequency' in line or 'Device utilisation' in line]
        if freq is None or freq < TARGET_MHZ:
            # Record and carry on: raising here hid every group queued behind the
            # first timing miss, so a shard that died at group 3 never told us
            # that group 5 also failed. A budget breach still fails fast because
            # that is a packing bug, not a per-core one.
            row['route'] = 'FAIL'
            misses.append(group)
            print(f'GROUP {group} ROUTE FAIL fmax={freq} below {TARGET_MHZ} '
                  f'MHz (evidence kept, continuing)', flush=True)
            checkpoint()
            continue
        row['route'] = 'PASS'
        checkpoint()
        fs = out/f'group_{group}.fs'
        command([SUITE/'lib/python3.exe', SUITE/'bin/gowin_pack-script.py',
                 '-d', 'GW5A-25A', '--sspi_as_gpio', '-o', fs, routed], out/f'group_{group}_pack.log')
        row['bitstream'] = fs.relative_to(ROOT).as_posix()
        row['bitstream_sha256'] = hashlib.sha256(fs.read_bytes()).hexdigest()
        row['bitstream_bytes'] = fs.stat().st_size
        checkpoint()
        print(f'PACK group={group} PASS bytes={fs.stat().st_size} fmax={freq}', flush=True)
    if misses:
        raise RuntimeError('groups below the %s MHz gate: %s' % (TARGET_MHZ, misses))
    print(f'Build evidence={out}')


if __name__ == '__main__':
    main()
