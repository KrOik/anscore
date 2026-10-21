"""Isolated Gowin mapping for ISP-14 ccm_stream; no P&R or board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools' / 'oss-cad-suite' / 'oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep + env['PATH']
yosys = str(tool / 'bin' / 'yosys.exe')
src = (BASE / 'rtl' / 'ccm_stream.sv').as_posix()
reports = []
for bits in (8, 10):
    tag = f'ccm_stream_bits{bits}'
    d = OUT / tag
    d.mkdir()
    command = ('read_verilog -sv %s; chparam -set BITS %d ccm_stream; '
               'synth_gowin -top ccm_stream -json core.json; stat'
               % (src, bits))
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([yosys, '-p', command], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules']['ccm_stream']['cells'].values())
    report = dict(bits=bits, module='ccm_stream', cells=dict(counts),
        lut1_4=sum(counts[f'LUT{k}'] for k in range(1, 5)),
        ff=sum(v for k, v in counts.items() if k.startswith('DFF')),
        dsp=sum(v for k, v in counts.items()
                if k.startswith(('MULT', 'PADD', 'ALU54'))),
        bram=sum(v for k, v in counts.items()
                 if k.startswith(('DPX', 'SPX', 'SDPX'))),
        wide_mux=sum(v for k, v in counts.items() if k.startswith('MUX')))
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
summary = {
    'status': 'PASS',
    'source_sha256': {'ccm_stream.sv': hashlib.sha256(
        Path(src).read_bytes()).hexdigest()},
    'configurations': reports,
    'scope': 'isolated mapped resources; no board pin fit, routed timing or physical acceptance',
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
