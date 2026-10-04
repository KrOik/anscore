"""Isolated Gowin mapping for ISP-07 bayer_demosaic; no P&R or board claim."""
import os, json, subprocess, hashlib, collections, sys
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(tool / 'bin') + os.pathsep + str(tool / 'lib')
               + os.pathsep + env['PATH'])
sources = [LIB / 'infra/window/stream_window.v',
           LIB / 'infra/window/stream_window_padded.v',
           BASE / 'rtl/bayer_demosaic.sv']
reports = []
configs = [
    dict(BITS=8, WIDTH=32, HEIGHT=24),
    dict(BITS=10, WIDTH=64, HEIGHT=64),
    dict(BITS=10, WIDTH=128, HEIGHT=128),
]
for cfg in configs:
    tag = 'b%d_w%d_h%d' % (cfg['BITS'], cfg['WIDTH'], cfg['HEIGHT'])
    d = OUT / tag
    d.mkdir()
    sets = ' '.join('-set %s %s' % kv for kv in cfg.items())
    command = ('read_verilog -sv %s; chparam %s bayer_demosaic; '
               'synth_gowin -noalu -family gw2a -top bayer_demosaic '
               '-json core.json; stat'
               % (' '.join(s.resolve().as_posix() for s in sources), sets))
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['bayer_demosaic']['cells'].values())
    report = dict(cfg, cells=dict(counts),
        lut1_4=sum(counts[f'LUT{k}'] for k in range(1, 5)),
        ff=sum(v for k, v in counts.items() if k.startswith('DFF')),
        dsp=sum(v for k, v in counts.items()
                if k.startswith(('MULT', 'PADD', 'ALU54'))),
        bram=sum(v for k, v in counts.items()
                 if k.startswith(('DPX', 'SPX', 'SDPX', 'DPB', 'SDPB', 'SP'))),
        wide_mux=sum(v for k, v in counts.items() if k.startswith('MUX')))
    assert report['dsp'] == 0, report          # demosaic is multiplier-free
    assert not any('LATCH' in t.upper() for t in counts)
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
summary = {
    'status': 'PASS',
    'source_sha256': {s.name: hashlib.sha256(s.read_bytes()).hexdigest()
                      for s in sources},
    'configurations': reports,
    'scope': 'isolated mapped resources; includes stream_window_padded/'
             'stream_window infra; no board pin fit, routed timing or '
             'physical acceptance',
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
