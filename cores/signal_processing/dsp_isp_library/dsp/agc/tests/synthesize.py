"""Reproducible isolated Gowin synthesis for agc_stream; no P&R/board."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(tool / 'bin') + os.pathsep + str(tool / 'lib')
               + os.pathsep + env['PATH'])
source = BASE / 'rtl/agc_stream.sv'
command = ('read_verilog -sv %s; synth_gowin -noalu -family gw2a '
           '-top agc_stream -json core.json; stat' % source.as_posix())
(OUT / 'command.txt').write_text(command + '\n')
p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command], cwd=OUT,
                   env=env, text=True, stdout=subprocess.PIPE,
                   stderr=subprocess.STDOUT)
(OUT / 'yosys.log').write_text(p.stdout)
if p.returncode:
    raise RuntimeError('synthesis failed: ' + p.stdout)
design = json.loads((OUT / 'core.json').read_text())
counts = collections.Counter(c['type'] for c in
                             design['modules']['agc_stream']['cells'].values())
report = {'cells': dict(counts),
          'lut1_4': sum(counts['LUT%d' % k] for k in range(1, 5)),
          'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
          'dsp': sum(v for k, v in counts.items()
                     if k.startswith(('MULT', 'PADD', 'ALU54'))),
          'bram': sum(v for k, v in counts.items()
                      if k.startswith(('DPX', 'SPX', 'SDPX')))}
assert report['dsp'] <= 4 and report['lut1_4'] <= 15000, report
(OUT / 'resources.json').write_text(json.dumps(report, indent=2))
summary = {'status': 'PASS',
           'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
           'configurations': [report],
           'scope': 'isolated mapped core resources only; no routed timing, '
                    'wrapper, chain or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
