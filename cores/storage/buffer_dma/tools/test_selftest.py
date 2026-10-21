"""Independent golden checks for synthesizable on-board stimulus/checker."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v', P / 'tb/tb_buffer_dma_selftest.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('selftest_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        exe = out / 'test.vvp'
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_buffer_dma_selftest', '-o', str(exe)] +
            list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS synthesizable selftest 4 runs' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        completions = re.findall(r'RUN_PASS run=(\d+) seed=([0-9a-f]+) stalls=(\d+) error=(\d+) words=(\d+) cycles=(\d+)', run.stdout)
        if len(completions) != 4:
            raise RuntimeError('missing runs')
        rows = re.findall(r'SELF_READ run=(\d+) sink=(\d+) source=(\d+) frame=(\d+) offset=(\d+) data=([0-9a-f]+)', run.stdout)
        checked = {}
        traces = {}
        required = {(s, f, i) for s in range(2) for f in range(32) for i in range(f % 16 + 1)}
        for run_id, seed, stalls, error, words, cycles in completions:
            rid = int(run_id)
            seen = set()
            trace = []
            mismatches = 0
            for run_number, sink, source, frame, offset, data in rows:
                if int(run_number) != rid:
                    continue
                sink, source, frame, offset = map(int, (sink, source, frame, offset))
                key = (source, frame, offset)
                if key in seen or sink != source ^ (frame & 1):
                    raise RuntimeError('routing/duplicate mismatch')
                seen.add(key)
                expected = (int(seed, 16) ^ (source * 0x17351) ^ (frame * 0x103397 + offset * 0x71a3)) & 0xffffffff
                mismatches += int(int(data, 16) != expected)
                trace.append((sink, source, frame, offset, data))
            if seen != required or int(words) != 544 or mismatches != (1 if rid == 3 else 0) or int(error) != (rid == 3):
                raise RuntimeError('golden/corruption detection mismatch')
            checked[rid] = {'seed': seed, 'stalls': int(stalls), 'words': len(seen),
                'mismatches': mismatches, 'expected_error': bool(int(error)), 'cycles': int(cycles)}
            traces[rid] = trace
        if checked[1]['cycles'] != checked[4]['cycles'] or traces[1] != traces[4]:
            raise RuntimeError('seeded replay not reproducible')
        timeout_exe = out / 'timeout.vvp'
        build_timeout = subprocess.run(['iverilog', '-g2012', '-s', 'tb_buffer_dma_timeout', '-o', str(timeout_exe)] +
            list(map(str, sources)), capture_output=True, text=True)
        (out / 'timeout_compile.log').write_text(build_timeout.stdout + build_timeout.stderr)
        if build_timeout.returncode:
            raise RuntimeError(build_timeout.stderr)
        timeout_run = subprocess.run(['vvp', str(timeout_exe)], capture_output=True, text=True, timeout=30)
        (out / 'timeout_run.log').write_text(timeout_run.stdout + timeout_run.stderr)
        if timeout_run.returncode or 'PASS selftest watchdog stops at 64 cycles' not in timeout_run.stdout:
            raise RuntimeError(timeout_run.stdout + timeout_run.stderr)
        report.update(status='PASS', runs=checked, watchdog='PASS')
        print('PASS selftest golden: 4 runs / 2176 words, exactly one injected mismatch, repeatable restart')
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
