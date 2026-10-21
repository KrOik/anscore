"""Independent 3x3 Sobel golden, center bypass, framing and held-output checks."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/gray_sobel_stream.v', P / 'tb/tb_gray_sobel_stream.v'] + [
        ROOT / 'cores/system/common_scaffold/image' / s for s in (
            'window/img_window3x3_valid_draft.v', 'filters/rtl/img_edge_sobel3x3.v',
            'filters/rtl/img_edge_gradient3x3.v', 'filters/rtl/img_filter_stream_register.v')]
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('sobel_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {str(s.relative_to(ROOT)): hashlib.sha256(s.read_bytes()).hexdigest()
              for s in sources + [Path(__file__).resolve()]}}
    try:
        exe = out / 'test.vvp'
        run = subprocess.run(['iverilog', '-g2012', '-s', 'tb_gray_sobel_stream', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(run.stdout + run.stderr)
        if run.returncode:
            raise RuntimeError(run.stderr)
        run = subprocess.run(['vvp', str(exe), '+output=' + str(out / 'pixels.bin')], capture_output=True, text=True, timeout=180)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS Sobel stream' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        golden = bytearray()
        for f, (w, h) in enumerate(((7, 6), (320, 240), (640, 480), (3, 3))):
            image = [[(x*23+y*37+f*57)&255 for x in range(w)] for y in range(h)]
            for y in range(1, h-1):
                for x in range(1, w-1):
                    gx = sum(image[y+dy][x+1]*k-image[y+dy][x-1]*k for dy, k in ((-1, 1), (0, 2), (1, 1)))
                    gy = sum(image[y+1][x+dx]*k-image[y-1][x+dx]*k for dx, k in ((-1, 1), (0, 2), (1, 1)))
                    value = image[y][x] if f in (1, 3) else min(255, (abs(gx)+abs(gy)) >> 2)
                    flags = int(x==1 and y==1) | (int(x==w-2)<<1) | (int(x==w-2 and y==h-2)<<2)
                    golden += bytes((value, f, 0, flags))
        actual = (out / 'pixels.bin').read_bytes()
        if actual != golden:
            mismatch = next((i for i, (a, b) in enumerate(zip(actual, golden)) if a != b), None)
            raise RuntimeError(f'pixel/metadata mismatch byte={mismatch} lengths={len(actual)}/{len(golden)}')
        report.update(status='PASS', pixels=len(actual)//4, output_sha256=hashlib.sha256(actual).hexdigest())
        print(run.stdout.splitlines()[0])
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2)+'\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
