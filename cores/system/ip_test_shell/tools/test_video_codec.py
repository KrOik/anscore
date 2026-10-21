"""Full-size RGB line-packet contract regression with immutable evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import re

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'


def main():
    sources = [P / 'rtl/video_line_packet_codec.v', P / 'tb/tb_video_line_packet_codec.v']
    sources += [P / 'rtl/stream_width_adapter.v', P / 'rtl/stream_fabric4.v']
    sources += [ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
                for n in ('width_converter', 'frame_switch4', 'packet_async_fifo')]
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('video_codec_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        report['paths'] = []
        for composed, mode in enumerate(('codec', 'packet_fabric')):
            exe = out / (mode + '.vvp')
            build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_video_line_packet_codec',
                '-P', f'tb_video_line_packet_codec.THROUGH_FABRIC={composed}',
                '-o', str(exe)] + list(map(str, sources)), capture_output=True, text=True)
            (out / (mode + '_compile.log')).write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=180)
            (out / (mode + '_run.log')).write_text(run.stdout + run.stderr)
            verdict = 'PASS video composed fabric' if composed else 'PASS video codec II1=128'
            if run.returncode or verdict not in run.stdout:
                raise RuntimeError(run.stdout + run.stderr)
            counts = re.search(r'pixels=(\d+) line_packets=(\d+) stalls=(\d+)', run.stdout)
            if not counts or tuple(map(int, counts.groups()[:2])) != (384007, 723) or int(counts[3]) == 0:
                raise RuntimeError('full frame/stall coverage missing')
            report['paths'].append({'mode': mode, 'pixels': 384007, 'line_packets': 723,
                'sink_stall_cycles': int(counts[3]), 'status': 'PASS'})
            print(run.stdout, end='', flush=True)
        report.update(status='PASS', legal_full_frame_pixels_per_path=384007, line_packets_per_path=723,
            frames=[[1, 1], [3, 2], [320, 240], [640, 480]],
            continuous_pixels_at_II1=128,
            checks=['complete data/SOF/EOL/frame_id', 'random backpressure stability',
                    'frame-boundary config latching', 'missing/overlapping SOF',
                    'early/missing EOL', 'zero width', 'invalid keep', 'changing packet metadata'])
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
