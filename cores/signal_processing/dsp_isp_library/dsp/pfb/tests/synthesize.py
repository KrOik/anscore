"""Isolated Gowin mapping for pfb_stream; no P&R or board claim.

Runs synth_gowin for the supported (M,P) lattice points.  A matching
pfb_coeffs.vh is generated into each work directory (iverilog/yosys search
the working directory for `include files first).
"""
import os, json, subprocess, hashlib, collections, sys
from pathlib import Path
from datetime import datetime

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from model import prototype, quantize, emit_vh

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir(parents=True)
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib')
               + os.pathsep + env['PATH'])
source = BASE / 'rtl/pfb_stream.sv'
reports = []
for m, p in [(4, 8), (8, 8), (8, 4), (16, 4), (16, 8)]:
    tag = 'm%dp%d' % (m, p)
    d = OUT / tag
    d.mkdir()
    emit_vh(d / 'pfb_coeffs.vh', quantize(prototype(m, p)))
    command = ('verilog_defaults -add -I%s; read_verilog -sv %s; '
               'chparam -set M %d -set P %d pfb_stream; '
               'synth_gowin -top pfb_stream -json core.json; stat'
               % (d.as_posix(), source.as_posix(), m, p))
    (d / 'command.txt').write_text(command + '\n')
    q = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', command],
                       cwd=d, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(q.stdout)
    if q.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['pfb_stream']['cells'].values())
    report = {'config': tag, 'cells': dict(counts),
              'lut1_4': sum(counts['LUT%d' % k] for k in range(1, 5)),
              'ff': sum(v for k, v in counts.items()
                        if k.startswith('DFF')),
              'dsp': sum(v for k, v in counts.items()
                         if k.startswith(('MULT', 'PADD', 'ALU54'))),
              'bram': sum(v for k, v in counts.items()
                          if k.startswith(('DPX', 'SPX', 'SDPX'))),
              'wide_mux': sum(v for k, v in counts.items()
                              if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
    print(tag, 'lut=%d ff=%d dsp=%d bram=%d'
          % (report['lut1_4'], report['ff'], report['dsp'], report['bram']))
summary = {'status': 'PASS',
           'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
