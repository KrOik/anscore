"""Isolated Gowin synthesis for the asyncfifo cores; no timing/P&R/board claim.

This OSS-CAD-Suite yosys build's synth_gowin does not accept -family.
Run:  python synth_asyncfifo.py [--out DIR]
"""
import argparse, datetime, hashlib, json, os, pathlib, shutil, subprocess
from collections import Counter

ROOT = pathlib.Path(__file__).resolve().parent
REPO = ROOT.parents[3]
CAD = REPO / 'tools/oss-cad-suite/oss-cad-suite'


def tools(name):
    local = CAD / 'bin' / f'{name}.exe'
    return str(local) if local.exists() else shutil.which(name) or name


def env():
    e = os.environ.copy()
    e['PATH'] = str(CAD / 'bin') + os.pathsep + str(CAD / 'lib') + os.pathsep + \
        e['PATH']
    return e


def synth(out, module, params):
    tag = module + ''.join(f'_{k}{v}' for k, v in params.items())
    work = out / tag
    work.mkdir()
    src = ROOT / 'rtl' / f'{module}.sv'
    chp = ''.join(f'chparam -set {k} {v} {module}\n' for k, v in params.items())
    script = (f'read_verilog -sv "{src.as_posix()}"\n{chp}'
              f'synth_gowin -top {module} -json mapped.json\nstat\n')
    (work / 'synth.ys').write_text(script)
    p = subprocess.run([tools('yosys'), '-s', 'synth.ys'], cwd=work, env=env(),
                       text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    (work / 'synth.log').write_text('$ ' + ' '.join(
        [tools('yosys'), '-s', 'synth.ys']) + '\n' + p.stdout)
    assert p.returncode == 0, p.stdout[-4000:]
    net = json.loads((work / 'mapped.json').read_text())
    cells = Counter(c['type'] for c in net['modules'][module]['cells'].values())
    result = dict(module=module, parameters=params, cells=dict(cells),
                  source_sha256=hashlib.sha256(src.read_bytes()).hexdigest(),
                  status='SYNTHESIS PASS',
                  scope='core plus default synthesis IO pads; not P&R',
                  timing='NOT RUN', board='NOT RUN')
    print(tag, dict(cells))
    return result


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', type=pathlib.Path)
    a = ap.parse_args()
    out = a.out or ROOT / 'evidence' / ('synth_' + datetime.datetime.now().
                                      strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=False)
    results = [
        synth(out, 'async_stream_fifo', dict(WIDTH=16, DEPTH=16)),
        synth(out, 'async_stream_fifo', dict(WIDTH=16, DEPTH=64)),
        synth(out, 'async_stream_fifo', dict(WIDTH=32, DEPTH=4)),
        synth(out, 'stream_cdc_handshake', dict(WIDTH=16)),
    ]
    (out / 'summary.json').write_text(json.dumps(results, indent=2))
    print(out)


if __name__ == '__main__':
    main()
