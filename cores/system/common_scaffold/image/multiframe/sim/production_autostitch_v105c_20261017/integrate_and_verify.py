"""Stage or integrate a board-qualified autostitch candidate; never program hardware.

Only --apply writes the four listed RTL targets, after three strict SRAM passes.
Shared source lists, README, manifest and authoritative board records belong to root.
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
PROD = ROOT / 'cores/system/common_scaffold/image/multiframe'
BOARD = ROOT / 'cores/system/common_scaffold/board/tang25k'
DEFAULT_CAND = BOARD / 'build/image_autostitch_frame_selftest_25k_20261017_v105d_addrpipe'
EXPECTED = b'STC PASS F=20 I=003E A=004B O=012C E=0000 D=64FB8FCF C=F\r\n'
TOP = 'image_autostitch_frame_selftest_25k'
INDEXES = [ROOT / 'cores/system/common_scaffold/image/rtl_sources.f',
           ROOT / 'cores/system/common_scaffold/rtl_functional_sources.f']
SOURCES = {
    'img_mf_auto_stitch.v': ('img_mf_auto_stitch_bram.v',
        {'img_mf_auto_stitch_bram': 'img_mf_auto_stitch', 'img_mf_translation_sad_pipe': 'img_mf_translation_sad'}),
    'img_mf_translation_sad.v': ('img_mf_translation_sad_pipe.v',
        {'img_mf_translation_sad_pipe': 'img_mf_translation_sad'}),
    'img_mf_dual_frame_store_bram_read.v': ('img_mf_dual_frame_store_bram_read.v', {}),
    'img_mf_signed_floor_divider.v': ('img_mf_signed_floor_divider.v', {}),
}
REFERENCE_NAMES = {n: n + '_original_reference' for n in
                   ('img_mf_auto_stitch', 'img_mf_dual_frame_store', 'img_mf_translation_sad')}
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


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')


def module(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    item = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(item)
    return item


def local(candidate, name):
    target = (candidate / name).resolve()
    require(target.is_relative_to(candidate.resolve()) and target.is_file(), 'Unsafe/missing candidate input ' + name)
    return target


def rename(data, mapping, counts=None):
    actual = {}
    for old, new in mapping.items():
        data, actual[old] = re.subn(rb'\b' + old.encode() + rb'\b', new.encode(), data)
        if counts is not None:
            require(actual[old] == counts[old], 'Unexpected identifier count ' + old)
    return data, actual


def freeze_gate(candidate):
    manifest = read_json(candidate / 'FREEZE_MANIFEST.json')
    require(manifest['verification']['result'] == 'PASS', 'Candidate freeze not PASS')
    frozen = manifest['files_sha256']
    require(all(sha(local(candidate, n)) == v for n, v in frozen.items()), 'Frozen input changed')
    sim = read_json(candidate / 'simulation_summary.json')
    required = {'por', 'board', 'original_production_reference', 'injected_checker_error', 'reset_recovery', 'store_random_pipeline'}
    require(sim['status'] == 'PASS' and {t['test'] for t in sim['tests']} == required
            and all(t['status'] == 'PASS' for t in sim['tests']), 'Candidate board simulation incomplete')
    require(tuple(sim[k] for k in ('commands', 'main_inputs', 'aux_inputs', 'outputs', 'error_responses', 'uart_bytes', 'uart_quiet_bits'))
            == (32, 62, 75, 300, 14, 58, 12), 'Candidate numerical contract changed')
    require((candidate / 'expected_uart.txt').read_bytes() == EXPECTED, 'Original UART changed')
    sad, div = read_json(candidate / 'sad_stage_summary.json'), read_json(candidate / 'divider_regression_summary.json')
    require(sad['status'] == div['status'] == 'PASS' and len(sad['tests']) == 8 and len(div['tests']) == 3,
            'Candidate unit coverage incomplete')
    require(sim['sad_stage_summary_sha256'] == sha(candidate / 'sad_stage_summary.json')
            and sim['divider_regression_summary_sha256'] == sha(candidate / 'divider_regression_summary.json'), 'Unit summary changed')
    for name, count in (('store_pipeline_summary.json', 3), ('sad_address_summary.json', 6)):
        unit = read_json(candidate / name)
        require(unit['status'] == 'PASS' and len(unit['tests']) == count
                and sim[name[:-5] + '_sha256'] == sha(candidate / name), 'Address/store coverage incomplete: ' + name)
    inventory = read_json(candidate / 'production_source_sha256.json')
    require({p.name: sha(p) for p in (candidate / 'rtl').glob('*.v')} == inventory['candidate_rtl_sha256'], 'Candidate RTL inventory changed')
    for name in ['simulation_summary.json', 'expected_uart.txt', 'run_sad_pipeline.py', 'run_divider_regression.py', 'run_sim.py',
                 'run_store_pipeline_regression.py', 'run_sad_address_regression.py',
                 'reference/img_mf_auto_stitch_v105b_baseline.v', 'reference/img_mf_dual_frame_store_v105c_baseline.v',
                 *['rtl/' + name for name, _ in SOURCES.values()]]:
        require(name in frozen, 'Freeze omits ' + name)
    official = module(BOARD / 'resume_candidate_route_official.py', 'autostitch_official_gate')
    gate = official.verify_simulation_gate(candidate)
    require(gate.get('source_sha256_verified') and gate.get('freeze_files_sha256_verified'), 'Actual official freeze gate failed')
    # Parent synthesis/PNR may update build_status while staging is running.
    # The official verifier is still called every time; cross-run equality
    # binds immutable simulation inputs, not its mutable progress snapshot.
    immutable_gate = {k: gate[k] for k in ('simulation', 'source_sha256_verified',
                      'freeze_manifest_sha256', 'freeze_files_sha256_verified')}
    return {'freeze_manifest_sha256': sha(candidate / 'FREEZE_MANIFEST.json'), 'files_sha256': frozen,
            'official_input_gate': immutable_gate}


def board_gate(candidate, build_name, board_name):
    validator = module(BOARD / 'validate_candidate_uart.py', 'autostitch_uart_readonly')
    build_path = local(candidate, build_name)
    build = read_json(build_path)
    require(build.get('status') == 'BUILD_PASS_NOT_BOARD' and build.get('device') == 'GW5A-LV25MG121NES'
            and build.get('clk_mhz') == 50, 'Wrong/unqualified routed build')
    gates = build.get('gates', {})
    require(all(gates.get(k) is True for k in ('route_process', 'route_complete', 'lut_15k', 'dsp_4', 'timing_50mhz', 'hold'))
            and all(gates.values()), 'Resource/setup/hold gate failed')
    require(min(build.get('fmax_mhz', []), default=0) >= 50 and build['util']['lut4'] <= 15000
            and build['util']['mult12'] <= 4, '50MHz/resource budget failed')
    checks = build.get('clock_checks', {})
    require(checks.get('actual_clock_mhz') == 50 and checks.get('setup_50mhz') is True
            and checks.get('hold') is True and checks.get('multicycle_exception') is False, 'Missing actual 50MHz/no-exception evidence')
    ce = build.get('core_enable_divisor')
    require((type(ce) is int and ce == 4) or ce == '1 of 4 physical edges; no timing exception',
            'Autostitch board CE must remain exactly 1/4 with full no-exception clock checks')
    artifacts = validator.verify_frozen_artifacts(candidate, build)
    require(artifacts['expected_uart_sha256'] == digest(EXPECTED), 'UART provenance changed')
    image = local(candidate, build['bitstream'])
    require(sha(image) == build['bitstream_sha256'] and image.stat().st_size == build['bitstream_bytes'], 'Bitstream changed')
    original = local(candidate, build['original_build_summary'])
    require(sha(original) == build['original_build_summary_sha256'], 'Original route summary changed')
    routed = read_json(original)
    require(all(build[k] == routed[k] for k in ('input_top25k_sha256', 'bitstream_sha256', 'fmax_mhz', 'gates', 'util')),
            'Qualified route does not match original route')
    final_path = local(candidate, board_name)
    final = read_json(final_path)
    require(final.get('status') == 'PASS' and final.get('programming') == 'SRAM_ONLY'
            and final.get('independent_sram_loads') == 3, 'Three independent SRAM passes missing')
    require(final.get('expected_uart') == EXPECTED.decode() and final.get('uart_bytes_per_load') == 58
            and final.get('bitstream_sha256') == sha(image), 'Board UART/bitstream differs')
    require(final.get('functional_clk_mhz') == 50 and final.get('resources') == build['util']
            and final.get('fmax_mhz') == build['fmax_mhz'], 'Board summary resource/timing mismatch')
    require(final.get('clock_enable') == '1/4; no timing exception' and final.get('scope') == build.get('scope'),
            'Board CE/scope differs from qualified build')
    loads = final.get('loads', [])
    require(len(loads) == 3 and len({r['record'] for r in loads}) == 3, 'Board records not distinct')
    dates, records = set(), {}
    for load in loads:
        path = local(candidate, load['record'])
        require(sha(path) == load['sha256'], 'Board record changed')
        rec = read_json(path)
        require(rec.get('status') == 'PASS' and rec.get('programming') == 'PASS_SRAM_ONLY'
                and rec.get('programmer_returncode') == rec.get('jtag_detect_returncode') == 0
                and rec.get('jtag_detected_idcode') == '0x1281b', 'SRAM/JTAG record failed')
        require(rec.get('uart_capture') == rec.get('expected_uart') == EXPECTED.decode()
                and rec.get('uart_bytes') == 58 and rec.get('uart_validation') == 'PASS_EXACT_BYTES', 'UART not exact')
        require(rec.get('expected_uart_sha256') == digest(EXPECTED) and rec.get('bitstream_sha256') == sha(image)
                and rec.get('build_summary_sha256') == sha(build_path), 'Board provenance mismatch')
        require(rec.get('functional_clk_mhz') == 50 and rec.get('core_enable_divisor') == ce
                and rec.get('clock_checks') == checks and rec.get('scope') == build.get('scope'), 'Board-record clock/scope mismatch')
        require(rec.get('post_line_min_requested_seconds', 0) >= 0.1 and rec.get('post_line_observation_seconds', 0) >= 0.1
                and rec.get('post_line_extra_bytes') == 0, 'UART quiet check failed')
        verified = rec.get('pre_program_artifact_verification', {})
        require(verified.get('retained_netlist_sha256') == build['input_top25k_sha256']
                and verified.get('expected_uart_sha256') == digest(EXPECTED)
                and verified.get('simulation_freeze', {}).get('freeze_manifest_sha256') == sha(candidate / 'FREEZE_MANIFEST.json'),
                'Board record missing frozen source/netlist/fixture check')
        dates.add(rec['date']); records[load['record']] = sha(path)
    require(len(dates) == 3, 'Board timestamps not distinct')
    return {'qualified_build_sha256': sha(build_path), 'board_summary_sha256': sha(final_path),
            'bitstream_sha256': sha(image), 'board_record_sha256': records, 'artifact_verification': artifacts,
            'resources': build['util'], 'fmax_mhz': build['fmax_mhz'], 'physical_scope': final['scope'],
            'validator_sha256': sha(BOARD / 'validate_candidate_uart.py')}


def proposed_files(candidate):
    proposed, adaptations = {}, {}
    for public, (private, names) in SOURCES.items():
        data = (candidate / 'rtl' / private).read_bytes()
        proposed[public], counts = rename(data, names, {n: 1 for n in names})
        adaptations[public] = {'candidate': 'rtl/' + private, 'candidate_sha256': digest(data),
                               'public_sha256': digest(proposed[public]), 'identifier_counts': counts}
    return proposed, adaptations


def snapshot_production():
    paths = [*sorted(PROD.glob('*.v')), PROD / 'README.md', PROD / 'manifest.json', *INDEXES]
    if (PROD / 'mf_frame_group.vvp').exists(): paths.append(PROD / 'mf_frame_group.vvp')
    paths += [PROD / n for n in SOURCES if not (PROD / n).exists()]
    return {p.relative_to(ROOT).as_posix(): sha(p) if p.exists() else None for p in paths}


def old_guard(candidate, before):
    original = read_json(candidate / 'production_source_sha256.json')['reference_snapshot_sha256']
    for name in ('img_mf_auto_stitch.v', 'img_mf_translation_sad.v'):
        require(before[(PROD / name).relative_to(ROOT).as_posix()] == original[name], 'Production differs from frozen baseline: ' + name)
    for name in ('img_mf_dual_frame_store_bram_read.v', 'img_mf_signed_floor_divider.v'):
        require(not (PROD / name).exists(), 'Unexpected preexisting helper: ' + name)


class RecordedSubprocess:
    def __init__(self, actual_paths):
        self.actual_paths, self.commands = actual_paths, []

    def run(self, args, *positional, **kwargs):
        argv = [self.actual_paths.get(str(a), str(a)) for a in args]
        kwargs['env'] = device_flow.tool_env()
        kwargs.setdefault('timeout', 180)
        self.commands.append({'argv': argv, 'cwd': str(kwargs.get('cwd', Path.cwd()))})
        return subprocess.run(argv, *positional, **kwargs)


@contextmanager
def staging(out, recorder):
    with tempfile.TemporaryDirectory(prefix='.stage_', dir=HERE) as tmp:
        stage = Path(tmp)
        try:
            yield stage
        finally:
            for path in sorted(stage.rglob('*')):
                if path.is_file() and path.suffix in ('.json', '.log'):
                    target = out / 'regressions' / path.relative_to(stage)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
            write_json(out / 'executed_commands.json', recorder.commands)


def adapt_run(item, changes, path):
    original = inspect.getsource(item.run)
    adapted = original
    for old, new, count in changes:
        require(adapted.count(old) == count, 'Regression adaptation no longer matches: ' + old)
        adapted = adapted.replace(old, new)
    exec(compile(adapted, str(path), 'exec'), item.__dict__)
    return {'original_run_sha256': digest(original.encode()), 'adapted_run_sha256': digest(adapted.encode()),
            'changes': [{'from': a, 'to': b, 'count': c} for a, b, c in changes]}


def regressions(candidate, out, proposed, actual):
    recorder = RecordedSubprocess({})
    adaptations = {}
    with staging(out, recorder) as stage:
        for path in candidate.iterdir():
            if path.is_file() and (path.suffix in ('.sv', '.vh', '.hex', '.mem') or path.name in
                    ('README.md', 'expected_uart.txt', 'golden_summary.json', 'production_source_sha256.json', 'PREDECESSOR.json')):
                shutil.copyfile(path, stage / path.name)
        (stage / 'rtl').mkdir(); (stage / 'reference').mkdir()
        for name, (private, _) in SOURCES.items():
            target = stage / 'rtl' / private
            target.write_bytes(proposed[name])
            if actual:
                require(sha(PROD / name) == digest(proposed[name]), 'Production differs from proposal')
                recorder.actual_paths[str(target)] = str(PROD / name)
        for path in (candidate / 'reference').glob('*.v'):
            data = path.read_bytes()
            if path.name in ('img_mf_auto_stitch.v', 'img_mf_dual_frame_store.v', 'img_mf_translation_sad.v'):
                data, counts = rename(data, REFERENCE_NAMES)
                adaptations[path.name] = {'original_sha256': sha(path), 'staged_sha256': digest(data), 'identifier_counts': counts}
            (stage / 'reference' / path.name).write_bytes(data)
        support = stage / 'reference/img_mf_translation_sad_pipe_baseline_support.v'
        support.write_bytes((candidate / 'rtl/img_mf_translation_sad_pipe.v').read_bytes())
        original_top = (candidate / (TOP + '.v')).read_bytes()
        # Map original public name first; map only the candidate private name second.
        top, counts = rename(original_top, {'img_mf_auto_stitch': 'img_mf_auto_stitch_original_reference',
                                           'img_mf_auto_stitch_bram': 'img_mf_auto_stitch'},
                              {'img_mf_auto_stitch': 1, 'img_mf_auto_stitch_bram': 1})
        (stage / (TOP + '.v')).write_bytes(top)
        adaptations['board_top'] = {'original_sha256': digest(original_top), 'adapted_sha256': digest(top), 'identifier_counts': counts}
        inventory = read_json(stage / 'production_source_sha256.json')
        inventory['candidate_rtl_sha256'] = {p.name: sha(p) for p in (stage / 'rtl').glob('*.v')}
        inventory['reference_snapshot_sha256'] = {n: sha(stage / 'reference' / n) for n in inventory['reference_snapshot_sha256']}
        write_json(stage / 'production_source_sha256.json', inventory)
        sad = module(candidate / 'run_sad_pipeline.py', 'autostitch_sad_actual')
        adaptations['sad_script'] = adapt_run(sad, [
            ("[('img_mf_translation_sad','old_dut'),('img_mf_translation_sad_pipe','new_dut')]",
             "[('img_mf_translation_sad_original_reference','old_dut'),('img_mf_translation_sad','new_dut')]", 1)], candidate / 'run_sad_pipeline.py')
        div = module(candidate / 'run_divider_regression.py', 'autostitch_div_actual')
        adaptations['divider_script'] = adapt_run(div, [
            ("sources=[H/'rtl/img_mf_signed_floor_divider.v',H/'rtl/img_mf_translation_sad_pipe.v',",
             "sources=[H/'rtl/img_mf_signed_floor_divider.v',H/'rtl/img_mf_translation_sad_pipe.v',H/'reference/img_mf_translation_sad_pipe_baseline_support.v',", 1)], candidate / 'run_divider_regression.py')
        for item, name in ((sad, 'run_sad_pipeline'), (div, 'run_divider_regression')):
            item.H, item.ROOT, item.subprocess = stage, ROOT, recorder
            sys.modules[name] = item
        store = module(candidate / 'run_store_pipeline_regression.py', 'autostitch_store_actual')
        address = module(candidate / 'run_sad_address_regression.py', 'autostitch_address_actual')
        original_address_bench = address.BENCH.encode()
        address_bench, address_counts = rename(original_address_bench,
            {'img_mf_translation_sad': 'img_mf_translation_sad_original_reference',
             'img_mf_translation_sad_pipe': 'img_mf_translation_sad'},
            {'img_mf_translation_sad': 1, 'img_mf_translation_sad_pipe': 1})
        address.BENCH = address_bench.decode()
        adaptations['address_bench'] = {'original_sha256': digest(original_address_bench),
            'adapted_sha256': digest(address_bench), 'identifier_counts': address_counts}
        for item, name in ((store, 'run_store_pipeline_regression'), (address, 'run_sad_address_regression')):
            item.H, item.ROOT, item.subprocess = stage, ROOT, recorder
            sys.modules[name] = item
        sim = module(candidate / 'run_sim.py', 'autostitch_board_actual')
        sim.H, sim.ROOT, sim.subprocess = stage, ROOT, recorder
        result = sim.run()
        require(result['status'] == 'PASS' and len(result['tests']) == 6, 'Production board regression incomplete')
        # Existing group bench and watchdog are used byte-for-byte.
        group_sources = sorted(PROD.glob('*.v'))
        if not actual:
            group_sources = [stage / 'rtl' / SOURCES[p.name][0] if p.name in SOURCES else p for p in group_sources]
            group_sources += [stage / 'rtl' / private for name, (private, _) in SOURCES.items() if not (PROD / name).exists()]
        image = stage / 'group.vvp'
        compile_cmd = [device_flow.resolve('iverilog'), '-g2012', '-Wall', '-Wno-timescale', '-s', 'tb_img_mf_frame_group', '-o', str(image), *map(str, group_sources)]
        c = recorder.run(compile_cmd, cwd=PROD, capture_output=True, text=True)
        (stage / 'group_compile.log').write_text(c.stdout + c.stderr)
        require(c.returncode == 0, 'Original MF group compile failed: ' + c.stdout + c.stderr)
        r = recorder.run([device_flow.resolve('vvp'), str(image)], cwd=PROD, capture_output=True, text=True)
        (stage / 'group_simulation.log').write_text(r.stdout + r.stderr)
        print(r.stdout + r.stderr, end='', flush=True)
        require(r.returncode == 0 and 'MF GROUP PASS:' in r.stdout, 'Original MF group failed')
        require((PROD / 'tb_img_mf_frame_group.v').read_bytes() == next(p for p in group_sources if p.name == 'tb_img_mf_frame_group.v').read_bytes(), 'Group bench changed')
        require(read_json(stage / 'sad_stage_summary.json')['pipeline_rtl_sha256'] == digest(proposed['img_mf_translation_sad.v']), 'SAD regression used different source')
        require(read_json(stage / 'divider_regression_summary.json')['source_sha256'] == digest(proposed['img_mf_signed_floor_divider.v']), 'Divider regression used different source')
        production_paths = sorted(recorder.actual_paths.values())
        if actual:
            require(all(any(p in cmd['argv'] for cmd in recorder.commands) for p in production_paths), 'Actual production source not compiled')
    require(not stage.exists(), 'Temporary stage was not removed')
    return {'sad_configurations': 8, 'divider_configurations': 3, 'store_configurations': 3,
            'sad_address_configurations': 6, 'board_simulations': 6,
            'original_multiframe_group': 'PASS', 'actual_production_rtl_compiled': actual,
            'actual_production_paths': production_paths, 'adaptations': adaptations,
            'numeric_goldens_changed': False, 'checker_changed': False, 'watchdog_changed': False,
            'temporary_directory_removed': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    for name in ('plan', 'preflight', 'apply', 'verify'):
        modes.add_argument('--' + name, action='store_true')
    parser.add_argument('--candidate', type=Path, default=DEFAULT_CAND)
    parser.add_argument('--build-summary', default='build_qualified_scope_summary.json')
    parser.add_argument('--board-summary', default='board_validation_summary.json')
    args = parser.parse_args()
    if not any((args.plan, args.preflight, args.apply, args.verify)):
        args.plan = True
    candidate = args.candidate.resolve()
    require(candidate.is_relative_to((BOARD / 'build').resolve()), 'Candidate must be under board/build')
    out = HERE / ('run_' + datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S_%f'))
    out.mkdir()
    before = snapshot_production()
    result = {'status': 'FAIL', 'mode': 'plan' if args.plan else ('preflight' if args.preflight else ('apply' if args.apply else 'verify')),
              'production_written': False, 'production_before_sha256': before,
              'candidate': candidate.relative_to(ROOT).as_posix(), 'runner_sha256': sha(Path(__file__)),
              'hardware_operations': 'NOT_RUN', 'created_utc': datetime.now(timezone.utc).isoformat()}
    try:
        freeze = freeze_gate(candidate)
        proposed, maps = proposed_files(candidate)
        result.update(freeze=freeze, identifier_mapping=maps)
        board = None if args.preflight or args.plan else board_gate(candidate, args.build_summary, args.board_summary)
        result['board_qualification'] = board or 'NOT_REQUIRED_FOR_STAGED_ONLY_PREFLIGHT'
        plan = {'rtl_targets': {str((PROD / n).relative_to(ROOT)): {'before_sha256': before.get((PROD / n).relative_to(ROOT).as_posix()),
                        'after_sha256': digest(b)} for n, b in proposed.items()},
                'source_lists_owned_by_root': [str(p.relative_to(ROOT)) for p in INDEXES],
                'metadata_owned_by_root': [str((PROD / n).relative_to(ROOT)) for n in ('README.md', 'manifest.json')],
                'existing_public_dual_frame_store_unchanged': True}
        write_json(out / 'integration_plan.json', plan)
        if args.plan:
            require(snapshot_production() == before and freeze_gate(candidate) == freeze, 'Production/evidence changed during plan')
            result.update(status='PLAN_READY_NOT_APPLIED', production_pass=False,
                          regressions='NOT_RUN; use --preflight for staged regression', production_after_sha256=before)
            return
        if args.preflight or args.apply:
            old_guard(candidate, before)
        if args.apply:
            require(not (HERE / 'APPLIED.json').exists(), 'Already applied; use --verify')
            for path in INDEXES:
                entries = path.read_text().splitlines()
                require(all(entries.count((PROD / name).relative_to(ROOT).as_posix()) == 1 for name in SOURCES), 'Root must integrate source list first: ' + str(path))
            backup = out / 'before'; backup.mkdir()
            inventory = {}
            for name in [*(PROD / n for n in SOURCES), PROD / 'README.md', PROD / 'manifest.json', *INDEXES]:
                key = name.relative_to(ROOT).as_posix()
                target = backup / key; target.parent.mkdir(parents=True, exist_ok=True)
                if name.exists(): shutil.copyfile(name, target)
                inventory[key] = {'existed': name.exists(), 'sha256': sha(name) if name.exists() else None}
            write_json(backup / 'inventory.json', inventory)
            require(snapshot_production() == before and freeze_gate(candidate) == freeze
                    and board_gate(candidate, args.build_summary, args.board_summary) == board, 'Evidence/production changed before apply')
            result['production_written'] = True
            result['written_targets'] = []
            for name, data in proposed.items():
                (PROD / name).write_bytes(data)
                result['written_targets'].append(name)
            write_json(HERE / 'APPLIED.json', {'run': out.name, 'candidate': candidate.relative_to(ROOT).as_posix(),
                       'targets_sha256': {n: digest(b) for n, b in proposed.items()}, 'board_qualification': board,
                       'backup_inventory': str((backup / 'inventory.json').relative_to(HERE)), 'regressions': 'PENDING; consult run summary'})
        elif args.verify:
            applied = read_json(HERE / 'APPLIED.json')
            require(applied['candidate'] == candidate.relative_to(ROOT).as_posix()
                    and applied['targets_sha256'] == {n: digest(b) for n, b in proposed.items()}, 'Verify candidate differs from applied record')
            require(all(sha(PROD / n) == digest(b) for n, b in proposed.items()), 'Production differs from proposal')
        result['regressions'] = regressions(candidate, out, proposed, not args.preflight)
        require(freeze_gate(candidate) == freeze, 'Frozen candidate changed during tests')
        if board: require(board_gate(candidate, args.build_summary, args.board_summary) == board, 'Board evidence changed during tests')
        after = snapshot_production()
        for name, value in before.items():
            if not args.preflight and name in {(PROD / n).relative_to(ROOT).as_posix() for n in SOURCES}: continue
            require(after[name] == value, 'Unassigned production/shared file changed: ' + name)
        if not args.preflight:
            require(all(sha(PROD / n) == digest(b) for n, b in proposed.items()), 'Production changed after tests')
        result.update(status='PASS_STAGED_ONLY_NOT_APPLIED' if args.preflight else 'PASS_PRODUCTION_REGRESSION',
                      production_pass=not args.preflight, production_after_sha256=after,
                      physical_scope='Candidate RGB888 4x3 shift1 /6x5 canvas, CE1/4 at actual50MHz only; wider simulation is not timing qualification',
                      evidence_sha256={p.relative_to(out).as_posix(): sha(p) for p in sorted(out.rglob('*')) if p.is_file()})
    except Exception as error:
        result['error'] = repr(error)
        raise
    finally:
        result['temporary_stage_directories_remaining'] = [p.name for p in HERE.glob('.stage_*')]
        write_json(out / 'summary.json', result)
        print('AUTOSTITCH_PRODUCTION_RUNNER ' + result['status'] + ' evidence=' + str(out), flush=True)


if __name__ == '__main__':
    main()
