"""Separately approved, fixed 26-child TV qualification. No retries or sweeps."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations

import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = ROOT/'execution/attempt_01'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_bytes())


def write(path: Path, value: dict, exclusive: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2)+'\n')


def local(base: Path, name: str) -> Path:
    relative = PurePosixPath(name)
    assert name and not relative.is_absolute() and '..' not in relative.parts
    assert '\\' not in name and ':' not in name and not any(c in name for c in '\0\r\n')
    path = (base/name).resolve()
    assert path.is_relative_to(base.resolve())
    return path


def load_frozen(name: str, path: Path):
    assert name not in sys.modules
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def guard(expected: str) -> tuple[dict, dict]:
    assert sha(ROOT/'SOURCE_SEAL.json') == expected, 'prepared seal changed'
    seal = read(ROOT/'SOURCE_SEAL.json')
    assert seal['schema'] == 'anscore-tv-prepared-seal-v1'
    assert seal['status'] == 'PREPARED_NOT_HDL_RUN' and seal['max_children'] == 26
    assert sha(ROOT/'SOURCE_FREEZE.json') == seal['source_freeze_sha256']
    freeze = read(ROOT/'SOURCE_FREEZE.json')
    assert freeze['files_sha256'] == seal['source_files_sha256']
    for name, digest in seal['source_files_sha256'].items():
        assert sha(local(ROOT, name)) == digest, name
    prepared = {p.relative_to(ROOT).as_posix(): sha(p) for p in (ROOT/'prepared').rglob('*') if p.is_file()}
    assert prepared == seal['prepared_sha256'] and len(prepared) == 8
    assert read(ROOT/'prepared/RUNTIME.json') == seal['runtime']
    assert seal['tools'] == seal['runtime']['tools']
    assert seal['path_prefix'] == seal['runtime']['path_prefix']
    assert sha(ROOT/'FINITE_PLAN.json') == seal['finite_plan_sha256']
    plan = read(ROOT/'FINITE_PLAN.json')
    assert plan['schema'] == 'anscore-tv-finite-plan-v1'
    assert len(plan['children']) == plan['max_children'] == 26
    assert len({child['name'] for child in plan['children']}) == 26
    assert all(child['hard_seconds'] == 20 for child in plan['children'])
    assert plan['automatic_retry'] is False and plan['stop_on_first_failure'] is True
    assert plan['simulation_children'] == 10 and plan['named_parameter_rejects'] == 6
    preparation = read(ROOT/'preparation/attempt_01/receipt.json')
    assert preparation['status'] == 'PASS_FIXED_PREPARATION_ONLY'
    assert preparation['source_seal_sha256'] == expected
    assert preparation['source_freeze_sha256'] == seal['source_freeze_sha256']
    assert preparation['prepared_sha256'] == prepared
    assert preparation['tested_copies_sha256'] == seal['preparation_tested_copies_sha256']
    copied_guard(ROOT/'preparation/attempt_01/sources', seal['preparation_tested_copies_sha256'])
    return seal, plan


def copied_guard(folder: Path, expected: dict) -> None:
    actual = {p.relative_to(folder).as_posix(): sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual == expected, 'tested-copy path set or bytes changed'


def approval_guard(path: Path, expected: str, seal: dict, plan: dict) -> None:
    assert not path.resolve().is_relative_to(ROOT)
    approval = read(path)
    required = dict(schema='anscore-tv-hdl-approval-v1', approved_by='root',
                    source_seal_sha256=expected, source_freeze_sha256=seal['source_freeze_sha256'],
                    finite_plan_sha256=seal['finite_plan_sha256'],
                    preparation_receipt_sha256=sha(ROOT/'preparation/attempt_01/receipt.json'),
                    runtime_record_sha256=sha(ROOT/'prepared/RUNTIME.json'),
                    max_children=26, timeout_seconds_per_tree=20,
                    stop_on_first_failure=True, automatic_retry=False,
                    preparation_reexecution=False, fixed_normal_cases=10,
                    profile_compiles=6, simulations=10, named_parameter_rejects=6)
    assert all(approval.get(key) == value for key, value in required.items())
    assert approval['children'] == plan['children']
    assert approval['path_prefix'] == seal['path_prefix']
    assert len(approval['independent_reviews']) >= 2
    for name, digest in approval['independent_reviews'].items():
        path_review = local(REPO, name)
        assert not path_review.is_relative_to(ROOT) and sha(path_review) == digest


def artifacts_guard(expected: dict) -> None:
    folder = OUT/'artifacts'
    actual = {p.relative_to(folder).as_posix(): sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual == expected, 'fresh generated artifact set/hash changed'


def register_compile(slot: dict, artifacts: dict, seal: dict) -> None:
    path = OUT/'artifacts'/(slot['profile']+'.vvp')
    assert path.name not in artifacts and path.is_file() and path.stat().st_size > 0
    artifacts[path.name] = sha(path)
    slot['generated_artifact'] = dict(path=path.relative_to(ROOT).as_posix(), bytes=path.stat().st_size,
                                      sha256=artifacts[path.name])
    text = path.read_text(encoding='utf-8')
    modules = {str(Path(name).resolve(strict=True)) for name in re.findall(r'^:vpi_module "([^"]+)";', text, re.MULTILINE)}
    assert modules == set(seal['runtime']['runtime_modules_sha256']), 'fresh VVP module closure differs'


def validate_simulation(slot: dict, data: bytes, copies: Path) -> dict:
    """Read every actual input/output/hold/reset tuple against frozen targets."""
    lines = data.decode('utf-8', errors='strict').splitlines()
    finish_pattern = r'.*sim[/\\]tb_tv\.sv:\d+: \$finish called at \d+ \(1ps\)'
    assert len(lines) >= 3
    assert lines[-3] == f"PASS TV profile={slot['profile']} frames={slot['frames']} rows={slot['rows']} reset={slot['reset_job']}"
    assert lines[-2] == 'FINISH TV' and re.fullmatch(finish_pattern, lines[-1])
    assert sum(line.startswith('PASS TV ') for line in lines) == 1
    assert lines.count('FINISH TV') == 1
    assert sum(bool(re.fullmatch(finish_pattern, line)) for line in lines) == 1
    source = read(copies/'fixtures/cases.json')
    cases = {case['name']: case for case in source['cases']}
    certificates = {case['name']: case for case in read(copies/'prepared/CERTIFICATES.json')['cases']}
    profiles = {p['name']: p for p in source['profiles']}
    profile = profiles[slot['profile']]
    n, width, tag_width = profile['N'], profile['DATA_W'], profile['TAG_W']
    reset_job = slot['reset_job']
    is_reset = reset_job != 'NONE'
    reset_at = [i for i, line in enumerate(lines) if line.startswith('RESETAT ')]
    reset_lines = [i for i, line in enumerate(lines) if line.startswith('RESETEDGE ')]
    probe_lines = [i for i, line in enumerate(lines) if line.startswith('PROBE ')]
    if is_reset:
        name = slot['cases'][0]
        assert len(reset_at) == len(probe_lines) == 1 and len(reset_lines) == 3
        at = reset_at[0]
        assert probe_lines[0] == at-1 and reset_lines == [at+1, at+2, at+3]
        assert lines[at] == f'RESETAT {name} {reset_job}'
        assert [lines[i] for i in reset_lines] == [f'RESETEDGE {name} {reset_job} {k}' for k in (1, 2, 3)]
        fields = lines[probe_lines[0]].split()
        states = {'PARTIAL': 0, 'ENVELOPE': 4, 'JUMP': 8, 'HELD_FINAL': 11}
        assert fields == ['PROBE', name, reset_job, str(3 if reset_job == 'PARTIAL' else n), '0', str(states[reset_job])]
        phase_boundary = reset_lines[-1]
    else:
        assert not reset_at and not reset_lines and not probe_lines
        phase_boundary = -1
    inputs = {name: [] for name in slot['cases']}
    outputs = {name: [] for name in slot['cases']}
    holds = {name: [] for name in slot['cases']}
    aborted_inputs, aborted_holds, offers, frames = [], [], [], []
    input_positions = {name: [] for name in slot['cases']}
    output_positions = {name: [] for name in slot['cases']}
    hold_positions = {name: [] for name in slot['cases']}
    frame_positions, offer_positions, partial_next = {}, [], []
    aborted_input_positions, aborted_hold_positions = [], []
    active_order = []
    for position, line in enumerate(lines[:-3]):
        parts = line.split()
        assert parts, 'unexpected empty simulation line'
        kind = parts[0]
        if kind in ('IN', 'REC', 'HOLD'):
            name = parts[1]
            assert name in inputs
            old = is_reset and position < phase_boundary
            if kind == 'IN':
                assert len(parts) == 6
                index, value, penalty, tag = int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5], 16)
                target = certificates[name]
                assert 0 <= index < n and value == target['x'][index]
                expected_penalty = cases[name]['lambda'] if index == 0 else ((1 << width)-1)^cases[name]['lambda']
                base_tag = (((1 << tag_width)-1)^cases[name]['tag']) if old else cases[name]['tag']
                expected_tag = base_tag if index == 0 else ((1 << tag_width)-1)^base_tag
                assert (penalty, tag) == (expected_penalty, expected_tag)
                (aborted_inputs if old else inputs[name]).append(index)
                (aborted_input_positions if old else input_positions[name]).append(position)
            else:
                assert len(parts) == 7
                index, numerator, denominator, tag, last = int(parts[2]), int(parts[3]), int(parts[4]), int(parts[5], 16), int(parts[6])
                assert 0 <= index < n and 1 <= denominator <= n
                a, d = certificates[name]['targets'][index]
                assert numerator*d == a*denominator
                base_tag = (((1 << tag_width)-1)^cases[name]['tag']) if old else cases[name]['tag']
                assert tag == base_tag and last == int(index == n-1)
                if cases[name]['lambda'] == 0 or n == 1:
                    assert denominator == 1
                packet = (index, numerator, denominator, tag, last)
                if old:
                    assert kind == 'HOLD' and reset_job == 'HELD_FINAL'
                    aborted_holds.append(packet)
                    aborted_hold_positions.append(position)
                elif kind == 'REC':
                    outputs[name].append(packet)
                    output_positions[name].append(position)
                    active_order.append(name)
                else:
                    holds[name].append(packet)
                    hold_positions[name].append((position, index))
        elif kind == 'NEXTIN':
            assert len(parts) == 6 and not is_reset and parts[1] in inputs
            name = parts[1]
            assert cases[name]['offer_future'] and name == slot['cases'][-1] and n > 1
            assert tuple(map(int, parts[2:5])) == (0, 0, 0) and int(parts[5], 16) == 0
            partial_next.append((name, position))
        elif kind == 'OFFER':
            assert len(parts) == 3 and parts[1] in inputs and parts[2] == reset_job
            offers.append((parts[1], position < phase_boundary))
            offer_positions.append((parts[1], position, position < phase_boundary))
        elif kind == 'FRAME':
            assert len(parts) == 5 and parts[1] in inputs
            assert parts[2:4] == [str(n), str(n)] and 0 < int(parts[4]) <= (8*n.bit_length()+10)*n*(n+1)//2+6*n+64
            assert not is_reset or position > phase_boundary
            frames.append(parts[1])
            assert parts[1] not in frame_positions
            frame_positions[parts[1]] = position
        elif kind in ('PROBE', 'RESETAT', 'RESETEDGE'):
            assert is_reset
        else:
            raise AssertionError('unexpected nonterminal raw event: '+line)
    assert frames == slot['cases']
    assert active_order == [name for name in slot['cases'] for _ in range(n)]
    for name in slot['cases']:
        assert inputs[name] == list(range(n))
        assert [row[0] for row in outputs[name]] == list(range(n))
        expected_stalls = {index: cycles for index, cycles in cases[name]['stalls']}
        assert {index: sum(row[0] == index for row in holds[name]) for index in expected_stalls} == expected_stalls
        assert all(row[0] in expected_stalls for row in holds[name])
        for held in holds[name]:
            assert held == outputs[name][held[0]], 'held fields differ from retired fields'
        assert max(input_positions[name]) < min(output_positions[name])
        assert max(output_positions[name]) < frame_positions[name]
        for position, index in hold_positions[name]:
            assert max(input_positions[name]) < position < output_positions[name][index]
            if index:
                assert output_positions[name][index-1] < position
    for left, right in zip(slot['cases'], slot['cases'][1:]):
        assert frame_positions[left] < min(input_positions[right]), 'next owner before prior FRAME'
    for name, position, old in offer_positions:
        if old:
            assert reset_job == 'HELD_FINAL'
            assert max(aborted_input_positions) < position < min(aborted_hold_positions)
            assert position < probe_lines[0]
        else:
            assert max(input_positions[name]) < position < output_positions[name][-1]
            if n > 1:
                assert output_positions[name][-2] < position
            final_holds = [at for at, index in hold_positions[name] if index == n-1]
            assert final_holds and position < min(final_holds)
    if is_reset:
        assert aborted_inputs == list(range(3 if reset_job == 'PARTIAL' else n))
        assert max(aborted_input_positions) < probe_lines[0]
        assert phase_boundary < min(input_positions[slot['cases'][0]])
        assert all(max(aborted_input_positions) < at < probe_lines[0] for at in aborted_hold_positions)
        if reset_job == 'HELD_FINAL':
            assert len(aborted_holds) == 2 and aborted_holds[0] == aborted_holds[1]
            assert offers == [(slot['cases'][0], True)]
        else:
            assert not aborted_holds and not offers
        assert not partial_next
    else:
        assert not aborted_inputs and not aborted_holds
        assert offers == [(name, False) for name in slot['cases'] if cases[name]['offer_future']]
        assert [name for name, _ in partial_next] == [name for name in slot['cases'] if cases[name]['offer_future']]
        assert all(frame_positions[name] < position for name, position in partial_next)
    assert len(active_order) == slot['rows']
    return dict(input_records=sum(len(v) for v in inputs.values()), output_records=len(active_order),
                held_records=sum(len(v) for v in holds.values()), aborted_input_records=len(aborted_inputs),
                aborted_held_records=len(aborted_holds), aborted_output_records=0,
                frames=len(frames), reset_edges=len(reset_lines), offers=len(offers),
                partial_next_input_records=len(partial_next))


def archive_failure() -> str:
    target = ROOT/'failure_archive/hdl_01'
    target.mkdir(parents=True, exist_ok=False)
    inventory = {}
    for source in sorted(OUT.rglob('*')):
        if source.is_file():
            name = source.relative_to(ROOT).as_posix()
            destination = local(target, name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
            inventory[name] = sha(destination)
            assert inventory[name] == sha(source)
    write(target/'ARCHIVE.json', dict(status='FAILED_STOPPED_NO_RETRY', original_files_sha256=inventory,
                                    original_receipt_sha256=sha(OUT/'receipt.json')), exclusive=True)
    return sha(target/'ARCHIVE.json')


def run_once(expected: str, approval_path: Path) -> int:
    sys.dont_write_bytecode = True
    seal, plan = guard(expected)
    approval_path = approval_path.resolve(strict=True)
    approval_guard(approval_path, expected, seal, plan)
    approval_hash = sha(approval_path)
    runtime = load_frozen('tv_finite_runtime_guard', ROOT/'sim/runtime.py')
    assert not OUT.exists() and not (ROOT/'failure_archive/hdl_01').exists(), 'exclusive attempt; no retry'
    OUT.mkdir(parents=True, exist_ok=False)
    write(OUT/'LOCK.json', dict(status='STARTED_ONCE', source_seal_sha256=expected,
                             approval_sha256=approval_hash), exclusive=True)
    slots = [dict(copy.deepcopy(child), status='NOT_RUN') for child in plan['children']]
    receipt = dict(schema='anscore-tv-finite-receipt-v1', status='STARTED', children=slots,
                   source_seal_sha256=expected, source_freeze_sha256=seal['source_freeze_sha256'],
                   finite_plan_sha256=seal['finite_plan_sha256'], approval_sha256=approval_hash,
                   preparation_receipt_sha256=sha(ROOT/'preparation/attempt_01/receipt.json'),
                   runtime_record_sha256=sha(ROOT/'prepared/RUNTIME.json'), tools=seal['tools'],
                   path_prefix=seal['path_prefix'], max_children=26, hard_seconds=20,
                   automatic_retry=False, stop_on_first_failure=True,
                   preparation_reexecuted=False, hardware='HW_UNVERIFIED')
    write(OUT/'receipt.json', receipt)
    current = None
    current_started = False
    artifacts = {}
    try:
        copies = OUT/'sources'
        copied = {**seal['source_files_sha256'], **seal['prepared_sha256'],
                  'SOURCE_FREEZE.json': seal['source_freeze_sha256'], 'SOURCE_SEAL.json': expected}
        for name, digest in copied.items():
            destination = local(copies, name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream:
                stream.write(local(ROOT, name).read_bytes())
            assert sha(destination) == digest
        (OUT/'artifacts').mkdir()
        (OUT/'tmp').mkdir()
        copied_guard(copies, copied)
        runtime.verify(seal['runtime'])
        helpers = load_frozen('tv_finite_process_tree', copies/'sim/process_tree.py')
        receipt['tested_copies_sha256'] = copied
        env = {key: os.environ[key] for key in ('SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT') if key in os.environ}
        env.update(PATH=os.pathsep.join(seal['path_prefix']), TEMP=str((OUT/'tmp').resolve()),
                   TMP=str((OUT/'tmp').resolve()), PYTHONDONTWRITEBYTECODE='1',
                   PYTHONNOUSERSITE='1', PYTHONPATH='', PYTHONIOENCODING='utf-8', LANG='C', LC_ALL='C')
        receipt['effective_environment_sha256'] = hashlib.sha256(json.dumps(env, sort_keys=True).encode()).hexdigest()
        for current in slots:
            current_started = False
            guard(expected)
            assert sha(approval_path) == approval_hash
            runtime.verify(seal['runtime'])
            copied_guard(copies, copied)
            artifacts_guard(artifacts)
            if current['kind'] == 'compile':
                assert not (OUT/'artifacts'/(current['profile']+'.vvp')).exists()
            if current['kind'] == 'simulation':
                assert current['profile']+'.vvp' in artifacts
            argv = [seal['tools'][current['tool']]['path']]
            argv += [arg.replace('{ARTIFACT}', str((OUT/'artifacts').resolve())) for arg in current['args']]
            current['argv'] = argv
            current['working_directory'] = str(copies.resolve())
            current_started = True
            result = helpers.execute(argv, copies, env, 20)
            stdout, stderr = result.pop('stdout'), result.pop('stderr')
            current.update(result)
            for stream_name, data in (('stdout', stdout), ('stderr', stderr)):
                path = OUT/(current['name']+'.'+stream_name+'.raw')
                with path.open('xb') as stream:
                    stream.write(data)
                current[stream_name+'_file'] = path.relative_to(ROOT).as_posix()
                current[stream_name+'_sha256'] = sha(path)
                current[stream_name+'_bytes'] = len(data)
            if current['kind'] == 'compile':
                artifact = OUT/'artifacts'/(current['profile']+'.vvp')
                if artifact.exists():
                    current['observed_artifact_sha256'] = sha(artifact)
                    current['observed_artifact_bytes'] = artifact.stat().st_size
            assert not current['timed_out'] and current['failure'] is None
            assert current['process_tree_cleanup'].get('windows_kill_on_close_job_closed') is True
            assert 0 <= current['elapsed_seconds'] < 20
            if current['kind'] == 'reject':
                assert current['returncode'] != 0 and current['named_marker'].encode() in stdout+stderr
                current['status'] = 'EXPECTED_REJECT'
            else:
                assert current['returncode'] == 0
                if current['kind'] in ('compile', 'lint'):
                    assert stdout == stderr == b'', 'unexpected compiler diagnostic'
                    if current['kind'] == 'compile':
                        register_compile(current, artifacts, seal)
                elif current['kind'] == 'certificate':
                    assert stderr == b'' and stdout == current['exact_stdout'].encode()
                elif current['kind'] == 'version':
                    assert b'Icarus Verilog version' in stdout+stderr
                    assert b'Unable to get version' not in stdout+stderr
                elif current['kind'] == 'simulation':
                    assert stderr == b''
                    current['observed_records'] = validate_simulation(current, stdout, copies)
                    assert current['observed_records'] == current['expected_observed_records']
                else:
                    raise AssertionError('unknown child kind')
                current['status'] = 'PASS'
            artifacts_guard(artifacts)
            copied_guard(copies, copied)
            guard(expected)
            runtime.verify(seal['runtime'])
            assert sha(approval_path) == approval_hash
            receipt['generated_artifacts_sha256'] = dict(artifacts)
            write(OUT/'receipt.json', receipt)
        assert len(artifacts) == 6
        receipt.update(status='PASS_FIXED_26', completed_children=26, profile_compiles=6,
                       simulations=10, named_parameter_rejects=6, normal_cases=10,
                       normal_output_rows=162, reset_fresh_output_rows=24,
                       reset_aborted_output_rows=0, generated_artifacts_retained_for_independent_review=True)
        receipt['partial_next_input_records'] = 1
        write(OUT/'receipt.json', receipt)
        print('PASS TV FIXED children=26 compiles=6 simulations=10 rejects=6 HW_UNVERIFIED', flush=True)
        return 0
    except Exception as error:
        if current is not None and current_started:
            current['status'] = 'TIMEOUT' if current.get('timed_out') else 'FAIL'
        failure_phase = current['name'] if current_started else ('metadata_before_'+current['name'] if current else 'metadata_setup')
        receipt.update(status='FAILED_STOPPED', first_failure=failure_phase,
                       failed_during_launched_child=current_started,
                       failure=f'{type(error).__name__}: {error}', generated_artifacts_sha256=dict(artifacts),
                       not_run_children=[child['name'] for child in slots if child['status'] == 'NOT_RUN'])
        write(OUT/'receipt.json', receipt)
        archive_hash = archive_failure()
        print('FAILED_STOPPED TV archive_sha256='+archive_hash+' no_retry=1', flush=True)
        return 1


def main() -> int:
    if sys.flags.optimize:
        raise RuntimeError('optimized Python is forbidden for finite integrity gates')
    if os.name != 'nt':
        raise RuntimeError('this exact finite plan requires Windows process-tree containment')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-source-seal', required=True)
    parser.add_argument('--approval', required=True, type=Path)
    args = parser.parse_args()
    return run_once(args.approved_source_seal, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
