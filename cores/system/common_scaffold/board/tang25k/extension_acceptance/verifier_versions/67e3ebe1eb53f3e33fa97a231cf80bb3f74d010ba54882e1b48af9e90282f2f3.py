"""Program a frozen extension fixture and compare exact UART bytes, three times.

Functional FPGA fixture evidence only; no physical external-sensor or hold
timing signoff. Hardware must be exclusively owned by this process.
"""
import argparse
import datetime
import hashlib
import json
import re
import subprocess
import sys
import time
from pathlib import Path
import serial

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
sys.path.insert(0, str(ROOT/'cores/signal_processing/dsp_isp_library/board/tang25k'))
import device_flow


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('summary', type=Path)
    parser.add_argument('expected', type=Path)
    parser.add_argument('--port', default='COM44')
    parser.add_argument('--route-status', type=Path)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--periodic-frame', action='store_true',
                        help='Accept one or more complete exact repeated frames (periodic UART fixtures only)')
    parser.add_argument('--repetitions', type=int, default=3, choices=range(1, 4))
    args = parser.parse_args()
    summary_path = args.summary.resolve()
    summary = json.loads(summary_path.read_text(encoding='utf-8'))
    route_inputs = {}
    if args.route_status:
        sys.path.insert(0, str(HERE.parent))
        import resume_candidate_route_official as route
        state_path = args.route_status.resolve()
        state = json.loads(state_path.read_text(encoding='utf-8'))
        candidate = state_path.parent
        if candidate != summary_path.parent:
            raise RuntimeError('route and summary directory mismatch')
        current = route.verify_simulation_gate(candidate)
        for key in ('source_sha256_verified', 'freeze_files_sha256_verified', 'build_status_sha256'):
            if current.get(key) != state['simulation_provenance'].get(key):
                raise RuntimeError('simulation source changed since routing')
        report = state['route_report']
        names = state['artifacts']
        route_log = route.contained_file(candidate, names['router_log'])
        actual = route.parse_route_report(route_log.read_text(encoding='utf-8'), state['route_returncode'])
        if actual != report:
            raise RuntimeError('route report no longer matches actual log')
        required = ('route_process','route_complete','lut4_device_gate','dff_device_gate',
                    'bsram_device_gate','mult12_device_gate','lut_15k','dsp_4','timing_50mhz')
        if any(report['gates'].get(k) is not True for k in required):
            raise RuntimeError('route/setup/resource gate failed')
        if any(not value for key,value in report['gates'].items() if key not in {'hold','hold_model_qualification'}):
            raise RuntimeError('additional route gate failed')
        if report['hold_violation_lines'] or any(v < 0 for v in report['hold_slacks_ns']):
            raise RuntimeError('reported hold violation blocks functional test')
        for path, expected_sha in (
                (candidate/'top25k.json', state['input_top25k_sha256']),
                (candidate/names['cst'], state['derived_cst_sha256']),
                (Path(state['chipdb']), state['chipdb_sha256'])):
            if sha(path) != expected_sha:
                raise RuntimeError('routing input hash changed: '+str(path))
            route_inputs[path] = expected_sha
        routed = route.contained_file(candidate, names['pnr'])
        route_inputs.update({routed:sha(routed), route_log:sha(route_log), state_path:sha(state_path)})
        image = candidate/('functional_extension_'+state['attempt']+'.fs')
        receipt = image.with_suffix('.pack.json')
        if image.exists():
            previous = json.loads(receipt.read_text(encoding='utf-8'))
            if previous['routed_sha256'] != sha(routed) or previous['bitstream_sha256'] != sha(image):
                raise RuntimeError('existing image provenance mismatch')
        else:
            _, packer, provenance = route.validate_official_runtime()
            command = [provenance['baseline_python311'], str(packer), '-d', device_flow.FAMILY,
                       '--sspi_as_gpio', '-o', image.name, routed.name]
            with image.with_suffix('.pack.log').open('x',encoding='utf-8') as log:
                subprocess.run(command, cwd=candidate, env=route.pack_environment(route.OFFICIAL_RUNTIME),
                               stdout=log, stderr=subprocess.STDOUT, timeout=900, check=True)
            receipt.write_text(json.dumps(dict(routed_sha256=sha(routed), bitstream_sha256=sha(image),
                runtime_provenance=provenance, scope='functional test only, hold unproven'),indent=2)+'\n',encoding='utf-8')
        route_inputs[receipt] = sha(receipt)
    else:
        if summary['status'] != 'BUILD_PASS_NOT_BOARD' or not summary['gates'] or not all(summary['gates'].values()):
            raise RuntimeError('build/resource/setup gate failed')
        if summary['synth_lut'] > 15000 or summary['synth_dsp'] > 4:
            raise RuntimeError('isolated resource ceiling exceeded')
        if summary['util']['lut4'] > 15000 or summary['util']['mult12'] > 4:
            raise RuntimeError('actual routed resource ceiling exceeded')
        sys.path.insert(0, str(HERE.parent))
        import resume_candidate_route_official as route
        route_log = summary_path.parent/'nextpnr_25k.log'
        report = route.parse_route_report(route_log.read_text(encoding='utf-8'), 0)
        if report['hold_violation_lines'] or any(v < 0 for v in report['hold_slacks_ns']):
            raise RuntimeError('reported hold violation blocks functional test')
        route_inputs[route_log] = sha(route_log)
        image = (summary_path.parent/summary['bitstream']).resolve()
        if not image.is_relative_to(summary_path.parent) or sha(image) != summary['bitstream_sha256']:
            raise RuntimeError('bitstream provenance mismatch')
    expected = args.expected.resolve().read_bytes()
    if not expected or len(expected) > 196608:
        raise RuntimeError('invalid UART fixture size')
    frozen = {summary_path: sha(summary_path), image: sha(image),
              args.expected.resolve(): sha(args.expected.resolve())}
    frozen.update(route_inputs)
    manifest_path = args.manifest.resolve() if args.manifest else summary_path.parent/'build_input_sha256.json'
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if manifest.get('status') != 'PASS' or not manifest.get('files'):
        raise RuntimeError('build input stability not proven')
    if str(args.expected.resolve()) not in manifest['files']:
        raise RuntimeError('expected UART fixture missing from frozen manifest')
    for name, digest in manifest['files'].items():
        source = Path(name)
        if not source.is_absolute() or not source.is_file() or sha(source) != digest:
            raise RuntimeError('build source provenance mismatch: '+name)
        frozen[source] = digest
    frozen[manifest_path] = sha(manifest_path)
    if args.prepare_only:
        print('FUNCTIONAL_IMAGE_READY_HOLD_UNPROVEN '+str(image))
        return
    loader = ROOT/'tools/oss-cad-suite/oss-cad-suite/bin/openFPGALoader.exe'
    env = device_flow.tool_env()
    stamp = datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    record = summary_path.parent/f'board_validation_{stamp}.json'
    result = dict(status='RUNNING', scope='FPGA internal fixture exact UART output consistency',
                  timing_signoff='HOLD_UNPROVEN', physical_external_sensor_tested=False,
                  bitstream_sha256=sha(image), expected_sha256=hashlib.sha256(expected).hexdigest(),
                  expected_bytes=len(expected), summary_sha256=sha(summary_path),
                  build_input_manifest_sha256=sha(manifest_path), source_files_checked=len(manifest['files']),
                  verifier_sha256=sha(Path(__file__)), periodic_frame=args.periodic_frame, runs=[])
    try:
        with serial.Serial(args.port, 115200, timeout=.2) as port:
            for index in range(args.repetitions):
                if any(sha(path) != digest for path, digest in frozen.items()):
                    raise RuntimeError('input changed during validation')
                detect = subprocess.run([str(loader), '-b', 'tangprimer25k', '--detect'],
                                        env=env, capture_output=True, text=True, timeout=15)
                detection = dict(returncode=detect.returncode, stdout=detect.stdout, stderr=detect.stderr)
                if detect.returncode or not re.search(r'(?i)idcode\s+0x0*1281b\b', detect.stdout+detect.stderr):
                    result['jtag_detection_failure'] = detection
                    raise RuntimeError('JTAG device detection failed')
                port.reset_input_buffer()
                loaded = subprocess.run([str(loader), '-b', 'tangprimer25k', str(image)],
                                        env=env, capture_output=True, text=True, timeout=45)
                raw = bytearray()
                deadline = time.monotonic()+25
                while len(raw) < len(expected) and time.monotonic() < deadline:
                    raw.extend(port.read(min(4096, len(expected)-len(raw))))
                raw.extend(port.read(64))
                exact = bytes(raw) == expected
                if args.periodic_frame:
                    exact = len(raw) >= len(expected) and len(raw) % len(expected) == 0 and bytes(raw) == expected * (len(raw)//len(expected))
                passed = loaded.returncode == 0 and exact
                result['runs'].append(dict(index=index, status='PASS' if passed else 'FAIL',
                    detection=detection, programmer_returncode=loaded.returncode,
                    stdout=loaded.stdout, stderr=loaded.stderr, uart_hex=raw.hex(),
                    uart_sha256=hashlib.sha256(raw).hexdigest(), received_bytes=len(raw)))
                print(f'BOARD {index+1}/{args.repetitions} '+('PASS' if passed else 'FAIL'), flush=True)
                if not passed:
                    raise RuntimeError('programming or exact UART mismatch')
        if any(sha(path) != digest for path, digest in frozen.items()):
            raise RuntimeError('input changed during final capture')
        result['status'] = 'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
    except Exception as error:
        result['status'] = 'FAIL'
        result['error'] = str(error)
        raise
    finally:
        result['completed_at'] = datetime.datetime.now().astimezone().isoformat()
        record.write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print('REPORT '+str(record), flush=True)


if __name__ == '__main__':
    main()
