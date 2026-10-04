"""Isolated Gowin mapping for ISP-08 basic_isp; no P&R or board claim."""
import os, json, subprocess, hashlib, collections
from pathlib import Path
from datetime import datetime
BASE = Path(__file__).resolve().parents[1]
LIB = BASE.parents[1]
ROOT = LIB.parents[1]
OUT = BASE / 'evidence' / ('synth_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
OUT.mkdir()
tool = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
env = os.environ.copy()
env['PATH'] = str(tool / 'bin') + os.pathsep + str(tool / 'lib') + os.pathsep + env['PATH']
yosys = str(tool / 'bin/yosys.exe')
infra = LIB / 'infra/window'
all_rtl = sorted(BASE.glob('rtl/*.sv'))
top_src = [s.as_posix() for s in all_rtl] + \
    [(infra / 'stream_window.v').as_posix(),
     (infra / 'stream_window_padded.v').as_posix()]
incdir = (BASE / 'rtl').as_posix()
reports = []

# Top-level configurations.
configs = [
    dict(BITS=8,  CH=3, WIDTH=32, HEIGHT=24),
    dict(BITS=10, CH=3, WIDTH=32, HEIGHT=24),
    dict(BITS=10, CH=3, WIDTH=64, HEIGHT=64),
    dict(BITS=10, CH=1, WIDTH=64, HEIGHT=64),
    dict(BITS=8,  CH=1, WIDTH=8,  HEIGHT=8),
]
jobs = [('basic_isp_top', top_src, c) for c in configs]
# Per-stage standalone mappings (stage-verification evidence + cost split).
for mod, files, st_cfg in (
        ('isp_blc', ['isp_blc.sv'], dict(BITS=8, CH=3)),
        ('isp_wb_gain', ['isp_wb_gain.sv'], dict(BITS=8, CH=3)),
        ('isp_gamma', ['isp_gamma.sv'], dict(BITS=8, CH=3)),
        ('isp_awb_stats', ['isp_awb_stats.sv'],
         dict(BITS=8, CH=3, WIDTH=32, HEIGHT=24)),
        ('isp_dpc', ['isp_dpc.sv'], dict(BITS=8, CH=3, WIDTH=32, HEIGHT=24))):
    srcs = [(BASE / 'rtl' / f).as_posix() for f in files]
    if mod == 'isp_dpc':
        srcs += [(infra / 'stream_window.v').as_posix(),
                 (infra / 'stream_window_padded.v').as_posix()]
    jobs.append((mod, srcs, st_cfg))

for top, sources, cfg in jobs:
    tag = '%s_%s' % (top, '_'.join('%s%d' % (k.lower(), v)
                                   for k, v in cfg.items()))
    d = OUT / tag
    d.mkdir()
    sets = ' '.join('-set %s %s' % kv for kv in cfg.items())
    command = ('read_verilog -sv -I %s %s; chparam %s %s; '
               'synth_gowin -noalu -family gw2a -top %s -json core.json; stat'
               % (incdir, ' '.join(sources), sets, top, top))
    (d / 'command.txt').write_text(command + '\n')
    p = subprocess.run([yosys, '-p', command], cwd=d, env=env,
                       text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (d / 'yosys.log').write_text(p.stdout)
    if p.returncode:
        raise RuntimeError(str(d))
    design = json.loads((d / 'core.json').read_text())
    counts = collections.Counter(
        c['type'] for c in design['modules'][top]['cells'].values())
    report = dict(cfg, module=top, cells=dict(counts),
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
    'source_sha256': {Path(s).name: hashlib.sha256(Path(s).read_bytes()).hexdigest()
                      for s in top_src} | {'gamma_table.vh': hashlib.sha256(
                          (BASE / 'rtl/gamma_table.vh').read_bytes()).hexdigest()},
    'configurations': reports,
    'scope': 'isolated mapped resources; no board pin fit, routed timing or physical acceptance',
}
(OUT / 'summary.json').write_text(json.dumps(summary, indent=2))
print(OUT)
print(json.dumps(summary, indent=2))
