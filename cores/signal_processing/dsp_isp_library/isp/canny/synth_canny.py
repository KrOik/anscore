"""Isolated synthesis of canny_stream via yosys synth_gowin (no -family flag,
per repo ISP-16 requirement) with a hard four-DSP gate."""
import datetime, hashlib, json, os, shutil, subprocess, sys
from collections import Counter
import pathlib
HERE = pathlib.Path(__file__).resolve().parent          # isp/canny
LIB = HERE.parents[1]                                    # dsp_isp_library
ROOT = LIB.parents[1]                                    # repo root


def main():
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    out = HERE / 'evidence' / ('synth_' + stamp)
    out.mkdir(parents=True)
    src = out / 'sources'; src.mkdir()
    files = [HERE / 'rtl/canny_stream.sv',
             LIB / 'infra/window/stream_window.v',
             LIB / 'infra/window/stream_window_padded.v',
             HERE / 'synth_canny.py']
    for f in files:
        shutil.copy2(f, src / f.name)
    (out / 'hashes.json').write_text(json.dumps(
        {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in files},
        indent=2))
    env = dict(os.environ)
    cad = ROOT / 'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = (str(cad / 'bin') + os.pathsep + str(cad / 'lib')
                   + os.pathsep + env['PATH'])
    results = []
    for w, h, d, pad, p in [(32, 24, 8, 0, 4), (32, 24, 8, 1, 4),
                            (128, 128, 8, 0, 4), (128, 128, 10, 0, 2)]:
        case = out / f'w{w}_h{h}_d{d}_pad{pad}_p{p}'; case.mkdir()
        script = ''.join(
            f'read_verilog -sv "{(src / f.name).resolve().as_posix()}"\n'
            for f in files if f.suffix == '.sv' or f.suffix == '.v')
        script += (f'chparam -set WIDTH {w} -set HEIGHT {h} -set BITS {d}'
                   f' -set PAD_MODE {pad} -set PASSES {p} canny_stream\n'
                   'synth_gowin -noalu -top canny_stream -json mapped.json\n'
                   'stat\n')
        (case / 'build.ys').write_text(script)
        r = subprocess.run([shutil.which('yosys', path=env['PATH']),
                            '-s', 'build.ys'], cwd=case, env=env,
                           capture_output=True, text=True, timeout=600)
        (case / 'synth.log').write_text(r.stdout + r.stderr)
        assert r.returncode == 0, (case, (r.stdout + r.stderr)[-3000:])
        cells = Counter(c['type'] for c in json.loads(
            (case / 'mapped.json').read_text())['modules']['canny_stream']
            ['cells'].values())
        dsp = sum(n for t, n in cells.items()
                  if t.startswith(('MULT', 'PADD', 'ALU54', 'MULT9', 'MULT18',
                                   'MULT36')))
        assert dsp <= 4, cells
        assert not any('LATCH' in t.upper() for t in cells)
        row = dict(width=w, height=h, bits=d, padding=pad, passes=p,
                   LUT1_4=sum(cells.get('LUT' + str(i), 0)
                              for i in range(1, 5)),
                   FF=sum(n for t, n in cells.items()
                          if t.startswith('DFF')),
                   BSRAM=sum(cells.get(t, 0) for t in
                             ('SPX9', 'DPX9B', 'SDPX9B', 'SP', 'DPB',
                              'SDPB', 'BSRAM')),
                   DSP=dsp, raw_cells=dict(cells),
                   status='SYNTHESIS PASS', timing='NOT RUN',
                   board='NOT RUN')
        (case / 'resources.json').write_text(json.dumps(row, indent=2))
        results.append(row)
        print(row['LUT1_4'], 'LUT,', row['FF'], 'FF,', row['BSRAM'],
              'BSRAM,', row['DSP'], 'DSP  ', case.name, flush=True)
    (out / 'summary.json').write_text(json.dumps(results, indent=2))
    print(out)


if __name__ == '__main__':
    main()
