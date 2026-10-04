"""Isolated Gowin mapping for INFRA-07 stream test-source/sink cores.

Runs `synth_gowin -noalu -family gw2a` on each RTL module (and two
representative parameterizations where meaningful) and records
LUT1-4 / FF / DSP / BRAM counts plus wide-mux counts per configuration.

No place-and-route, pin fit, routed timing, or board claim is made.
"""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime

BASE = Path(__file__).resolve().parents[1]
ROOT = BASE.parents[3]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = (str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') +
               os.pathsep + env['PATH'])

# (top, parameter overrides)
CONFIGS = [
    ('crc32', {}),
    ('crc32', {'DATA_WIDTH': 8}),
    ('crc32', {'DATA_WIDTH': 32}),
    ('prbs_source', {}),
    ('tone_source', {}),
    ('tone_source', {'MAX_TONES': 2}),
    ('image_pattern_source', {}),
    ('image_pattern_source', {'DATA_WIDTH': 16, 'MAX_W': 4096, 'MAX_H': 4096}),
    ('backpressure_sink', {}),
    ('backpressure_sink', {'DATA_WIDTH': 8}),
    ('stream_sink_checker', {}),
    ('stream_sink_checker', {'DATA_WIDTH': 16}),
]
SRC = {p.stem: p for p in sorted((BASE / 'rtl').glob('*.sv'))}
# checker instantiates crc32; image source has no deps
DEPS = {'stream_sink_checker': ['stream_sink_checker.sv', 'crc32.sv']}

reports = []
for top, params in CONFIGS:
    tag = top + ('' if not params else '_' + '_'.join(
        f'{k}{v}' for k, v in params.items()))
    d = OUT / tag; d.mkdir()
    files = DEPS.get(top, [top + '.sv'])
    reads = ' '.join(f'read_verilog -sv {(BASE/"rtl"/f).as_posix()};'
                     for f in files)
    chp = ''.join(f' chparam -set {k} {v} {top};' for k, v in params.items())
    cmd = (f'{reads}{chp} synth_gowin -noalu -family gw2a -top {top}'
           f' -json core.json; stat')
    (d / 'command.txt').write_text(cmd + '\n')
    p = subprocess.run([str(TOOL / 'bin/yosys.exe'), '-p', cmd], cwd=d,
                       env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    cells = design['modules'][top]['cells'].values()
    counts = collections.Counter(c['type'] for c in cells)
    report = {
        'top': top, 'params': params, 'cells': dict(counts),
        'lut1_4': sum(counts[f'LUT{k}'] for k in range(1, 5)),
        'ff': sum(v for k, v in counts.items() if k.startswith('DFF')),
        'dsp': sum(v for k, v in counts.items()
                   if k.startswith(('MULT', 'PADD', 'ALU54'))),
        'bram': sum(v for k, v in counts.items()
                    if k.startswith(('DPX', 'SPX', 'SDPX', 'ROM'))),
        'wide_mux': sum(v for k, v in counts.items()
                        if k.startswith('MUX'))}
    (d / 'resources.json').write_text(json.dumps(report, indent=2))
    reports.append(report)
    print(tag, 'lut1_4=%d ff=%d dsp=%d bram=%d' %
          (report['lut1_4'], report['ff'], report['dsp'], report['bram']))

budget = {'lut_class_limit': 15000, 'dsp_class_limit': 4}
viol = [r for r in reports if r['lut1_4'] > budget['lut_class_limit']
        or r['dsp'] > budget['dsp_class_limit']]
summary = {
    'status': 'PASS' if not viol else 'BUDGET_VIOLATION',
    'rtl_sha256': {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in sorted(SRC.values())},
    'budget': budget,
    'configurations': reports,
    'scope': ('isolated mapped resources per module; no board pin fit, '
              'routed timing, or physical acceptance')}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps({'status': summary['status'],
                  'budget': budget,
                  'worst_lut': max(r['lut1_4'] for r in reports),
                  'worst_dsp': max(r['dsp'] for r in reports)}, indent=2))
