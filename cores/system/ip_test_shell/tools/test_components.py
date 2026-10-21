"""Run isolated debug and CSR regressions, retaining source-bound evidence."""
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'


def main():
    out = ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('components_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'tests': [], 'sources': {}}
    try:
        for name in ('logic_probe8', 'test_shell_csr', 'axil_csr_bridge', 'uart_csr_transport', 'uart_diagnostic_top', 'csr_capture_replay'):
            sources = [P / 'rtl' / (name + '.v'), P / 'tb' / ('tb_' + name + '.v')]
            if name == 'axil_csr_bridge':
                sources.append(P / 'rtl/test_shell_csr.v')
            if name == 'csr_capture_replay':
                sources.append(ROOT / 'cores/system/stream_bus_library/rtl/sys_capture_replay.v')
            if name == 'uart_csr_transport':
                sources = sorted((P / 'rtl').glob('*.v')) + [P / 'tb/tb_uart_csr_transport.v']
                sources += [ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
                            for n in ('frame_switch4', 'width_converter', 'packet_async_fifo', 'capture_replay')]
            if name == 'uart_diagnostic_top':
                sources = [P / 'examples/25k/uart_diagnostic_top.v', P / 'tb/tb_uart_diagnostic_top.v',
                           ROOT / 'cores/system/stream_bus_library/board/sys_uart.v']
            report['sources'].update({p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources})
            cmd = ['iverilog', '-g2012', '-s', 'tb_' + name, '-o', str(out / (name + '.vvp'))] + list(map(str, sources))
            build = subprocess.run(cmd, capture_output=True, text=True)
            (out / (name + '_compile.log')).write_text(build.stdout + build.stderr)
            if build.returncode:
                raise RuntimeError(build.stderr)
            run = subprocess.run(['vvp', str(out / (name + '.vvp'))], capture_output=True, text=True, timeout=60)
            (out / (name + '_run.log')).write_text(run.stdout + run.stderr)
            if run.returncode or 'PASS' not in run.stdout:
                raise RuntimeError(run.stdout + run.stderr)
            report['tests'].append({'name': name, 'status': 'PASS', 'verdict': run.stdout.splitlines()[0]})
            print(run.stdout.splitlines()[0])
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
