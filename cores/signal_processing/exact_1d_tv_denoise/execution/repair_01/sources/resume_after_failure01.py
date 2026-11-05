"""Separately approved fixed22 after the preserved first HDL failure.

The original seals and evidence remain immutable. Only the explicitly sealed
TB override is compiled anew. No preparation, certificate or model is rerun.
"""
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
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
OUT = ROOT/'execution/repair_01'
ARCHIVE = ROOT/'failure_archive/repair_01'
SEAL_NAME = 'REPAIR_SEAL01.json'
PLAN_NAME = 'REPAIR_PLAN01.json'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_bytes())


def write(path: Path, value: dict, exclusive: bool = False) -> str:
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2)+'\n')
    return sha(path)


def local(base: Path, name: str) -> Path:
    relative = PurePosixPath(name)
    assert name and not relative.is_absolute() and '..' not in relative.parts
    assert '\\' not in name and ':' not in name and not any(c in name for c in '\0\r\n')
    path = base/name
    assert not path.is_symlink() and path.resolve().is_relative_to(base.resolve())
    return path


def file_map(base: Path) -> dict:
    return {p.relative_to(base).as_posix(): sha(p) for p in base.rglob('*') if p.is_file()}


def exact(base: Path, wanted: dict) -> None:
    assert file_map(base) == wanted, 'exact recursive path/hash inventory changed: '+str(base)


def load_frozen(name: str, path: Path):
    assert name not in sys.modules
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def runtime_guard(record: dict, compiler: dict) -> None:
    assert record['schema'] == 'anscore-tv-static-pe-runtime-v1'
    assert len(record['local_pe_graph']) == 62
    for tool in record['tools'].values():
        assert sha(Path(tool['path'])) == tool['sha256'], 'tool bytes changed'
    for field in ('compiler_backend_sha256', 'runtime_modules_sha256',
                  'python_extensions_sha256', 'windows_system_files_sha256'):
        for name, wanted in record[field].items():
            assert sha(Path(name)) == wanted, (field, name)
    for name, node in record['local_pe_graph'].items():
        assert sha(Path(name)) == node['sha256'], 'local PE bytes changed'
    for folder, names in record['dll_directory_names'].items():
        actual = sorted(p.name.lower() for p in Path(folder).iterdir()
                        if p.is_file() and p.suffix.lower() in ('.dll', '.pyd'))
        assert actual == names, 'DLL search-directory inventory changed'
    assert all(Path(folder).is_dir() for folder in record['path_prefix'])
    exact(local(REPO, compiler['directory']),
          {Path(n).relative_to(compiler['directory']).as_posix(): h
           for n, h in compiler['files_sha256'].items()})


def context_guard(digest: str) -> tuple[dict, dict, dict]:
    assert sha(ROOT/SEAL_NAME) == digest, 'approved repair seal changed'
    repair = read(ROOT/SEAL_NAME)
    assert repair['schema'] == 'anscore-tv-source-repair-seal-v1'
    wanted = {**repair['current_package_files_sha256'], SEAL_NAME: digest}
    actual = {n: h for n, h in file_map(ROOT).items()
              if not n.startswith(('execution/repair_01/', 'failure_archive/repair_01/'))}
    assert actual == wanted, 'current source/preparation/parent evidence inventory changed'
    for name, wanted_hash in repair['external_anchors_sha256'].items():
        assert sha(local(REPO, name)) == wanted_hash, name
    preservation = read(local(REPO, repair['preservation_receipt']))
    assert preservation['package_files_sha256'] == repair['preserved_original_package_files_sha256']
    exact(local(REPO, repair['preservation_package']), preservation['package_files_sha256'])
    original = read(ROOT/'SOURCE_SEAL.json')
    freeze = read(ROOT/'SOURCE_FREEZE.json')
    assert original['source_files_sha256'] == freeze['files_sha256']
    preserved = repair['preserved_original_package_files_sha256']
    assert set(repair['current_package_files_sha256'])-set(preserved) == {
        'resume_after_failure01.py', PLAN_NAME}
    assert set(preserved).issubset(repair['current_package_files_sha256'])
    assert {n for n, h in preserved.items()
            if repair['current_package_files_sha256'][n] != h} == {'sim/tb_tv.sv'}
    override = repair['source_override']
    assert override['path'] == 'sim/tb_tv.sv'
    assert override['old_sha256'] == preserved['sim/tb_tv.sv'] == original['source_files_sha256']['sim/tb_tv.sv']
    assert override['new_sha256'] == repair['current_package_files_sha256']['sim/tb_tv.sv']
    for name, key in [('execution/attempt_01/receipt.json', 'receipt_sha256'),
                      ('failure_archive/hdl_01/ARCHIVE.json', 'archive_sha256'),
                      ('preparation/attempt_01/receipt.json', 'preparation_receipt_sha256'),
                      ('FINITE_PLAN.json', 'finite_plan_sha256')]:
        assert sha(ROOT/name) == repair['parent'][key]
    assert original['source_freeze_sha256'] == repair['parent']['source_freeze_sha256']
    assert original['runtime'] == read(ROOT/'prepared/RUNTIME.json')
    assert original['tools'] == original['runtime']['tools']
    assert original['path_prefix'] == original['runtime']['path_prefix']
    assert sha(ROOT/'SOURCE_SEAL.json') == repair['parent']['source_seal_sha256']
    assert sha(ROOT/'SOURCE_FREEZE.json') == repair['parent']['source_freeze_sha256']
    assert sha(ROOT/'prepared/RUNTIME.json') == repair['parent']['runtime_record_sha256']
    exact(ROOT/'prepared', {Path(n).relative_to('prepared').as_posix(): h
                            for n, h in original['prepared_sha256'].items()})
    preparation = read(ROOT/'preparation/attempt_01/receipt.json')
    assert preparation['status'] == 'PASS_FIXED_PREPARATION_ONLY'
    assert preparation['preparation_invocations'] == 1
    assert preparation['source_seal_sha256'] == repair['parent']['source_seal_sha256']
    assert preparation['prepared_sha256'] == original['prepared_sha256']
    assert preparation['tested_copies_sha256'] == original['preparation_tested_copies_sha256']
    exact(ROOT/'preparation/attempt_01/sources', original['preparation_tested_copies_sha256'])
    parent = read(ROOT/'execution/attempt_01/receipt.json')
    assert parent['status'] == 'FAILED_STOPPED' and parent['first_failure'] == 'normal_p0'
    assert [c['status'] for c in parent['children']] == ['PASS']*10+['FAIL']+['NOT_RUN']*15
    assert parent['source_seal_sha256'] == repair['parent']['source_seal_sha256']
    old_plan = read(ROOT/'FINITE_PLAN.json')
    plan = read(ROOT/PLAN_NAME)
    assert sha(ROOT/PLAN_NAME) == repair['repair_plan_sha256']
    assert plan['schema'] == 'anscore-tv-fixed22-repair-plan-v1'
    assert plan['children'] == old_plan['children'][4:]
    assert plan['carried_children'] == old_plan['children'][:4]
    assert len(plan['children']) == plan['max_new_children'] == 22
    assert len({c['name'] for c in plan['children']}) == 22
    assert [c['kind'] for c in plan['children']] == ['compile']*6+['simulation']*10+['reject']*6
    assert all(c['hard_seconds'] == 20 for c in plan['children'])
    assert plan['automatic_retry'] is False and plan['stop_on_first_failure'] is True
    assert plan['preparation_reexecution'] is False and plan['certificate_reexecution'] is False
    for previous, declared in zip(parent['children'][:4], plan['carried_children']):
        assert all(previous[k] == value for k, value in declared.items())
        assert previous['status'] == 'PASS' and previous['returncode'] == 0
        assert not previous['timed_out'] and previous['failure'] is None
    runtime_guard(original['runtime'], repair['compiler_inventory'])
    assert sha(ROOT/SEAL_NAME) == digest
    return repair, plan, original


def approval_guard(path: Path, expected: str, repair: dict, plan: dict) -> str:
    assert path.is_relative_to((REPO/'.git').resolve()) and not path.is_relative_to(ROOT)
    approval = read(path)
    required = dict(schema='anscore-tv-repair-hdl-approval-v1', approved_by='root',
                    repair_seal_sha256=expected, repair_plan_sha256=repair['repair_plan_sha256'],
                    parent_receipt_sha256=repair['parent']['receipt_sha256'],
                    parent_archive_sha256=repair['parent']['archive_sha256'],
                    original_source_seal_sha256=repair['parent']['source_seal_sha256'],
                    original_source_freeze_sha256=repair['parent']['source_freeze_sha256'],
                    preparation_receipt_sha256=repair['parent']['preparation_receipt_sha256'],
                    runtime_record_sha256=repair['parent']['runtime_record_sha256'],
                    max_invocations=1, max_children=22, hard_seconds_per_tree=20,
                    automatic_retry=False, stop_on_first_failure=True,
                    preparation_reexecution=False, certificate_reexecution=False,
                    numerical_model_reexecution=False, carried_children=4,
                    profile_compiles=6, simulations=10, named_parameter_rejects=6)
    assert all(approval.get(k) == value for k, value in required.items()), 'exact repair approval required'
    assert approval['children'] == plan['children']
    assert approval['path_prefix'] == repair['path_prefix']
    assert len(approval['independent_reviews']) >= 2
    for name, wanted in approval['independent_reviews'].items():
        review = local(REPO, name)
        assert not review.is_relative_to(ROOT) and sha(review) == wanted
    return sha(path)


def checkpoint(digest: str, approval_path: Path, approval_hash: str,
               copies: dict, artifacts: dict, retained: dict, receipt_hash: str) -> None:
    repair, plan, _ = context_guard(digest)
    assert approval_guard(approval_path, digest, repair, plan) == approval_hash
    exact(OUT/'sources', copies)
    exact(OUT/'artifacts', artifacts)
    expected = {'receipt.json': receipt_hash, **retained,
                **{'sources/'+n: h for n, h in copies.items()},
                **{'artifacts/'+n: h for n, h in artifacts.items()}}
    actual = {n: h for n, h in file_map(OUT).items() if not n.startswith('tmp/')}
    assert actual == expected, 'new receipt/raw/approval/review/copy/artifact evidence changed'


def archive_failure(receipt: dict) -> str:
    ARCHIVE.mkdir(parents=True, exist_ok=False)
    inventory = {}
    originals = [p for p in ROOT.rglob('*') if p.is_file() and not p.is_relative_to(ARCHIVE)]
    for source in sorted(originals):
        name = source.relative_to(ROOT).as_posix()
        destination = local(ARCHIVE, name)
        destination.parent.mkdir(parents=True, exist_ok=True)
        data = source.read_bytes()
        with destination.open('xb') as stream:
            stream.write(data)
        inventory[name] = sha(destination)
        assert inventory[name] == hashlib.sha256(data).hexdigest() == sha(source)
    archive = dict(schema='anscore-tv-repair-failure-archive-v1', status='FAILED_STOPPED_NO_RETRY',
                   original_files_sha256=inventory, terminal_receipt_sha256=sha(OUT/'receipt.json'),
                   parent_receipt_sha256=receipt['parent_receipt_sha256'], automatic_retry=False)
    write(ARCHIVE/'ARCHIVE.json', archive, exclusive=True)
    exact(ARCHIVE, {**inventory, 'ARCHIVE.json': sha(ARCHIVE/'ARCHIVE.json')})
    return sha(ARCHIVE/'ARCHIVE.json')


def run_once(digest: str, approval_path: Path) -> int:
    sys.dont_write_bytecode = True
    repair, plan, original = context_guard(digest)
    approval_path = approval_path.resolve(strict=True)
    approved = approval_guard(approval_path, digest, repair, plan)
    assert not OUT.exists() and not ARCHIVE.exists(), 'exclusive separate repair attempt; no retry'
    copies = {**repair['tested_input_files_sha256'], SEAL_NAME: digest}
    slots = [dict(copy.deepcopy(c), status='NOT_RUN', launched=False) for c in plan['children']]
    receipt = dict(schema='anscore-tv-repair-finite-receipt-v1', status='STARTED', children=slots,
                   repair_seal_sha256=digest, repair_plan_sha256=repair['repair_plan_sha256'],
                   approval_sha256=approved, parent_receipt_sha256=repair['parent']['receipt_sha256'],
                   parent_archive_sha256=repair['parent']['archive_sha256'],
                   original_source_seal_sha256=repair['parent']['source_seal_sha256'],
                   preparation_receipt_sha256=repair['parent']['preparation_receipt_sha256'],
                   runtime_record_sha256=repair['parent']['runtime_record_sha256'],
                   carried_children=copy.deepcopy(read(ROOT/'execution/attempt_01/receipt.json')['children'][:4]),
                   superseded_parent_compiles=[c['name'] for c in plan['children'][:6]],
                   parent_failed_simulation='normal_p0 remains FAIL in immutable parent receipt',
                   tested_copies_sha256=copies, generated_artifacts_sha256={}, retained_evidence_sha256={},
                   max_children=22, hard_seconds=20, automatic_retry=False, stop_on_first_failure=True,
                   preparation_reexecuted=False, certificate_reexecuted=False, numerical_model_reexecuted=False,
                   completed_children=0, hardware='HW_UNVERIFIED')
    current = None; phase = 'initial_receipt'; raw = {}; artifacts = {}; retained = {}
    OUT.mkdir(parents=True, exist_ok=False)
    try:
        receipt_hash = write(OUT/'receipt.json', receipt, exclusive=True)
        write(OUT/'LOCK.json', dict(status='ONE_SEPARATE_REPAIR_STARTED', repair_seal_sha256=digest,
                                   approval_sha256=approved), exclusive=True)
        retained['LOCK.json'] = sha(OUT/'LOCK.json')
        phase = 'copy_setup'
        (OUT/'sources').mkdir(); (OUT/'artifacts').mkdir(); (OUT/'tmp').mkdir()
        for name, wanted in copies.items():
            destination = local(OUT/'sources', name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream:
                stream.write(local(ROOT, name).read_bytes())
            assert sha(destination) == wanted
        with (OUT/'approval.json').open('xb') as stream:
            stream.write(approval_path.read_bytes())
        retained['approval.json'] = approved
        for index, (name, wanted) in enumerate(read(approval_path)['independent_reviews'].items()):
            path = OUT/('review_'+str(index)+'.json')
            with path.open('xb') as stream:
                stream.write(local(REPO, name).read_bytes())
            assert sha(path) == wanted; retained[path.name] = wanted
        checkpoint(digest, approval_path, approved, copies, artifacts, retained, receipt_hash)
        phase = 'guarded_helper_imports'
        helpers = load_frozen('tv_repair01_process_tree', OUT/'sources/sim/process_tree.py')
        validator = load_frozen('tv_repair01_original_raw_validator', OUT/'sources/run_tests.py')
        env = {k: os.environ[k] for k in ('SystemRoot', 'WINDIR', 'COMSPEC', 'PATHEXT') if k in os.environ}
        env.update(PATH=os.pathsep.join(repair['path_prefix']), TEMP=str((OUT/'tmp').resolve()),
                   TMP=str((OUT/'tmp').resolve()), PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
                   PYTHONPATH='', PYTHONIOENCODING='utf-8', LANG='C', LC_ALL='C')
        receipt['effective_environment_sha256'] = hashlib.sha256(json.dumps(env, sort_keys=True).encode()).hexdigest()
        receipt['retained_evidence_sha256'] = dict(retained)
        receipt_hash = write(OUT/'receipt.json', receipt)
        for slot in slots:
            current = None; raw = {}; phase = 'pre_checkpoint:'+slot['name']
            checkpoint(digest, approval_path, approved, copies, artifacts, retained, receipt_hash)
            if slot['kind'] == 'compile':
                assert not (OUT/'artifacts'/(slot['profile']+'.vvp')).exists()
            if slot['kind'] == 'simulation':
                assert set(artifacts) == {c['profile']+'.vvp' for c in plan['children'][:6]}
            current = slot; phase = 'child:'+slot['name']
            slot['argv'] = [original['tools'][slot['tool']]['path']]+[
                a.replace('{ARTIFACT}', str((OUT/'artifacts').resolve())) for a in slot['args']]
            slot['working_directory'] = str((OUT/'sources').resolve())
            slot['launched'] = True; slot['status'] = 'RUNNING'
            receipt_hash = write(OUT/'receipt.json', receipt)
            result = helpers.execute(slot['argv'], OUT/'sources', env, 20)
            raw = {stream: result.pop(stream) for stream in ('stdout', 'stderr')}
            slot.update(result); phase = 'raw_persistence:'+slot['name']
            for stream, data in raw.items():
                path = OUT/(slot['name']+'.'+stream+'.raw')
                with path.open('xb') as output:
                    output.write(data)
                slot[stream+'_file'] = path.relative_to(ROOT).as_posix()
                slot[stream+'_sha256'] = sha(path); slot[stream+'_bytes'] = len(data)
                retained[path.name] = sha(path)
            candidate = dict(artifacts)
            if slot['kind'] == 'compile':
                path = OUT/'artifacts'/(slot['profile']+'.vvp')
                if path.is_file():
                    candidate[path.name] = sha(path)
                    slot['observed_artifact'] = dict(name=path.name, sha256=sha(path), bytes=path.stat().st_size)
            phase = 'post_checkpoint:'+slot['name']
            checkpoint(digest, approval_path, approved, copies, candidate, retained, receipt_hash)
            phase = 'validation:'+slot['name']
            assert not slot['timed_out'] and slot['failure'] is None
            assert slot['process_tree_cleanup'].get('windows_kill_on_close_job_closed') is True
            assert 0 <= slot['elapsed_seconds'] < 20
            if slot['kind'] == 'reject':
                assert slot['returncode'] is not None and 0 < slot['returncode'] < 128
                assert slot['named_marker'].encode() in raw['stdout']+raw['stderr']
                status = 'EXPECTED_REJECT'
            else:
                assert slot['returncode'] == 0 and raw['stderr'] == b''
                if slot['kind'] == 'compile':
                    assert raw['stdout'] == b'' and slot['observed_artifact']['bytes'] > 0
                    path = OUT/'artifacts'/(slot['profile']+'.vvp')
                    modules = {str(Path(n).resolve(strict=True)) for n in re.findall(
                        r'^:vpi_module "([^"]+)";', path.read_text('utf-8'), re.MULTILINE)}
                    assert modules == set(original['runtime']['runtime_modules_sha256'])
                    slot['generated_artifact'] = dict(slot['observed_artifact'])
                elif slot['kind'] == 'simulation':
                    observed = validator.validate_simulation(slot, raw['stdout'], OUT/'sources')
                    assert observed == slot['expected_observed_records']
                    slot['observed_records'] = observed
                else:
                    raise AssertionError('only fixed compile/simulation/reject children permitted')
                status = 'PASS'
            phase = 'post_validation_checkpoint:'+slot['name']
            checkpoint(digest, approval_path, approved, copies, candidate, retained, receipt_hash)
            artifacts.clear(); artifacts.update(candidate); slot['status'] = status
            receipt['generated_artifacts_sha256'] = dict(artifacts)
            receipt['retained_evidence_sha256'] = dict(retained)
            receipt['completed_children'] = sum(c['launched'] for c in slots)
            receipt_hash = write(OUT/'receipt.json', receipt)
        current = None; phase = 'final_checkpoint'
        checkpoint(digest, approval_path, approved, copies, artifacts, retained, receipt_hash)
        assert len(artifacts) == 6 and len(slots) == 22
        assert sum(c['status'] == 'PASS' for c in slots) == 16
        assert sum(c['status'] == 'EXPECTED_REJECT' for c in slots) == 6
        receipt.update(status='PASS_REPAIRED_FIXED_26', new_children=22, carried_successful_children=4,
                       qualified_children=26, profile_compiles=6, simulations=10, named_parameter_rejects=6,
                       normal_cases=10, normal_output_rows=162, reset_fresh_output_rows=24,
                       partial_next_input_records=1, generated_artifacts_retained_for_independent_review=True)
        write(OUT/'receipt.json', receipt)
        print('PASS TV REPAIR01 new_children=22 carried=4 qualified=26 HW_UNVERIFIED', flush=True)
        return 0
    except Exception as error:
        if current is not None and current['launched']:
            current['status'] = 'TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED', failure_phase=phase,
                       first_failure=None if current is None else current['name'],
                       failure=f'{type(error).__name__}: {error}',
                       completed_children=sum(c['launched'] for c in slots),
                       not_run_children=[c['name'] for c in slots if c['status'] == 'NOT_RUN'],
                       generated_artifacts_sha256=dict(artifacts), retained_evidence_sha256=dict(retained))
        if current is not None:
            for stream, data in raw.items():
                path = OUT/(current['name']+'.'+stream+'.raw')
                if not path.exists():
                    try:
                        with path.open('xb') as output:
                            output.write(data)
                    except Exception as persistence_error:
                        receipt.setdefault('raw_persistence_errors', {})[stream] = str(persistence_error)
        try:
            receipt['observed_attempt_files_sha256'] = file_map(OUT)
            write(OUT/'receipt.json', receipt)
        except Exception as persistence_error:
            receipt['terminal_receipt_error'] = str(persistence_error)
        try:
            archive_hash = archive_failure(receipt)
            print('FAILED_STOPPED TV REPAIR01 archive_sha256='+archive_hash+' no_retry=1', flush=True)
        except Exception as archive_error:
            receipt['archive_error'] = str(archive_error)
            try:
                write(OUT/'receipt.json', receipt)
            except Exception:
                pass
            print('FAILED_STOPPED TV REPAIR01 originals_retained archive_failed no_retry=1', flush=True)
        return 1


def main() -> int:
    if sys.flags.optimize or os.name != 'nt':
        raise RuntimeError('unoptimized Python on Windows is required')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-repair-seal', required=True)
    parser.add_argument('--approval', required=True, type=Path)
    args = parser.parse_args()
    return run_once(args.approved_repair_seal, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
