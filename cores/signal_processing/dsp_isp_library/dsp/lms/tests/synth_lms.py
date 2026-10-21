"""Isolated Gowin synthesis for DSP-15 lms_stream; core-only, no P&R or board.

Uses the required flow: read_verilog -sv (lms + fp_div dependency), then
synth_gowin -top lms_stream (no -family on this tool version).  Synthesizes
IMPL={0,1} x MULT_DSP={1,0} at NTAPS=8 plus a small-NTAPS reference point so
the resource table covers both implementations and both multiplier styles.
"""
import os, sys, json, subprocess, collections, hashlib
from pathlib import Path
from datetime import datetime

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') + os.pathsep + env['PATH']
RTL = BASE / 'rtl/lms_stream.sv'
DIV = ROOT / 'cores/signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv'

variants = [
    dict(NTAPS=8, IMPL=0, MULT_DSP=1, name='serial_dsp'),
    dict(NTAPS=8, IMPL=0, MULT_DSP=0, name='serial_logic'),
    dict(NTAPS=8, IMPL=1, MULT_DSP=1, name='parallel_dsp'),
    dict(NTAPS=8, IMPL=1, MULT_DSP=0, name='parallel_logic'),
    dict(NTAPS=4, IMPL=1, MULT_DSP=1, name='parallel4_dsp'),
]
reports = []
for v in variants:
    d = OUT / v['name']
    d.mkdir()
    command = (f'read_verilog -sv {RTL.as_posix()} {DIV.as_posix()}; '
               f'chparam -set NTAPS {v["NTAPS"]} -set IMPL {v["IMPL"]} '
               f'-set MULT_DSP {v["MULT_DSP"]} lms_stream; '
               f'synth_gowin -top lms_stream -json core.json; stat')
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', command], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(f'{v["name"]} synthesis failed: {d}\n{p.stdout[-3000:]}')
    j = json.loads((d / 'core.json').read_text())
    c = collections.Counter(
        cell['type'] for cell in j['modules']['lms_stream']['cells'].values())
    report = dict(v)
    report['cells'] = dict(c)
    report['lut'] = sum(c[f'LUT{k}'] for k in range(1, 5))
    report['alu'] = c.get('ALU', 0)          # Gowin ALU adders (LUT-class)
    report['ff'] = sum(n for k, n in c.items() if k.startswith('DFF'))
    report['dsp'] = sum(n for k, n in c.items()
                        if k.startswith(('MULT', 'PADD')))
    report['dist_ram'] = sum(n for k, n in c.items()
                             if k.startswith('RAM16'))
    report['bram'] = sum(n for k, n in c.items()
                         if k.startswith(('DPX', 'SPX', 'SDPX', 'SDP', 'SP')))
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
    print(f'  {v["name"]}: lut={report["lut"]} alu={report["alu"]} '
          f'ff={report["ff"]} dsp={report["dsp"]} '
          f'dram={report["dist_ram"]} bram={report["bram"]}')

# MULT_DSP=0 variants must show no inferred DSP/ALU multipliers
for r in reports:
    if r['MULT_DSP'] == 0:
        assert r['dsp'] == 0, r

summary = {'status': 'PASS',
           'rtl_sha256': hashlib.sha256(RTL.read_bytes()).hexdigest(),
           'div_sha256': hashlib.sha256(DIV.read_bytes()).hexdigest(),
           'variants': reports,
           'scope': ('isolated core synthesis only; no wrapper, board image, '
                    'P&R, timing, or hardware qualification')}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
