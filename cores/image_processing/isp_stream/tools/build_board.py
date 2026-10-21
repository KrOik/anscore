"""Build narrow 25K selftest top, no automatic board download."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil
import argparse

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
P = ROOT / 'cores/image_processing/isp_stream'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nowidelut',action='store_true',help='map to LUT4 only; avoid dedicated wide-LUT placement groups')
    args=parser.parse_args()
    sources = sorted((P / 'rtl').glob('*.v')) + [ROOT / 'cores/system/common_scaffold/image' / name for name in (
        'pipelines/img_bayer_window_frontend_draft.v','window/img_window3x3_valid_draft.v',
        'isp/img_isp_bayer_interpolate.v','isp/img_isp_awb_gain.v','isp/img_isp_ccm.v','isp/img_isp_gamma_lut.v','isp/img_isp_awb_stats.v',
        'filters/rtl/img_edge_sobel3x3.v','filters/rtl/img_edge_gradient3x3.v','filters/rtl/img_filter_stream_register.v')] + [
        ROOT / 'cores/system/stream_bus_library/rtl/sys_atomic_config.v',
        ROOT / 'cores/system/stream_bus_library/rtl/sys_register_snapshot.v',
        ROOT / 'cores/storage/buffer_dma/rtl/frame_stream_monitor.v',
        ROOT / 'cores/system/ip_test_shell/rtl/logic_probe8.v',
        ROOT / 'cores/system/stream_bus_library/board/sys_uart.v',
        ROOT / 'cores/system/ip_test_shell/rtl/uart_csr_transport.v', P / 'examples/25k/isp_top.v']
    cst = P / 'examples/25k/isp.cst'
    out = ROOT / 'artifacts/isp_stream_25k' / datetime.now(timezone.utc).strftime('board_%Y%m%dT%H%M%S%fZ')
    out.mkdir(parents=True)
    report = {'status': 'IN_PROGRESS', 'target': 'GW5A-LV25MG121NES', 'clock_mhz': 50,
        'board_downloaded': False, 'synthesis_options': ['-nowidelut'] if args.nowidelut else [], 'sources': {p.relative_to(ROOT).as_posix():
        hashlib.sha256(p.read_bytes()).hexdigest() for p in sources + [cst, Path(__file__).resolve()]}}
    # Build from a frozen copy, so ongoing RTL development cannot alter inputs
    # between synthesis, routing and packing. Keep original names in the report.
    snapshot = out / 'source_snapshot'
    for source in sources + [cst, Path(__file__).resolve()]:
        name = source.relative_to(ROOT)
        destination = snapshot / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        if hashlib.sha256(destination.read_bytes()).hexdigest() != report['sources'][name.as_posix()]:
            raise RuntimeError('source changed while freezing build inputs: ' + str(name))
    (out / 'source_snapshot_manifest.json').write_text(json.dumps(report['sources'], indent=2) + '\n')
    report['source_snapshot'] = 'source_snapshot'
    frozen_sources = [snapshot / source.relative_to(ROOT) for source in sources]
    frozen_cst = snapshot / cst.relative_to(ROOT)
    def run(name, command):
        with (out / (name + '.log')).open('w') as log:
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise RuntimeError(name + ' failed: ' + str(out / (name + '.log')))
    try:
        rel = lambda p: p.relative_to(ROOT).as_posix()
        script = 'read_verilog ' + ' '.join(map(rel, frozen_sources)) + '; synth_gowin -family gw5a ' + ('-nowidelut ' if args.nowidelut else '') + '-top isp_top -json ' + rel(out / 'design.json') + '; stat'
        (out / 'synth.ys').write_text(script + '\n')
        print('Evidence=' + str(out), flush=True)
        run('synthesis', ['yosys', '-Q', '-p', script])
        cells = {}
        for cell in json.loads((out / 'design.json').read_text())['modules']['isp_top']['cells'].values():
            cells[cell['type']] = cells.get(cell['type'], 0) + 1
        report['synthesis_cells'] = cells
        print('Synthesis PASS; routing', flush=True)
        run('pnr', ['nextpnr-himbaechel', '--json', str(out / 'design.json'), '--write', str(out / 'routed.json'),
            '--device', 'GW5A-LV25MG121NES', '--freq', '50', '--report', str(out / 'pnr_report.json'),
            '--vopt', 'family=GW5A-25A', '--vopt', 'cst=' + str(frozen_cst), '--vopt', 'sspi_as_gpio'])
        oss = Path(os.environ['OSS_CAD_PYTHON']).parent.parent / 'bin'
        run('pack', [os.environ['OSS_CAD_PYTHON'], str(oss / 'gowin_pack-script.py'), '-d', 'GW5A-25A',
            '--sspi_as_gpio', '-o', str(out / 'isp.fs'), str(out / 'routed.json')])
        report['bitstream_sha256'] = hashlib.sha256((out / 'isp.fs').read_bytes()).hexdigest()
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
