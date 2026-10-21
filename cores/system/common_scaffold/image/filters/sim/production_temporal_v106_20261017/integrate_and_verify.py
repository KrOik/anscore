"""Read-only staging, or guarded integration, of the frozen v106 temporal IP.

--preflight tests a proposed public-name copy and does NOT claim production PASS.
--apply requires three real SRAM loads; subsequent --verify never rewrites RTL.
No synthesis, routing, programming, serial, or production metadata edits occur.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import importlib.util
import inspect
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = next(p for p in HERE.parents if (p / 'cores/signal_processing/dsp_isp_library/board/tang25k/device_flow.py').is_file())
IMAGE = ROOT / 'cores/system/common_scaffold/image'
PROD = IMAGE / 'filters'
TARGET = PROD / 'rtl/img_filter_temporal_denoise.v'
CAND = ROOT / 'cores/system/common_scaffold/board/tang25k/build/image_temporal_frame_selftest_25k_20261017_v106'
BOARD = CAND.parents[1]
PUBLIC = 'img_filter_temporal_denoise'
PRIVATE = PUBLIC + '_pipe'
EXPECTED = b'TMP106 PASS F=20 I=00CF H=004F O=00CF E=0000 D=543453C2\r\n'
sys.path.insert(0, str(ROOT / 'cores/signal_processing/dsp_isp_library/board/tang25k'))
sys.path.insert(0, str(BOARD))
import device_flow


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'))


def write_json(path, data):
    Path(path).write_text(json.dumps(data, indent=2) + '\n', encoding='utf-8')


def load_module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidate_file(name):
    path = (CAND / name).resolve()
    require(path.is_relative_to(CAND.resolve()) and path.is_file(), 'Invalid candidate path: ' + name)
    return path


def freeze_gate():
    manifest = read_json(CAND / 'FREEZE_MANIFEST.json')
    require(manifest['verification']['result'] == 'PASS', 'Candidate freeze did not pass')
    files = manifest['files_sha256']
    require(files and all(sha(candidate_file(name)) == value for name, value in files.items()),
            'Frozen candidate input changed')
    for required in ('rtl/' + PRIVATE + '.v', 'run_functional.py', 'run_board_sim.py',
                     'generate_vectors.py', 'simulation_summary.json', 'expected_uart.txt',
                     'reference/' + PUBLIC + '_baseline.v'):
        require(required in files, 'Freeze does not cover ' + required)
    require((CAND / 'expected_uart.txt').read_bytes() == EXPECTED, 'Original UART contract changed')
    functional = read_json(CAND / 'functional_summary.json')
    simulation = read_json(CAND / 'simulation_summary.json')
    require(functional['status'] == simulation['status'] == 'PASS', 'Candidate simulation failed')
    require(len(functional['tests']) == 9 and len(simulation['tests']) == 5, 'Incomplete candidate regression')
    return {'freeze_manifest_sha256': sha(CAND / 'FREEZE_MANIFEST.json'), 'files_sha256': files}


def board_gate():
    # This imported helper is read-only. Its main() is intentionally never called.
    validator = load_module(BOARD / 'validate_candidate_uart.py', 'v106_uart_gate_readonly')
    summary_path = CAND / 'build_qualified_scope_summary.json'
    build = read_json(summary_path)
    require(build.get('status') == 'BUILD_PASS_NOT_BOARD', 'Unqualified routed build')
    require(build.get('device') == 'GW5A-LV25MG121NES' and build.get('clk_mhz') == 50,
            'Wrong board or clock')
    required_gates = ('route_process', 'route_complete', 'lut_15k', 'dsp_4', 'timing_50mhz', 'hold')
    require(all(build.get('gates', {}).get(k) is True for k in required_gates)
            and all(build['gates'].values()), 'Resource/setup/hold gate failed')
    require(min(build.get('fmax_mhz', []), default=0) >= 50, '50 MHz setup failed')
    require(build['util']['lut4'] <= 15000 and build['util']['mult12'] <= 4, 'Resource budget exceeded')
    checks = build.get('clock_checks', {})
    require(checks.get('actual_clock_mhz') == 50 and checks.get('setup_50mhz') is True
            and checks.get('hold') is True and checks.get('multicycle_exception') is False,
            'Missing actual 50 MHz/no-exception evidence')
    artifacts = validator.verify_frozen_artifacts(CAND, build)
    require(artifacts['expected_uart_sha256'] == digest(EXPECTED), 'UART freeze mismatch')
    image = candidate_file(build['bitstream'])
    require(sha(image) == build['bitstream_sha256'] and image.stat().st_size == build['bitstream_bytes'],
            'Bitstream changed')
    original = candidate_file(build['original_build_summary'])
    require(sha(original) == build['original_build_summary_sha256'], 'Original route summary changed')
    routed = read_json(original)
    for key in ('input_top25k_sha256', 'bitstream_sha256', 'fmax_mhz', 'gates', 'util'):
        require(build[key] == routed[key], 'Qualified route summary changed ' + key)
    final_path = CAND / 'board_validation_summary.json'
    final = read_json(final_path)
    require(final.get('status') == 'PASS' and final.get('programming') == 'SRAM_ONLY'
            and final.get('independent_sram_loads') == 3, 'Three SRAM passes missing')
    require(final.get('expected_uart') == EXPECTED.decode() and final.get('uart_bytes_per_load') == len(EXPECTED)
            and final.get('bitstream_sha256') == sha(image), 'Board summary differs from frozen artifacts')
    require(final.get('functional_clk_mhz') == 50 and final.get('resources') == build['util']
            and final.get('fmax_mhz') == build['fmax_mhz'], 'Board summary timing/resource mismatch')
    loads = final.get('loads', [])
    require(len(loads) == 3 and len({load['record'] for load in loads}) == 3, 'Loads must be distinct')
    records = {}
    dates = set()
    for load in loads:
        path = candidate_file(load['record'])
        require(sha(path) == load['sha256'], 'Board record changed')
        rec = read_json(path)
        require(rec.get('status') == 'PASS' and rec.get('programming') == 'PASS_SRAM_ONLY'
                and rec.get('programmer_returncode') == 0 and rec.get('jtag_detect_returncode') == 0
                and rec.get('jtag_detected_idcode') == '0x1281b', 'SRAM/JTAG record failed')
        require(rec.get('uart_capture') == rec.get('expected_uart') == EXPECTED.decode()
                and rec.get('uart_bytes') == len(EXPECTED) and rec.get('uart_validation') == 'PASS_EXACT_BYTES',
                'Board UART differs from independent golden')
        require(rec.get('expected_uart_sha256') == digest(EXPECTED)
                and rec.get('bitstream_sha256') == sha(image)
                and rec.get('build_summary_sha256') == sha(summary_path), 'Board provenance mismatch')
        require(rec.get('post_line_min_requested_seconds', 0) >= 0.1
                and rec.get('post_line_observation_seconds', 0) >= 0.1
                and rec.get('post_line_extra_bytes') == 0, 'UART quiet observation missing/failed')
        verified = rec.get('pre_program_artifact_verification', {})
        require(verified.get('retained_netlist_sha256') == build['input_top25k_sha256']
                and verified.get('expected_uart_sha256') == digest(EXPECTED)
                and verified.get('simulation_freeze', {}).get('freeze_manifest_sha256') == sha(CAND / 'FREEZE_MANIFEST.json'),
                'Board record lacks frozen source/netlist/fixture gate')
        dates.add(rec['date'])
        records[path.name] = sha(path)
    require(len(dates) == 3, 'Board records must have distinct timestamps')
    return {'board_summary_sha256': sha(final_path), 'qualified_build_sha256': sha(summary_path),
            'bitstream_sha256': sha(image), 'board_record_sha256': records,
            'artifact_verification': artifacts, 'fmax_mhz': build['fmax_mhz'],
            'resources': build['util'], 'physical_scope': final['scope'],
            'shared_validator_source_sha256': sha(BOARD / 'validate_candidate_uart.py')}


def proposed_bytes():
    data = (CAND / ('rtl/' + PRIVATE + '.v')).read_bytes()
    pattern = rb'(?m)^(module\s+)' + PRIVATE.encode() + rb'(?=\s*#)'
    proposed, count = re.subn(pattern, lambda m: m[1] + PUBLIC.encode(), data)
    require(count == 1 and data.count(PRIVATE.encode()) == 1, 'Expected one module declaration only')
    return proposed


def baseline_hash():
    entries = read_json(CAND / 'production_source_sha256.json')
    found = [value for name, value in entries.items() if Path(name).name == TARGET.name]
    require(len(found) == 1, 'Missing original production hash')
    baseline = (CAND / ('reference/' + PUBLIC + '_baseline.v')).read_bytes()
    old = baseline.replace(('module ' + PUBLIC + '_baseline #').encode(), ('module ' + PUBLIC + ' #').encode(), 1)
    require(digest(old) == found[0], 'Preserved reference does not match old production')
    return found[0]


def backup_production(out):
    folder = out / 'before'
    folder.mkdir()
    inventory = {}
    for path in (TARGET, PROD / 'README.md', PROD / 'manifest.json'):
        copied = folder / path.name
        shutil.copyfile(path, copied)
        inventory[path.relative_to(ROOT).as_posix()] = {'sha256': sha(path), 'backup': copied.name,
                                                       'bytes': copied.stat().st_size}
    write_json(folder / 'inventory.json', inventory)
    return inventory


class RecordedSubprocess:
    def __init__(self):
        self.commands = []

    def run(self, args, *positional, **kwargs):
        command = list(map(str, args))
        if command[0] in ('iverilog', 'vvp'):
            command[0] = device_flow.resolve(command[0])
        kwargs['env'] = device_flow.tool_env()
        kwargs.setdefault('timeout', 120)
        self.commands.append({'argv': command, 'cwd': str(kwargs.get('cwd', Path.cwd()))})
        return subprocess.run(command, *positional, **kwargs)


def identifier_only(data):
    return re.sub(r'\b' + PRIVATE + r'\b', PUBLIC, data)


@contextmanager
def regression_stage(out, records):
    with tempfile.TemporaryDirectory(prefix='.stage_', dir=HERE) as temporary:
        stage = Path(temporary)
        try:
            yield stage
        finally:
            # Preserve diagnostic evidence on failure before removing simulator images.
            for path in sorted(stage.rglob('*')):
                if path.is_file() and path.suffix in ('.log', '.json'):
                    destination = out / 'regressions' / path.relative_to(stage)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, destination)
            write_json(out / 'executed_commands.json', records.commands)


def regressions(out, data, actual_production):
    records = RecordedSubprocess()
    with regression_stage(out, records) as stage:
        for name in ('cases.mem', 'pixels.mem', 'config.vh', 'report.vh', 'expected_uart.txt',
                     'expected_uart.hex', 'expected_uart_fault.txt', 'expected_uart_fault.hex',
                     'golden_summary.json', 'tb_image_temporal_selftest_25k.sv', 'tb_por.sv',
                     'README.md', 'production_source_sha256.json', 'external_http_review.json'):
            shutil.copyfile(CAND / name, stage / name)
        (stage / 'reference').mkdir()
        shutil.copyfile(CAND / ('reference/' + PUBLIC + '_baseline.v'), stage / ('reference/' + PUBLIC + '_baseline.v'))
        (stage / 'rtl').mkdir()
        # The filename matches the frozen test script; its bytes use the PUBLIC module.
        staged_rtl = stage / ('rtl/' + PRIVATE + '.v')
        staged_rtl.write_bytes(data)
        require(sha(staged_rtl) == digest(data), 'Staged RTL byte mismatch')
        top_path = CAND / 'image_temporal_selftest_25k.v'
        top = top_path.read_bytes()
        require(len(re.findall(rb'\b' + PRIVATE.encode() + rb'\b', top)) == 1, 'Unexpected board identifier map')
        adapted_top = re.sub(rb'\b' + PRIVATE.encode() + rb'\b', PUBLIC.encode(), top)
        (stage / top_path.name).write_bytes(adapted_top)
        generator = load_module(CAND / 'generate_vectors.py', 'generate_vectors')
        sys.modules['generate_vectors'] = generator
        functional = load_module(CAND / 'run_functional.py', 'v106_production_functional')
        require(functional.BENCH.count(PRIVATE) == 1, 'Unexpected functional identifier map')
        original_bench_sha = digest(functional.BENCH.encode())
        functional.BENCH = identifier_only(functional.BENCH)
        functional.HERE, functional.ROOT, functional.subprocess = stage, ROOT, records
        functional.main()
        board_sim = load_module(CAND / 'run_board_sim.py', 'v106_production_board_sim')
        board_sim.HERE, board_sim.ROOT, board_sim.subprocess = stage, ROOT, records
        board_sim.main()
        func = read_json(stage / 'functional_summary.json')
        board = read_json(stage / 'simulation_summary.json')
        require(len(func['tests']) == 9 and len(board['tests']) == 5, 'Incomplete production adaptation')
        require(func['source_sha256'] == digest(data), 'Functional used different RTL')
        group = load_module(IMAGE / 'sim/run_image_core_group.py', 'v106_original_image_core')
        original_sources = group.rtl_sources()
        require(TARGET in original_sources, 'Original group omitted temporal source')
        group_sources = original_sources if actual_production else [staged_rtl if p == TARGET else p for p in original_sources]
        group.rtl_sources = lambda: group_sources
        group.subprocess = records
        group.GROUP_OUT = stage / 'image_core'
        original_main = inspect.getsource(group.main)
        output_line = "out=ROOT/('build_core_group_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'))"
        require(original_main.count(output_line) == 1, 'Image-core output adaptation no longer matches')
        adapted_main = original_main.replace(output_line, 'out=GROUP_OUT', 1)
        exec(compile(adapted_main, str(IMAGE / 'sim/run_image_core_group.py'), 'exec'), group.__dict__)
        require(group.main() == 0, 'Original image_core group failed')
        require('PASS IMAGE CORE GROUP' in (group.GROUP_OUT / 'simulation.log').read_text(), 'Missing group PASS')
        adaptations = {'numeric_goldens_changed': False, 'checker_changed': False,
                       'watchdogs_changed': False, 'functional_module_identifier_replacements': 1,
                       'board_top_module_identifier_replacements': 1,
                       'functional_bench_original_sha256': original_bench_sha,
                       'functional_bench_adapted_sha256': digest(functional.BENCH.encode()),
                       'board_top_original_sha256': sha(top_path),
                       'board_top_adapted_sha256': digest(adapted_top),
                       'image_core_original_script_sha256': sha(IMAGE / 'sim/run_image_core_group.py'),
                       'image_core_main_original_sha256': digest(original_main.encode()),
                       'image_core_main_adapted_sha256': digest(adapted_main.encode()),
                       'image_core_main_change': 'output directory only; tools resolved through device_flow',
                       'image_core_source_sha256': {p.relative_to(ROOT).as_posix(): sha(p) for p in original_sources},
                       'image_core_temporal_source': str(TARGET if actual_production else staged_rtl),
                       'staged_public_rtl_sha256': sha(staged_rtl)}
        require(not actual_production or sha(TARGET) == sha(staged_rtl), 'Production changed during tests')
    require(not stage.exists(), 'Simulator temporary directory was not cleaned')
    return {'functional_configurations': 9, 'board_simulations': 5,
            'image_core_cases': 7, 'image_core_pixels': 183, 'image_core_windows': 4,
            'commands': records.commands, 'adaptations': adaptations,
            'temporary_directory_removed': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--preflight', action='store_true')
    mode.add_argument('--apply', action='store_true')
    mode.add_argument('--verify', action='store_true')
    args = parser.parse_args()
    out = HERE / ('run_' + datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir()
    summary = {'status': 'FAIL', 'mode': vars(args), 'production_written': False,
               'production_board_programming': 'NOT_RUN', 'runner_sha256': sha(Path(__file__)),
               'candidate': CAND.relative_to(ROOT).as_posix(), 'created_utc': datetime.now(timezone.utc).isoformat()}
    before_production = {p.relative_to(ROOT).as_posix(): sha(p) for p in (TARGET, PROD / 'README.md', PROD / 'manifest.json')}
    summary['production_before_sha256'] = before_production
    try:
        freeze = freeze_gate()
        expected_old_sha = baseline_hash()
        proposed = proposed_bytes()
        summary.update(freeze=freeze, proposed_public_rtl_sha256=digest(proposed), original_production_sha256=expected_old_sha)
        board = None if args.preflight else board_gate()
        summary['board_qualification'] = board or 'NOT_REQUIRED_FOR_STAGED_ONLY_PREFLIGHT'
        if args.preflight:
            require(sha(TARGET) == expected_old_sha, 'Preflight requires unchanged original production')
        elif args.apply:
            require(not (HERE / 'APPLIED.json').exists(), 'Already applied; use --verify')
            require(sha(TARGET) == expected_old_sha, 'Production RTL differs from frozen original')
            summary['backup'] = backup_production(out)
            # Recheck immediately before the single explicitly requested mutation.
            require(freeze_gate() == freeze and board_gate() == board, 'Evidence changed before apply')
            require(sha(TARGET) == expected_old_sha, 'Production changed before apply')
            TARGET.write_bytes(proposed)
            summary['production_written'] = True
            write_json(HERE / 'APPLIED.json', {'run': out.name, 'before_sha256': expected_old_sha,
                       'after_sha256': sha(TARGET), 'backup_inventory': str((out / 'before/inventory.json').relative_to(HERE)),
                       'board_qualification': board, 'initial_regression_status': 'PENDING; consult the retained run summary'})
        else:
            require((HERE / 'APPLIED.json').is_file(), 'No retained integration/backup record')
            require(sha(TARGET) == digest(proposed), 'Production is not exact module-name restoration')
        actual_production = not args.preflight
        summary['regressions'] = regressions(out, proposed if args.preflight else TARGET.read_bytes(), actual_production)
        require(freeze_gate() == freeze, 'Candidate changed during regression')
        if actual_production:
            require(board_gate() == board, 'Board evidence changed during regression')
        require(sha(PROD / 'README.md') == before_production[(PROD / 'README.md').relative_to(ROOT).as_posix()]
                and sha(PROD / 'manifest.json') == before_production[(PROD / 'manifest.json').relative_to(ROOT).as_posix()],
                'Production metadata changed during runner')
        require(sha(TARGET) == (digest(proposed) if actual_production else expected_old_sha), 'Unexpected production RTL change')
        summary.update(status='PASS_PRODUCTION_REGRESSION' if actual_production else 'PASS_STAGED_ONLY_NOT_APPLIED',
                       production_pass=actual_production, physical_scope='Candidate GRAY8 MAX4x3 only; functional64x64 simulation does not extend timing qualification',
                       latency='LOAD/PRODUCTS/SUM/SEND: one additional enabled product stage relative to baseline LOAD/CALC/SEND',
                       production_after_sha256=sha(TARGET),
                       evidence_sha256={p.relative_to(out).as_posix(): sha(p) for p in sorted(out.rglob('*')) if p.is_file()})
    except Exception as error:
        summary['error'] = repr(error)
        raise
    finally:
        summary['temporary_stage_directories_remaining'] = [p.name for p in HERE.glob('.stage_*')]
        write_json(out / 'summary.json', summary)
        print('V106_PRODUCTION_RUNNER ' + summary['status'] + ' evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
