"""Control CSR and full bit-serial UART simulation, immutable evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [
        ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v',
        ROOT / 'cores/system/stream_bus_library/board/sys_uart.v',
        ROOT / 'cores/system/ip_test_shell/rtl/uart_csr_transport.v',
        P / 'examples/25k/buffer_dma_top.v', P / 'tb/tb_buffer_dma_control.v',
        P / 'tb/tb_buffer_dma_uart.v']
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('control_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [Path(__file__).resolve()]}, 'cases': []}
    try:
        for top, marker in [('tb_buffer_dma_control', 'PASS control CSR routing'),
                            ('tb_buffer_dma_uart', 'PASS board UART serial control')]:
            exe = out / (top + '.vvp')
            build = subprocess.run(['iverilog', '-g2012', '-s', top, '-o', str(exe)] +
                list(map(str, sources)), capture_output=True, text=True)
            (out / (top + '_compile.log')).write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(exe)], capture_output=True, text=True, timeout=30)
            (out / (top + '_run.log')).write_text(run.stdout + run.stderr)
            if run.returncode or marker not in run.stdout:
                raise RuntimeError(run.stdout + run.stderr)
            report['cases'].append({'top': top, 'status': 'PASS'})
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
