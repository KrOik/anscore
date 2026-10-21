"""Build actual GW5A-25 UART/CSR test shell; source/bitstream-bound evidence."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import argparse
import re

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/system/ip_test_shell'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--resume-pack', type=Path)
    ap.add_argument('--diagnostic', action='store_true')
    args = ap.parse_args()
    out = args.resume_pack.resolve() if args.resume_pack else ROOT / 'artifacts/ip_test_shell_25k' / datetime.now(timezone.utc).strftime('board_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True, exist_ok=bool(args.resume_pack))
    top = 'uart_diagnostic_top' if args.diagnostic else 'test_shell_top'
    sources = sorted((P / 'rtl').glob('*.v')) + [P / 'examples/25k' / (top + '.v'),
               ROOT / 'cores/system/stream_bus_library/board/sys_uart.v']
    sources += [ROOT / 'cores/system/stream_bus_library/rtl' / ('sys_' + n + '.v')
                for n in ('frame_switch4', 'width_converter', 'packet_async_fifo', 'capture_replay')]
    cst = P / 'examples/25k/test_shell.cst'
    report = {'status': 'IN_PROGRESS', 'top': top, 'target': 'GW5A-LV25MG121NES', 'requested_clock_mhz': 50,
              'sources': {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [cst]}}
    report['probe_pins'] = [pin for _, pin in sorted(re.findall(r'IO_LOC "probe_out\[(\d)\]" (\w+);', cst.read_text()))]
    def run(name, cmd):
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(cmd, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(name + ' failed; see ' + str(out / (name + '.log')))
    try:
        if args.resume_pack:
            previous = json.loads((out / 'summary.json').read_text())
            if previous['sources'] != report['sources'] or 'pack failed' not in previous.get('reason', ''):
                raise RuntimeError('cannot resume: changed sources or failure was not pack')
            if 'Program finished normally.' not in (out / 'pnr.log').read_text():
                raise RuntimeError('cannot resume: no successful route evidence')
        rel = lambda p: p.relative_to(ROOT).as_posix()
        ys = 'read_verilog ' + ' '.join(rel(p) for p in sources) + '; synth_gowin -family gw5a -top ' + top + ' -json ' + rel(out / 'design.json') + '; stat'
        if not args.resume_pack:
            run('synthesis', ['yosys', '-Q', '-p', ys])
        design = json.loads((out / 'design.json').read_text())
        cells = {}
        for c in design['modules'][top]['cells'].values():
            cells[c['type']] = cells.get(c['type'], 0) + 1
        report['cells'] = cells
        report['lut_plus_alu'] = sum(v for k, v in cells.items() if k.startswith('LUT') or k == 'ALU')
        if report['lut_plus_alu'] > 15000:
            raise RuntimeError('LUT/ALU budget exceeded')
        route_command = ['nextpnr-himbaechel', '--json', str(out / 'design.json'), '--write', str(out / 'routed.json'),
                    '--device', 'GW5A-LV25MG121NES', '--freq', '50', '--vopt', 'family=GW5A-25A',
                    '--vopt', 'cst=' + str(cst), '--vopt', 'sspi_as_gpio']
        if not args.resume_pack:
            run('pnr', route_command)
        oss = Path(os.environ['OSS_CAD_PYTHON']).parent.parent / 'bin'
        run('pack_recovery' if args.resume_pack else 'pack', [os.environ['OSS_CAD_PYTHON'], str(oss / 'gowin_pack-script.py'), '-d', 'GW5A-25A',
                     '--sspi_as_gpio', '-o', str(out / 'test_shell.fs'), str(out / 'routed.json')])
        report['bitstream_sha256'] = hashlib.sha256((out / 'test_shell.fs').read_bytes()).hexdigest()
        report['status'] = 'PASS'
    except Exception as exc:
        report['status'] = 'FAIL'
        report['reason'] = str(exc)
        raise
    finally:
        (out / ('summary_recovery.json' if args.resume_pack else 'summary.json')).write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
