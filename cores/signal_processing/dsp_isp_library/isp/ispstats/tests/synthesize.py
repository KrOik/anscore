"""Isolated Gowin mapping for ISP-12; no P&R or board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
# OSS CAD Suite: lib before bin on PATH or external MinGW DLLs crash tools.
env['PATH'] = str(tool / 'lib') + os.pathsep + str(tool / 'bin') + os.pathsep + env['PATH']
sources = [BASE / 'rtl/ispstats_stream.sv']
reports = []
configs = [
    dict(BITS=8,  CH=3, MAX_W=32,  MAX_H=24),
    dict(BITS=8,  CH=1, MAX_W=32,  MAX_H=24),
    dict(BITS=10, CH=3, MAX_W=64,  MAX_H=64),
    dict(BITS=10, CH=3, MAX_W=256, MAX_H=256),
]
for cfg in configs:
    tag = 'b%d_c%d_w%d_h%d' % (cfg['BITS'], cfg['CH'], cfg['MAX_W'], cfg['MAX_H'])
    d = OUT / tag
    d.mkdir()
    sets = ' '.join('-set %s %s' % kv for kv in cfg.items())
    command = ('read_verilog -sv %s; chparam %s ispstats_stream; '
               'synth_gowin -noalu -family gw2a -top ispstats_stream -json core.json; stat'
               % (' '.join(s.as_posix() for s in sources), sets))
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['ispstats_stream']['cells'].values())
    assert not any('LATCH' in t.upper() for t in counts)
    report = dict(cfg, cells=dict(counts),
        lut1_4=sum(counts[f'LUT{k}'] for k in range(1, 5)),
        ff=sum(v for k, v in counts.items() if k.startswith('DFF')),
        dsp=sum(v for k, v in counts.items() if k.startswith(('MULT', 'PADD', 'ALU54'))),
        bram=sum(v for k, v in counts.items()
                 if k.startswith(('DPX', 'SPX', 'SDPX')) or k in ('DPB', 'SP', 'SDPB')),
        wide_mux=sum(v for k, v in counts.items() if k.startswith('MUX')))
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
    print(tag, 'LUT1-4=%d FF=%d DSP=%d BRAM=%d' % (
        report['lut1_4'], report['ff'], report['dsp'], report['bram']), flush=True)
summary = {
    'status': 'PASS',
    'source_sha256': {s.name: hashlib.sha256(s.read_bytes()).hexdigest()
                      for s in sources},
    'configurations': reports,
    'scope': 'isolated mapped resources; no board pin fit, routed timing or physical acceptance',
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
