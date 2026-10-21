"""RTL ownership + descriptor queues + actual BRAM, independent frame/CRC golden."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zlib
import argparse

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--shared', action='store_true', help='test shared pool instead of fixed ping-pong')
    args = parser.parse_args()
    sources = sorted((P / 'rtl').glob('*.v')) + [P / 'tb/tb_frame_slots.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('slots_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'FIXED_PINGPONG': not args.shared, 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_frame_slots', '-P',
            'tb_frame_slots.FIXED_PINGPONG=' + str(int(not args.shared)), '-o', str(out / 'test.vvp')]
            + list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(out / 'test.vvp')], capture_output=True, text=True, timeout=60)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS slot allocation-response' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        main_log = run.stdout.split('PASS RTL slot manager')[0]
        publications = [tuple(map(int, row)) for row in re.findall(r'PUBLISH sink=(\d+) source=(\d+) frame=(\d+)', main_log)]
        if len(publications) != 64 or {(s, f) for _, s, f in publications} != {(s, f) for s in range(2) for f in range(32)}:
            raise RuntimeError('missing or duplicated publications')
        if any(d != s ^ (f & 1) for d, s, f in publications):
            raise RuntimeError('publication routing mismatch')
        rows = re.findall(r'SLOT_READ sink=(\d+) source=(\d+) frame=(\d+) offset=(\d+) data=([0-9a-f]+)', main_log)
        if len(rows) != 544:
            raise RuntimeError('missing readback words')
        report['consumers'] = []
        for sink in range(2):
            golden = [(s, f, i, 0x512a309b ^ (s * 0x17351) ^
                ((f * 0x103397 + i * 0x71a3) & 0xffffffff))
                for d, s, f in publications if d == sink for i in range(f % 16 + 1)]
            observed = [(int(s), int(f), int(i), int(data, 16)) for d, s, f, i, data in rows if int(d) == sink]
            if observed != golden:
                raise RuntimeError('independent ownership/order/payload golden mismatch')
            payload = b''.join(data.to_bytes(4, 'little') for _, _, _, data in observed)
            (out / f'consumer{sink}.bin').write_bytes(payload)
            report['consumers'].append({'consumer': sink, 'frames': 32, 'words': len(observed),
                'crc32': f'{zlib.crc32(payload):08x}', 'status': 'PASS'})
        report.update(status='PASS', frame_ownership='RTL frame_slot_manager',
            payload_transfer='testbench mem_port transactions; RTL block mover still pending',
            peak_occupied_slots=4, physical_board=False)
        print('\n'.join(line for line in run.stdout.splitlines() if line.startswith('PASS')))
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
