"""Isolated Gowin mapping for ISP-11; no P&R or board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(tool / 'lib') + os.pathsep + str(tool / 'bin') + os.pathsep + env['PATH']
sources = [BASE / 'rtl/histeq_stream.sv']
reports = []
configs = [
    dict(BITS=8, MAX_W=32, MAX_H=24),
    dict(BITS=10, MAX_W=32, MAX_H=24),
    dict(BITS=10, MAX_W=64, MAX_H=64),
    dict(BITS=8, MAX_W=128, MAX_H=64),
]
for cfg in configs:
    tag = 'b%d_w%d_h%d' % (cfg['BITS'], cfg['MAX_W'], cfg['MAX_H'])
    d = OUT / tag
    d.mkdir()
    sets = ' '.join('-set %s %s' % kv for kv in cfg.items())
    command = ('read_verilog -sv %s; chparam %s histeq_stream; '
               'synth_gowin -noalu -family gw2a -top histeq_stream -json core.json; stat'
               % (' '.join(s.as_posix() for s in sources), sets))
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['histeq_stream']['cells'].values())
    report = dict(cfg, cells=dict(counts),
        lut1_4=sum(counts[f'LUT{k}'] for k in range(1, 5)),
        ff=sum(v for k, v in counts.items() if k.startswith('DFF')),
        dsp=sum(v for k, v in counts.items() if k.startswith(('MULT', 'PADD', 'ALU54'))),
        bram=sum(v for k, v in counts.items() if k.startswith(('DPX', 'SPX', 'SDPX'))),
        wide_mux=sum(v for k, v in counts.items() if k.startswith('MUX')))
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
summary = {
    'status': 'PASS',
    'source_sha256': {s.name: hashlib.sha256(s.read_bytes()).hexdigest()
                      for s in sources},
    'configurations': reports,
    'scope': 'isolated mapped resources; no board pin fit, routed timing or physical acceptance',
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
