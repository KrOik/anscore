"""Isolated Gowin mapping for each DSP-05 spectrum core; no P&R/board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep \
    + env['PATH']
RTL = BASE / 'rtl'
targets = {
    'window_mult': [RTL / 'window_cos_rom.sv', RTL / 'window_mult.sv'],
    'mag_squared': [RTL / 'mag_squared.sv'],
    'block_accum': [RTL / 'block_accum.sv'],
    'peak_search': [RTL / 'peak_search.sv'],
}
reports = {}
for top, files in targets.items():
    d = OUT / top
    d.mkdir()
    reads = ' '.join(f'read_verilog -sv {f.as_posix()};' for f in files)
    command = (f'{reads} synth_gowin -noalu -family gw2a -top {top} '
               f'-json core.json; stat')
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules'][top]['cells'].values())
    report = {
        'top': top, 'cells': dict(counts),
        'lut1_4': sum(counts.get(f'LUT{k}', 0) for k in range(1, 5)),
        'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
        'dsp': sum(v for k, v in counts.items()
                   if k.startswith(('MULT', 'PADD', 'ALU54'))),
        'bram': sum(v for k, v in counts.items()
                    if k.startswith(('DPX', 'SPX', 'SDPX'))),
        'wide_mux': sum(v for k, v in counts.items() if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports[top] = report
summary = {'status': 'PASS',
           'source_sha256': {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
                             for f in sorted(RTL.glob('*.sv'))},
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps({k: {kk: v[kk] for kk in ('lut1_4', 'ff', 'dsp', 'bram')}
                  for k, v in reports.items()}, indent=2))
