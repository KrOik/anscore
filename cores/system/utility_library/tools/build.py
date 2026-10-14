"""Resource-gated GW5A builds. Uses immutable timestamped output directories."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
from catalog import CORES
from verify import ROOT, REPO, environment, source_hashes

SUITE = REPO/'tools/oss-cad-suite/oss-cad-suite'


def command(argv, log, timeout=600):
    program = str(argv[0])
    candidate = SUITE/'bin'/(program+'.exe')
    if candidate.is_file():
        argv = [str(candidate), *argv[1:]]
    with log.open('wb') as stream:
        proc = subprocess.run([str(v) for v in argv], cwd=ROOT, env=environment(),
                              stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    if proc.returncode:
        raise RuntimeError(f'{program} exit={proc.returncode}; see {log}')


def metrics(netlist, top):
    data = json.loads(netlist.read_text())
    counts = Counter(cell['type'] for cell in data['modules'][top]['cells'].values())
    lut = sum(n for t, n in counts.items() if re.fullmatch(r'LUT[1-9]|ALU', t))
    dsp = sum(n for t, n in counts.items() if re.search(r'MULT|PADD|ALU54|MULTALU|MULTADD', t))
    bram = sum(n for t, n in counts.items() if re.fullmatch(r'(?:SP|SDP|DP|ROM)(?:X9)?B?', t))
    ff = sum(n for t, n in counts.items() if t.startswith('DFF'))
    return dict(lut_class=lut, dsp_class=dsp, bram_blocks=bram, ff_class=ff,
                cells=dict(sorted(counts.items())), under_budget=(lut<=15000 and dsp<=4 and bram<=46))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--groups', default='0,1,2,3,4,5,6')
    ap.add_argument('--isolated', action='store_true')
    ap.add_argument('--isolated-core', help='synthesize just this changed core')
    ap.add_argument('--synth-only', action='store_true')
    args = ap.parse_args()
    groups = [int(v) for v in args.groups.split(',')]
    if any(g not in range(7) for g in groups):
        ap.error('groups must be 0..6')
    out = ROOT/'evidence'/('build_'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ'))
    out.mkdir(parents=True, exist_ok=False)
    summary = dict(timestamp=datetime.now(timezone.utc).isoformat(),
                   device='GW5A-LV25MG121NES', family='GW5A-25A',
                   synthesis='synth_gowin -family gw5a -noalu',
                   physical_clock_mhz=50, enabled_beat_mhz=3.125,
                   timing_target_mhz=50, groups=[], isolated=[], sources=source_hashes())

    def checkpoint():
        (out/'summary.json').write_text(json.dumps(summary, indent=2)+'\n', encoding='utf-8')

    if args.isolated or args.isolated_core:
        selected = [e for e in CORES if not args.isolated_core or e['name']==args.isolated_core]
        if not selected:
            ap.error('unknown isolated core')
        for entry in selected:
            name = entry['name']
            script = out/(name+'.ys')
            netlist = out/(name+'.json')
            script.write_text(f'read_verilog rtl/prod_{name}.v\nsynth_gowin -family gw5a -noalu -top prod_{name} -json {netlist.as_posix()}\nstat\n')
            command(['yosys', '-s', script], out/(name+'.log'))
            row = dict(name=name, **metrics(netlist, 'prod_'+name))
            if not row['under_budget']:
                raise RuntimeError('isolated IP over budget: '+name)
            summary['isolated'].append(row)
            checkpoint()
            print(f'SYNTH {name}: LUT={row["lut_class"]} FF={row["ff_class"]} DSP={row["dsp_class"]}', flush=True)
    for group in groups:
        sources = [f'rtl/prod_{e["name"]}.v' for e in CORES[group*8:group*8+8]]
        # Top references all groups through generate-if; only the selected branch is elaborated.
        sources += [f'board/prod_board_group_{g}.v' for g in range(7)]
        sources += ['board/prod_top.v', 'board/prod_uart_tx.v']
        netlist = out/f'group_{group}.json'
        script = out/f'group_{group}.ys'
        script.write_text('read_verilog '+ ' '.join(sources)+'\n'+
                          f'chparam -set GROUP {group} prod_top\n'+
                          f'synth_gowin -family gw5a -noalu -top prod_top -json {netlist.as_posix()}\nstat\n')
        command(['yosys', '-s', script], out/f'group_{group}_yosys.log')
        row = dict(group=group, synthesis='PASS', route='NOT_RUN', **metrics(netlist, 'prod_top'))
        summary['groups'].append(row)
        checkpoint()
        if not row['under_budget']:
            raise RuntimeError(f'group {group} exceeds 15K LUT/4DSP/46 BRAM budget')
        print(f'GROUP {group}: LUT={row["lut_class"]} FF={row["ff_class"]} DSP={row["dsp_class"]} BRAM={row["bram_blocks"]}', flush=True)
        if args.synth_only:
            continue
        routed = out/f'group_{group}_pnr.json'
        command(['nextpnr-himbaechel', '--json', netlist, '--write', routed,
                 '--device', summary['device'], '--vopt', 'family=GW5A-25A',
                 '--vopt', 'cst=board/tang25k.cst', '--vopt', 'sspi_as_gpio',
                 '--freq', '50'], out/f'group_{group}_nextpnr.log')
        row['route'] = 'PASS'
        route_text = (out/f'group_{group}_nextpnr.log').read_text(encoding='utf-8', errors='replace')
        row['timing_lines'] = [line for line in route_text.splitlines()
                               if 'Max frequency' in line or 'Device utilisation' in line]
        checkpoint()
        fs = out/f'group_{group}.fs'
        command([SUITE/'lib/python3.exe', SUITE/'bin/gowin_pack-script.py',
                 '-d', 'GW5A-25A', '--sspi_as_gpio', '-o', fs, routed], out/f'group_{group}_pack.log')
        row['bitstream'] = fs.relative_to(ROOT).as_posix()
        row['bitstream_sha256'] = hashlib.sha256(fs.read_bytes()).hexdigest()
        row['bitstream_bytes'] = fs.stat().st_size
        checkpoint()
        print(f'PACK group={group} PASS bytes={fs.stat().st_size}', flush=True)
    print(f'Build evidence={out}')


if __name__ == '__main__':
    main()
