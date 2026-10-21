"""Isolated Gowin mapping for INFRA-05 cores; no P&R or board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep + env['PATH']

CONFIGS = [
    ('sat_round', 'rtl/sat_round.sv', 'sat_round',
     {'IN_W': 32, 'OUT_W': 16, 'SHIFT': 15, 'SIGNED_IN': 1}),
    ('cplx_mac', 'rtl/cplx_mac.sv', 'cplx_mac',
     {'DATA_W': 16, 'ACC_W': 48, 'OUT_W': 32, 'SHIFT': 0}),
    ('cplx_mac_small', 'rtl/cplx_mac.sv', 'cplx_mac',
     {'DATA_W': 16, 'ACC_W': 40, 'OUT_W': 32, 'SHIFT': 0}),
    ('div_iter', 'rtl/recip_div.sv', 'fp_div_iter',
     {'AW': 16, 'BW': 16, 'FB': 15, 'OUT_W': 18}),
    ('div_pipe', 'rtl/recip_div.sv', 'fp_div_pipe',
     {'AW': 16, 'BW': 16, 'FB': 15, 'OUT_W': 18}),
    ('sqrt_iter', 'rtl/sqrt_unit.sv', 'fp_sqrt_iter',
     {'IN_W': 32, 'FB': 8}),
    ('sqrt_pipe', 'rtl/sqrt_unit.sv', 'fp_sqrt_pipe',
     {'IN_W': 32, 'FB': 8}),
    ('log2_iter', 'rtl/log2exp2.sv', 'fp_log2_iter',
     {'IN_W': 16, 'FB': 12, 'G': 6, 'SIGNED_IN': 0}),
    ('exp2_iter', 'rtl/log2exp2.sv', 'fp_exp2_iter',
     {'IW': 16, 'FB': 12, 'G': 6, 'OUT_W': 13, 'FRACO': 6}),
    ('exp2_wide', 'rtl/log2exp2.sv', 'fp_exp2_iter',
     {'IW': 16, 'FB': 12, 'G': 6, 'OUT_W': 28, 'FRACO': 12}),
]

reports = []
for name, src, top, params in CONFIGS:
    d = OUT / name
    d.mkdir()
    source = (BASE / src).resolve()
    chp = ' '.join(f'-set {k} {v}' for k, v in params.items())
    command = (f'read_verilog -sv {source.as_posix()}; chparam {chp} {top}; '
               f'synth_gowin -noalu -family gw2a -top {top} -json core.json; stat')
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', command], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d) + ': ' + p.stdout[-2000:])
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules'][top]['cells'].values())
    report = {'name': name, 'top': top, 'params': params, 'cells': dict(counts),
              'lut1_4': sum(counts[f'LUT{k}'] for k in range(1, 5)),
              'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
              'dsp': sum(v for k, v in counts.items()
                         if k.startswith(('MULT', 'PADD', 'ALU54'))),
              'bram': sum(v for k, v in counts.items()
                          if k.startswith(('DPX', 'SPX', 'SDPX'))),
              'wide_mux': sum(v for k, v in counts.items()
                              if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)

summary = {'status': 'PASS',
           'source_sha256': {s: hashlib.sha256((BASE / s).read_bytes()).hexdigest()
                             for s in {c[1] for c in CONFIGS}},
           'configurations': reports,
           'scope': 'isolated mapped resources; no board pin fit, routed '
                    'timing or physical acceptance'}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
for r in reports:
    print(f"{r['name']:>14} LUT1-4={r['lut1_4']:>6} FF={r['ff']:>6} "
          f"DSP={r['dsp']:>3} BRAM={r['bram']:>3} MUX={r['wide_mux']:>5}")
