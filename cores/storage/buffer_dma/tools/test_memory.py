"""Independent word/CRC golden for two-writer/two-reader BRAM contention."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import zlib

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [P / 'tb/tb_mem_port.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('memory_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}}
    try:
        build = subprocess.run(['iverilog', '-g2012', '-s', 'tb_mem_port', '-o', str(out / 'test.vvp')]
            + list(map(str, sources)), capture_output=True, text=True)
        (out / 'compile.log').write_text(build.stdout + build.stderr)
        if build.returncode:
            raise RuntimeError(build.stderr)
        run = subprocess.run(['vvp', str(out / 'test.vvp')], capture_output=True, text=True, timeout=60)
        (out / 'run.log').write_text(run.stdout + run.stderr)
        if run.returncode or 'PASS byte masks' not in run.stdout:
            raise RuntimeError(run.stdout + run.stderr)
        rows = re.findall(r'READ source=(\d+) frame=(\d+) offset=(\d+) data=([0-9a-f]+)', run.stdout)
        if len(rows) != 1024:
            raise RuntimeError('missing memory readback')
        report['streams'] = []
        for source in range(2):
            observed = [(int(f), int(i), int(d, 16)) for s, f, i, d in rows if int(s) == source]
            golden = [(f, i, (0x512a309b ^ (source * 0x17351) ^
                ((f * 0x103397 + i * 0x71a3) & 0xffffffff))) for f in range(32) for i in range(16)]
            if observed != golden:
                raise RuntimeError('independent memory frame golden mismatch')
            payload = b''.join(d.to_bytes(4, 'little') for _, _, d in observed)
            (out / f'stream{source}.bin').write_bytes(payload)
            report['streams'].append({'source': source, 'blocks': 32, 'words': 512,
                                      'crc32': f'{zlib.crc32(payload):08x}', 'status': 'PASS'})
        cycles = int(re.search(r'full words,cycles=(\d+)', run.stdout)[1])
        report.update(status='PASS', transactions=2048, exchange_cycles=cycles,
            aggregate_bytes_per_simulated_cycle=8192 / cycles,
            frame_ownership='testbench only; RTL frame scheduler not implemented',
            physical_board=False)
        print('\n'.join(line for line in run.stdout.splitlines() if line.startswith('PASS')))
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out))


if __name__ == '__main__':
    main()
