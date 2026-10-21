"""Isolated synthesis report for scale_poly6_stream (yosys synth_gowin).

Runs DSP-mapped and all-LUT variants for MAX_W=1920 and prints the cell
summary. Usage:
    python cores/signal_processing/dsp_isp_library/isp/scale/synth_scale.py [--output DIR]
"""
import argparse, datetime, os, pathlib, shutil, subprocess, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[3]


def run(cad, out, name, opts):
    env = dict(os.environ)
    env['PATH'] = str(cad / 'bin') + os.pathsep + str(cad / 'lib') + \
        os.pathsep + env['PATH']
    ys = f"read_verilog -I {HERE} {HERE/'scale_poly6_stream.v'}; " \
         f"synth_gowin -top scale_poly6_stream {opts}"
    yo = str(cad / 'bin' / 'yosys.exe')
    if not pathlib.Path(yo).exists():
        yo = shutil.which('yosys', path=env['PATH'])
    p = subprocess.run([yo, '-p', ys],
                       capture_output=True, text=True, cwd=out, timeout=900)
    log = p.stdout + p.stderr
    if p.returncode != 0 or not log.strip():
        print(f'{name}: rc={p.returncode} log_len={len(log)}')
    (out / f'synth_{name}.log').write_text(log)
    # print the final statistics block (the one right before CHECK/end)
    tail = log.split('End of script')[0]
    idx = tail.rfind('Number of cells')
    if idx < 0:
        idx = tail.rfind('cells')
    seg = tail[max(0, idx - 500):] if idx >= 0 else tail[-2000:]
    print(f'=== {name} ===')
    print(seg[:1800])
    return p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--output', default=None)
    a = ap.parse_args()
    out = pathlib.Path(a.output) if a.output else \
        HERE / 'evidence' / ('synth_' +
            datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir(parents=True, exist_ok=True)
    cad = ROOT / 'tools' / 'oss-cad-suite' / 'oss-cad-suite'
    rc = 0
    rc |= run(cad, out, 'dsp', '-noalu')
    rc |= run(cad, out, 'nodsp', '-noalu -nodsp')
    return rc


if __name__ == '__main__':
    sys.exit(main())
