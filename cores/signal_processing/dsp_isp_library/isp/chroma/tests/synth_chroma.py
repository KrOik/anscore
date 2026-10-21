"""Isolated Gowin mapping for the ISP-15 chroma/pix_pack cores.

synth_gowin is invoked WITHOUT a -family flag (task requirement); mapped
cells are counted from the emitted JSON.  Isolated resources only - no
P&R, timing or board claim.
"""
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
from collections import Counter

HERE = pathlib.Path(__file__).resolve().parent
BASE = HERE.parent
ROOT = BASE.parents[3]
TOOL = ROOT / 'tools/oss-cad-suite/oss-cad-suite'


def main():
    out = BASE / 'evidence' / ('synth_' + datetime.datetime.now()
                               .strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True)
    src = out / 'sources'
    src.mkdir()
    files = [BASE / 'rtl' / n for n in
             ('chroma_422.sv', 'chroma_420.sv', 'pix_pack.sv')]
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest()
         for f in files}, indent=2))
    src = src.resolve()
    env = dict(os.environ)
    env['PATH'] = str(TOOL / 'bin') + os.pathsep + str(TOOL / 'lib') \
        + os.pathsep + env['PATH']
    yo = shutil.which('yosys', path=env['PATH'])

    # (name, source set, top, chparams)
    jobs = [
        ('c422_w32h24_d8', ['chroma_422.sv'], 'chroma_422',
         dict(WIDTH=32, HEIGHT=24, BITS=8)),
        ('c422_w64h48_d10', ['chroma_422.sv'], 'chroma_422',
         dict(WIDTH=64, HEIGHT=48, BITS=10)),
        ('c422_w1920h1080_d8', ['chroma_422.sv'], 'chroma_422',
         dict(WIDTH=1920, HEIGHT=1080, BITS=8)),
        ('c420_w32h24_d8_src0', ['chroma_422.sv', 'chroma_420.sv'],
         'chroma_420', dict(WIDTH=32, HEIGHT=24, BITS=8, SRC422=0)),
        ('c420_w64h48_d10_src0', ['chroma_422.sv', 'chroma_420.sv'],
         'chroma_420', dict(WIDTH=64, HEIGHT=48, BITS=10, SRC422=0)),
        ('c420_w64h48_d8_src1', ['chroma_422.sv', 'chroma_420.sv'],
         'chroma_420', dict(WIDTH=64, HEIGHT=48, BITS=8, SRC422=1)),
        ('c420_w1920h1080_d8_src0', ['chroma_422.sv', 'chroma_420.sv'],
         'chroma_420', dict(WIDTH=1920, HEIGHT=1080, BITS=8, SRC422=0)),
        ('pack_d8_ns4', ['pix_pack.sv'], 'pix_pack',
         dict(BITS=8, NS=4, SLOT=0)),
        ('pack_d10_ns4_s0', ['pix_pack.sv'], 'pix_pack',
         dict(BITS=10, NS=4, SLOT=0)),
        ('pack_d10_ns2_s16', ['pix_pack.sv'], 'pix_pack',
         dict(BITS=10, NS=2, SLOT=16)),
        ('unpack_d8_ns4', ['pix_pack.sv'], 'pix_unpack',
         dict(BITS=8, NS=4, SLOT=0)),
        ('unpack_d10_ns2_s16', ['pix_pack.sv'], 'pix_unpack',
         dict(BITS=10, NS=2, SLOT=16)),
    ]
    reports = []
    for name, sources, top, params in jobs:
        case = out / name
        case.mkdir()
        script = ''.join(
            f'read_verilog -sv "{(src / s).as_posix()}"\n' for s in sources)
        script += ''.join(f'chparam -set {k} {v} {top}\n'
                          for k, v in params.items())
        script += f'synth_gowin -top {top} -json mapped.json\nstat\n'
        (case / 'build.ys').write_text(script)
        r = subprocess.run([yo, '-s', 'build.ys'], cwd=case, env=env,
                           capture_output=True, text=True)
        (case / 'synth.log').write_text(r.stdout + r.stderr)
        assert r.returncode == 0, (name, r.stdout[-2000:])
        cells = Counter(c['type'] for c in json.loads(
            (case / 'mapped.json').read_text())['modules'][top]
            ['cells'].values())
        dsp = sum(n for t, n in cells.items()
                  if t.startswith(('MULT', 'PADD', 'ALU54')))
        assert dsp <= 4, (name, cells)
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(config=name, top=top, **params,
                   LUT1_4=sum(cells.get('LUT' + str(i), 0)
                              for i in range(1, 5)),
                   FF=sum(n for t, n in cells.items()
                          if t.startswith('DFF')),
                   BSRAM=sum(cells.get(t, 0) for t in
                             ('SPX9', 'DPX9B', 'SDPX9B', 'SP', 'DPB',
                              'SDPB')),
                   DSP=dsp, raw_cells=dict(cells),
                   status='SYNTHESIS PASS', timing='NOT RUN',
                   board='NOT RUN')
        (case / 'resources.json').write_text(json.dumps(row, indent=2))
        reports.append(row)
        print(name, 'LUT', row['LUT1_4'], 'FF', row['FF'],
              'DSP', dsp, 'BRAM', row['BSRAM'], flush=True)
    summary = {'status': 'PASS', 'configurations': reports,
               'scope': 'isolated mapped resources; synth_gowin without '
                        '-family; no board pin fit, routed timing or '
                        'physical acceptance'}
    (out / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(out)


if __name__ == '__main__':
    main()
