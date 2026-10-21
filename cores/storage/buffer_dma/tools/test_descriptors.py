"""Descriptor ring capacity, full replacement, wrap and synchronous read tests."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = [P / 'rtl/frame_descriptor_ring.v', P / 'tb/tb_frame_descriptor_ring.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('descriptors_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for depth in (2, 4, 8, 32):
            exe = out / f'depth{depth}.vvp'
            cmd = ['iverilog', '-g2012', '-s', 'tb_frame_descriptor_ring', '-P',
                f'tb_frame_descriptor_ring.DEPTH={depth}', '-o', str(exe)] + list(map(str, sources))
            build = subprocess.run(cmd, capture_output=True, text=True)
            (out / f'compile{depth}.log').write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
            (out / f'run{depth}.log').write_text(run.stdout + run.stderr)
            match = re.search(r'PASS descriptor ring DEPTH=(\d+) ordered=(\d+)', run.stdout)
            if run.returncode or not match or int(match[1]) != depth:
                raise RuntimeError(run.stdout + run.stderr)
            report['cases'].append({'depth': depth, 'ordered_descriptors': int(match[2]), 'status': 'PASS'})
            print(run.stdout.splitlines()[0])
        report['status'] = 'PASS'
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
