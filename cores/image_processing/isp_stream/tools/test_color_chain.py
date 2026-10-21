"""Independent exact AWB/CCM/LUT oracle and frame metadata comparison."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/rgb_color_chain.v'] + [ROOT / 'cores/system/common_scaffold/image/isp' / name
        for name in ('img_isp_awb_gain.v', 'img_isp_ccm.v', 'img_isp_gamma_lut.v')] + [P / 'tb/tb_rgb_color_chain.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('color_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        exe = out / 'test.vvp'
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_rgb_color_chain', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        pixels = out / 'rgb.bin'
        run = subprocess.run(['vvp', str(exe), '+output=' + str(pixels)], capture_output=True, text=True, timeout=90)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        match = re.search(r'PASS color chain pixels=(\d+) isolatedII=1', run.stdout)
        if run.returncode or not match:
            raise RuntimeError(run.stdout + run.stderr)
        golden = bytearray()
        clamp = lambda x: min(255, max(0, x))
        for f in range(6):
            width = 320 if f == 4 else 640 if f == 5 else 16 if f == 0 else 5
            height = 240 if f == 4 else 480 if f == 5 else 8 if f == 0 else 3
            gains = (256, 256, 256) if f == 2 else (256 + f*16, 256 - f*8, 256 + f*12)
            matrix = ((1024, 128, -64), (-128, 1024, 128), (64, -128, 1024)) if f % 2 else ((1024, 0, 0), (0, 1024, 0), (0, 0, 1024))
            bias = (-5, 3, 7) if f % 2 else (0, 0, 0)
            for y in range(height):
                for x in range(width):
                    raw = ((x*19+y*31+f*43)&255, (x*37+y*17+f*11)&255, (x*7+y*53+f*29)&255)
                    gained = [clamp((pixel * gain + 128) // 256) for pixel, gain in zip(raw, gains)]
                    r, g, b = [clamp((sum(a*v for a, v in zip(row, gained)) + 512) // 1024 + offset) for row, offset in zip(matrix, bias)]
                    if f % 2:
                        r, g, b = (r*r+127)//255, 255-g, (b+f*7)&255
                    flags = int(x == 0 and y == 0) | (int(x == width-1) << 1) | (int(x == width-1 and y == height-1) << 2)
                    golden += bytes((b, g, r, f+100, 0, flags))
        actual = pixels.read_bytes()
        if actual != golden or len(actual) // 6 != int(match[1]):
            mismatch = next((i for i, pair in enumerate(zip(actual, golden)) if pair[0] != pair[1]), None)
            raise RuntimeError(f'color golden mismatch at byte {mismatch}')
        report.update(status='PASS', pixels=len(actual)//6, frames=6, isolated_ii=1,
            output_sha256=hashlib.sha256(actual).hexdigest())
        print(match[0] + '; independent golden PASS')
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
