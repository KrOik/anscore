"""Reproducible isolated Gowin synthesis for DSP-08 recovery loops.

synth_gowin without -family (this yosys has no such flag); no P&R/board.
Counts LUT1-4 / DFF* / MULT* / BSRAM-class cells per module.
"""
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

UNITS = {
    'carrier_loop': ['nco.sv', 'pi_loop.sv', 'lock_det.sv', 'carrier_loop.sv'],
    'timing_loop': ['pi_loop.sv', 'lock_det.sv', 'timing_loop.sv'],
    'nco': ['nco.sv'],
    'pi_loop': ['pi_loop.sv'],
    'lock_det': ['lock_det.sv'],
}

reports = {}
for top, files in UNITS.items():
    srcs = ' '.join((BASE / 'rtl' / f).as_posix() for f in files)
    sub = OUT / top
    sub.mkdir()
    command = ('read_verilog -sv %s; synth_gowin -noalu '
               '-top %s -json core.json; stat' % (srcs, top))
    (sub / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(tool / 'bin/yosys.exe'), '-p', command],
                       cwd=sub, env=env, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (sub / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError('synthesis failed for %s: %s' % (top, p.stdout))
    design = json.loads((sub / 'core.json').read_text())
    counts = collections.Counter(c['type'] for c in
                                 design['modules'][top]['cells'].values())
    rep = {'cells': dict(counts),
           'lut1_4': sum(counts['LUT%d' % k] for k in range(1, 5)),
           'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
           'dsp': sum(v for k, v in counts.items()
                      if k.startswith(('MULT', 'PADD', 'ALU54'))),
           'bram': sum(v for k, v in counts.items()
                       if k.startswith(('DPX', 'SPX', 'SDPX', 'pARAM',
                                        'RAM', 'ROM')))}
    reports[top] = rep

for top, rep in reports.items():
    assert rep['dsp'] <= 4 and rep['lut1_4'] <= 15000, (top, rep)

summary = {'status': 'PASS',
           'source_sha256': {f: hashlib.sha256(
               (BASE / 'rtl' / f).read_bytes()).hexdigest()
               for f in sorted(set(sum(UNITS.values(), [])))},
           'configurations': reports,
           'scope': 'isolated mapped core resources only; no routed timing, '
                    'wrapper, chain or physical acceptance'}
(OUT / 'resources.json').write_text(json.dumps(reports, indent=2))
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
