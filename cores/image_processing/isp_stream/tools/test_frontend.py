"""Exact full-size RAW->BLC->bilinear RGB golden, unchanged canonical kernels."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/raw_black_level_stream.v', P / 'rtl/raw_rgb_frontend.v', P / 'rtl/raw_bayer_mode_stream.v',
        ROOT / 'cores/system/common_scaffold/image/pipelines/img_bayer_window_frontend_draft.v',
        ROOT / 'cores/system/common_scaffold/image/window/img_window3x3_valid_draft.v',
        ROOT / 'cores/system/common_scaffold/image/isp/img_isp_bayer_interpolate.v', P / 'tb/tb_raw_rgb_frontend.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('frontend_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for bits in (8, 10, 12):
            exe = out / f'raw{bits}.vvp'
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_raw_rgb_frontend', '-P',
                f'tb_raw_rgb_frontend.RAW_BITS={bits}', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
            (out / f'compile{bits}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            pixels = out / f'raw{bits}.bin'
            run = subprocess.run(['vvp', str(exe), '+output=' + str(pixels)], capture_output=True, text=True, timeout=90)
            (out / f'run{bits}.log').write_text(run.stdout + run.stderr)
            match = re.search(r'PASS RAW RGB frontend bits=(\d+) pixels=(\d+)', run.stdout)
            if run.returncode or not match or int(match[1]) != bits:
                raise RuntimeError(run.stdout + run.stderr)
            golden = bytearray()
            maximum = (1 << bits) - 1
            for f in range(7):
                width = 320 if f == 4 else 640 if f == 5 else 3 if f == 6 else 5
                height = 240 if f == 4 else 480 if f == 5 else 3 if f == 6 else 5
                pattern = f % 4
                corrected = []
                for y in range(height):
                    row = []
                    for x in range(width):
                        plane = ((y % 2) ^ (pattern >> 1)) * 2 + ((x % 2) ^ (pattern & 1))
                        pixel = ((x * 23 + y * 37 + f * 57) & maximum) - ((plane * 13 + f * 7) & maximum) + maximum // 8
                        row.append(max(0, min(maximum, pixel)))
                    corrected.append(row)
                for y in range(1, height - 1):
                    for x in range(1, width - 1):
                        center = corrected[y][x]
                        h = (corrected[y][x-1] + corrected[y][x+1] + 1) // 2
                        v = (corrected[y-1][x] + corrected[y+1][x] + 1) // 2
                        cross = (corrected[y-1][x] + corrected[y][x-1] + corrected[y][x+1] + corrected[y+1][x] + 2) // 4
                        diag = (corrected[y-1][x-1] + corrected[y-1][x+1] + corrected[y+1][x-1] + corrected[y+1][x+1] + 2) // 4
                        site = ((y & 1) * 2 + (x & 1)) ^ pattern
                        r, g, b = ((center, cross, diag), (h, center, v), (v, center, h), (diag, cross, center))[site]
                        flags = int(x == 1 and y == 1) | (int(x == width-2) << 1) | (int(x == width-2 and y == height-2) << 2)
                        golden += bytes((b >> (bits-8), g >> (bits-8), r >> (bits-8), f, 0, flags))
            actual = pixels.read_bytes()
            if actual != golden or len(actual) // 6 != int(match[2]):
                mismatch = next((i for i, pair in enumerate(zip(actual, golden)) if pair[0] != pair[1]), None)
                raise RuntimeError(f'frontend golden mismatch at byte {mismatch}')
            report['cases'].append({'raw_bits': bits, 'pixels': len(actual)//6,
                'output_sha256': hashlib.sha256(actual).hexdigest(), 'status': 'PASS'})
            print(match[0])
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
