"""Integrate/recheck the exact three-load qualified bilateral implementation."""
import argparse
from datetime import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
IMAGE = ROOT / 'cores/system/common_scaffold/image'
FILTERS = IMAGE / 'filters'
CANDIDATE = ROOT / ('cores/system/common_scaffold/board/tang25k/build/'
                    'image_bilateral_selftest_25k_20261017_v104c_sigmapipes')
BEFORE = HERE / 'before'
sys.path.insert(0, str(ROOT / 'cores/signal_processing/dsp_isp_library/board/tang25k'))
import device_flow


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    source = CANDIDATE / 'rtl/img_filter_bilateral3x3_serial.v'
    production = FILTERS / 'rtl/img_filter_bilateral3x3.v'
    exact = source.read_bytes()
    declaration = b'module img_filter_bilateral3x3_serial #'
    assert exact.count(declaration) == 1
    public = exact.replace(declaration, b'module img_filter_bilateral3x3 #', 1)
    board_path = CANDIDATE / 'board_validation_summary.json'
    board = json.loads(board_path.read_text())
    assert board['status'] == 'PASS' and board['independent_sram_loads'] == 3
    assert board['uart_bytes_per_load'] == 43
    for entry in board['loads']:
        path = CANDIDATE / entry['record']
        assert sha(path) == entry['sha256']
        capture = json.loads(path.read_text())
        assert capture['status'] == 'PASS' and capture['jtag_detected_idcode'] == '0x1281b'
        assert capture['uart_capture'].encode('ascii') == (CANDIDATE / 'expected_uart.txt').read_bytes()
    build = json.loads((CANDIDATE / 'build_qualified_scope_summary.json').read_text())
    assert build['gates'] and all(build['gates'].values()) and min(build['fmax_mhz']) >= 50
    assert sha(source) == build['simulation_provenance']['freeze_files_sha256_verified']['rtl/img_filter_bilateral3x3_serial.v']
    if args.apply:
        assert not BEFORE.exists(), 'Do not overwrite baseline backup'
        assert production.read_bytes() != public, 'Already integrated'
        BEFORE.mkdir()
        for name, path in [('img_filter_bilateral3x3.v', production),
                           ('img_filter_exp_weight.v', FILTERS / 'rtl/img_filter_exp_weight.v'),
                           ('README.md', FILTERS / 'README.md'),
                           ('manifest.json', FILTERS / 'manifest.json')]:
            shutil.copy2(path, BEFORE / name)
        baseline = {p.name: sha(p) for p in BEFORE.iterdir() if p.is_file()}
        (HERE / 'baseline_sha256.json').write_text(json.dumps(baseline, indent=2)+'\n')
        production.write_bytes(public)
    assert BEFORE.exists() and production.read_bytes() == public
    assert (FILTERS / 'rtl/img_filter_exp_weight.v').read_bytes() == (BEFORE / 'img_filter_exp_weight.v').read_bytes()
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    regression = HERE / ('regression_' + stamp)
    regression.mkdir()
    tests = []
    # The frozen benches are reused without altering frozen files. Their new
    # DUT bytes come from the current public production module, renamed only
    # for the testbench. The comparison DUT is the preserved old production.
    with tempfile.TemporaryDirectory(prefix='.production_check_', dir=HERE) as td:
        temporary = Path(td)
        for path in CANDIDATE.iterdir():
            if path.is_file() and path.suffix in ('.v', '.sv', '.vh', '.mem', '.hex'):
                shutil.copy2(path, temporary / path.name)
        (temporary / 'rtl').mkdir()
        for path in (CANDIDATE / 'rtl').glob('*.v'):
            shutil.copy2(path, temporary / 'rtl' / path.name)
        (temporary / 'rtl/img_filter_bilateral3x3_serial.v').write_bytes(
            production.read_bytes().replace(b'module img_filter_bilateral3x3 #', declaration, 1))
        functional = load_module('bilateral_functional', CANDIDATE / 'run_functional.py')
        functional.HERE = temporary
        functional.PROD = BEFORE
        functional.main()
        tests.append('independent integer golden and old production: PW1/8/12, 39 completed cases each')
        board_sim = load_module('bilateral_board', CANDIDATE / 'run_board_sim.py')
        board_sim.HERE = temporary
        board_sim.main()
        tests.extend(['four POR settings', 'normal full UART', 'actual checker fault', 'mid-divider async reset/replay'])
        for path in temporary.iterdir():
            if path.is_file() and path.suffix in ('.log', '.json'):
                shutil.copy2(path, regression / path.name)
    before_groups = set(IMAGE.glob('build_core_group_*'))
    command = [sys.executable, '-B', str(IMAGE / 'sim/run_image_core_group.py')]
    result = subprocess.run(command, cwd=ROOT, env=device_flow.tool_env(),
                            capture_output=True, text=True, timeout=180)
    (regression / 'image_core_console.log').write_text(result.stdout + result.stderr)
    groups = set(IMAGE.glob('build_core_group_*')) - before_groups
    assert len(groups) == 1
    group = groups.pop()
    group_summary = json.loads((group / 'summary.json').read_text())
    assert result.returncode == 0 and group_summary['compile_exit'] == 0 and group_summary['simulation_exit'] == 0, result.stdout + result.stderr
    image = (group / 'core.vvp').resolve()
    assert image.parent == group.resolve() and image.is_relative_to(IMAGE.resolve())
    removed_bytes = image.stat().st_size
    image.unlink()
    assert production.read_bytes() == public
    evidence = dict(status='PASS', command='python -B '+str(Path(__file__).relative_to(ROOT)),
                    production_source=str(production.relative_to(ROOT)), production_sha256=sha(production),
                    candidate_source=str(source.relative_to(ROOT)), candidate_sha256=sha(source),
                    only_change_to_candidate='module declaration _serial suffix removed; helper unchanged',
                    tests=tests, regression=str(regression.relative_to(ROOT)),
                    group_evidence=str(group.relative_to(ROOT)), cases=group_summary['cases'],
                    pixels=group_summary['pixels'], windows=group_summary['windows'],
                    disposable_group_image_removed_bytes=removed_bytes,
                    temporary_directories_removed=True, baseline_preserved=True,
                    board_evidence=str(board_path.relative_to(ROOT)), board_evidence_sha256=sha(board_path),
                    independent_sram_loads=3, resources=board['resources'], fmax_mhz=board['fmax_mhz'],
                    scope=board['scope'], latency_change='shared two-phase restoring divider and registered sigma/product preparation; handshake wait required')
    (regression / 'summary.json').write_text(json.dumps(evidence, indent=2)+'\n')
    # Keep every execution as a distinct evidence record.
    (HERE / ('integration_provenance_' + stamp + '.json')).write_text(json.dumps(evidence, indent=2)+'\n')
    print(result.stdout, end='')
    print(json.dumps(evidence, indent=2))


if __name__ == '__main__':
    main()
