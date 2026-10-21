"""Full-size streaming BLC, exact integer oracle independent of RTL control."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    sources = [P / 'rtl/raw_black_level_stream.v', P / 'tb/tb_raw_black_level_stream.v', P / 'tb/tb_blc_cadence.v']
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('blc_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for bits in (8, 10, 12):
            exe = out / f'raw{bits}.vvp'
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_raw_black_level_stream', '-P',
                f'tb_raw_black_level_stream.RAW_BITS={bits}', '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
            (out / f'compile{bits}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            pixels = out / f'raw{bits}.bin'
            run = subprocess.run(['vvp', str(exe), '+output=' + str(pixels)], capture_output=True, text=True, timeout=60)
            (out / f'run{bits}.log').write_text(run.stdout + run.stderr)
            match = re.search(r'PASS streaming BLC RAW_BITS=(\d+) pixels=(\d+) low=(\d+) high=(\d+)', run.stdout)
            if run.returncode or not match or int(match[1]) != bits:
                raise RuntimeError(run.stdout + run.stderr)
            raw = pixels.read_bytes()
            expected_records = []
            maximum = (1 << bits) - 1
            low = high = 0
            for frame in range(8):
                width = 320 if frame == 6 else 640 if frame == 7 else 1 if frame == 4 else 5
                height = 240 if frame == 6 else 480 if frame == 7 else 3
                target = 0 if frame % 3 == 0 else maximum // 2
                pattern = frame % 4
                for y in range(height):
                    for x in range(width):
                        pixel = (x * 37 + y * 53 + frame * 97) & maximum
                        plane = ((y % 2) ^ (pattern >> 1)) * 2 + ((x % 2) ^ (pattern & 1))
                        level = (maximum // 4 + plane * 17 + frame * 11) & maximum
                        corrected = pixel - level + target
                        if frame != 5:
                            low += corrected < 0
                            high += corrected > maximum
                            pixel = min(maximum, max(0, corrected))
                        expected_records.append((pixel, frame, int(x == 0 and y == 0) | (int(x == width - 1) << 1)))
            actual = list(struct.iter_unpack('<HHB', raw))
            if actual != expected_records or int(match[2]) != len(actual) or (int(match[3]), int(match[4])) != (low, high):
                mismatch = next((i for i, pair in enumerate(zip(actual, expected_records)) if pair[0] != pair[1]), None)
                raise RuntimeError(f'golden pixels/flags/clip counts mismatch at {mismatch}')
            report['cases'].append({'raw_bits': bits, 'pixels': len(actual), 'low_clips': low,
                'high_clips': high, 'output_sha256': hashlib.sha256(raw).hexdigest(), 'status': 'PASS'})
            print(match[0])
        cadence_exe = out / 'cadence.vvp'
        cadence_build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_blc_cadence', '-o', str(cadence_exe)] + list(map(str, sources)), capture_output=True, text=True)
        (out / 'cadence_compile.log').write_text(cadence_build.stdout + cadence_build.stderr)
        if cadence_build.returncode:
            raise RuntimeError(cadence_build.stderr)
        cadence = subprocess.run(['vvp', str(cadence_exe)], capture_output=True, text=True, timeout=30)
        (out / 'cadence_run.log').write_text(cadence.stdout + cadence.stderr)
        if cadence.returncode or 'PASS BLC continuous128 pixels II1' not in cadence.stdout:
            raise RuntimeError(cadence.stdout + cadence.stderr)
        report.update(status='PASS', isolated_ii=1, stalled_reset='PASS')
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
