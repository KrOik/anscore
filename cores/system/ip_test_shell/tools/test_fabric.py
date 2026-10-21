"""Exercise composed four-source packet fabric at three clock ratios."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'
SOURCES = [P / 'rtl/stream_fabric4.v', P / 'rtl/stream_width_adapter.v',
           P / 'tb/tb_stream_fabric4.v'] + [
    ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
    for n in ('frame_switch4', 'width_converter', 'packet_async_fifo')]
FAULT_TB = P / 'tb/tb_stream_fabric_faults.v'


def main():
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('fabric_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {
        p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES + [FAULT_TB]}, 'cases': []}
    try:
        for index, (s, m) in enumerate([(5, 7), (7, 5), (5, 11)]):
            d = out / str(index)
            d.mkdir()
            cmd = ['iverilog', '-g2012', '-s', 'tb_stream_fabric4', '-o', str(d / 'test.vvp'),
                   f'-Ptb_stream_fabric4.S_HALF={s}', f'-Ptb_stream_fabric4.M_HALF={m}',
                   f'-Ptb_stream_fabric4.SEED={831449261 + index}'] + list(map(str, SOURCES))
            result = subprocess.run(cmd, capture_output=True, text=True)
            (d / 'compile.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(result.stderr)
            result = subprocess.run(['vvp', str(d / 'test.vvp')], capture_output=True, text=True, timeout=60)
            (d / 'run.log').write_text(result.stdout + result.stderr)
            if result.returncode or 'PASS fabric4' not in result.stdout:
                raise RuntimeError(result.stdout + result.stderr)
            report['cases'].append({'status': 'PASS', 's_half_ns': s, 'm_half_ns': m,
                                    'packets': 256, 'verdict': result.stdout.splitlines()[0]})
            print(result.stdout.splitlines()[0], flush=True)
        for index, (s, m) in enumerate([(5, 7), (7, 5), (5, 11)]):
            d = out / ('faults_' + str(index))
            d.mkdir()
            top = 'tb_stream_fabric_faults'
            cmd = ['iverilog', '-g2012', '-s', top, '-o', str(d / 'test.vvp'),
                   f'-P{top}.S_HALF={s}', f'-P{top}.M_HALF={m}']
            cmd += list(map(str, [p for p in SOURCES if p.name != 'tb_stream_fabric4.v'] + [FAULT_TB]))
            result = subprocess.run(cmd, capture_output=True, text=True)
            (d / 'compile.log').write_text(result.stdout + result.stderr)
            if result.returncode:
                raise RuntimeError(result.stderr)
            result = subprocess.run(['vvp', str(d / 'test.vvp')], capture_output=True, text=True, timeout=60)
            (d / 'run.log').write_text(result.stdout + result.stderr)
            if result.returncode or 'PASS fabric_faults' not in result.stdout:
                raise RuntimeError(result.stdout + result.stderr)
            report['cases'].append({'status': 'PASS', 'kind': 'faults', 's_half_ns': s,
                                    'm_half_ns': m, 'verdict': result.stdout.splitlines()[0]})
            print(result.stdout.splitlines()[0], flush=True)
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
