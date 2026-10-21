"""Build narrow 25K selftest top, no automatic board download."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/storage/buffer_dma'


def main():
    sources = sorted((P / 'rtl').glob('*.v')) + [
        ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v',
        ROOT / 'cores/system/stream_bus_library/board/sys_uart.v',
        ROOT / 'cores/system/ip_test_shell/rtl/uart_csr_transport.v', P / 'examples/25k/buffer_dma_top.v']
    cst = P / 'examples/25k/buffer_dma.cst'
    out = ROOT / 'artifacts/buffer_dma_25k' / datetime.now(timezone.utc).strftime('board_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'target': 'GW5A-LV25MG121NES', 'clock_mhz': 50,
        'board_downloaded': False, 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [cst, Path(__file__).resolve()]}}
    def run(name, command):
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(name + ' failed: ' + str(out / (name + '.log')))
    try:
        rel = lambda p: p.relative_to(ROOT).as_posix()
        script = 'read_verilog ' + ' '.join(map(rel, sources)) + '; synth_gowin -family gw5a -top buffer_dma_top -json ' + rel(out / 'design.json') + '; stat'
        (out / 'synth.ys').write_text(script + '\n')
        print('Evidence=' + str(out), flush=True)
        run('synthesis', ['yosys', '-Q', '-p', script])
        cells = {}
        for cell in json.loads((out / 'design.json').read_text())['modules']['buffer_dma_top']['cells'].values():
            cells[cell['type']] = cells.get(cell['type'], 0) + 1
        report['synthesis_cells'] = cells
        print('Synthesis PASS; routing', flush=True)
        run('pnr', ['nextpnr-himbaechel', '--json', str(out / 'design.json'), '--write', str(out / 'routed.json'),
            '--device', 'GW5A-LV25MG121NES', '--freq', '50', '--report', str(out / 'pnr_report.json'),
            '--vopt', 'family=GW5A-25A', '--vopt', 'cst=' + str(cst), '--vopt', 'sspi_as_gpio'])
        oss = Path(os.environ['OSS_CAD_PYTHON']).parent.parent / 'bin'
        run('pack', [os.environ['OSS_CAD_PYTHON'], str(oss / 'gowin_pack-script.py'), '-d', 'GW5A-25A',
            '--sspi_as_gpio', '-o', str(out / 'buffer_dma.fs'), str(out / 'routed.json')])
        report['bitstream_sha256'] = hashlib.sha256((out / 'buffer_dma.fs').read_bytes()).hexdigest()
        report['pnr_report'] = json.loads((out / 'pnr_report.json').read_text())
        report['status'] = 'PASS'
        print('Route/pack PASS', flush=True)
    except Exception as exc:
        report.update(status='FAIL', reason=str(exc))
        raise
    finally:
        (out / 'summary.json').write_text(json.dumps(report, indent=2) + '\n')
        print('Evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
