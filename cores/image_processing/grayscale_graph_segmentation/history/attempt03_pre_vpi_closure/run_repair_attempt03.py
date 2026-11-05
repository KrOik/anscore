"""Separately approved PATH-only continuation of the final 23 original children.

Reuse the six successful attempt_02 VVP artifacts byte for byte. Never repeat
profile compilation, preparation, oracle verification, or the first four PASS
checks. The two failed attempts and both complete archives remain immutable.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PLAN = ROOT / 'REPAIR_PLAN_ATTEMPT03.json'
SEAL = ROOT / 'REPAIR_SEAL_ATTEMPT03.json'
OUT = ROOT / 'evidence/attempt_03'
TB = 'sim/tb_grayscale_graph_segmentation.sv'
HARD_SECONDS = 20
ORIGINAL_SEAL = '015df1ae9a19644b6dcc88ae333e4cc05e396a9930103fdd0fd039b345b34077'
FIRST_RECEIPT = '8ec0fdd87081b5c1c4075510e3c9cbafb634d4dd3a62e433a296767337dad52f'
FIRST_ARCHIVE = 'ec38eb85352dcb64110ccbc862bf2ea19a93258080776ee41abff8fbacb1562a'
SECOND_SEAL = '28222a72139356e613ae4b12636961c66c418f0fbeb8dc1b92a4772e320b4a04'
SECOND_RECEIPT = '685a379cb526ceeb4e386b93bf6d961236f82969e87895c23a5f6b3f51538b04'
SECOND_ARCHIVE = '9adc9c003ef591794e2f33bfb5589aba305b6dc18b6eafe006519c69bfb92b28'


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path: Path) -> dict:
    return json.loads(path.read_bytes())


def write(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8', newline='\n')


def local(base: Path, relative: str) -> Path:
    path = (base / relative).resolve()
    assert path.is_relative_to(base.resolve()), 'input path escapes its sealed base'
    return path


def archive_guard(attempt: str, digest: str, count: int, overrides: dict) -> dict:
    folder = ROOT/'failure_archive'/attempt
    assert sha(folder/'ARCHIVE.json') == digest, 'historical archive manifest changed'
    manifest = read(folder/'ARCHIVE.json')
    files = manifest['original_files_sha256']
    assert manifest['files'] == len(files) == count
    actual = {p.relative_to(folder).as_posix() for p in folder.rglob('*') if p.is_file()}
    assert actual == set(files) | {'ARCHIVE.json'}, 'historical archive inventory changed'
    for relative, expected in files.items():
        assert sha(local(folder, relative)) == expected, 'historical archive bytes changed'
        assert sha(local(ROOT, relative)) == overrides.get(relative, expected), 'protected parent bytes changed'
    return manifest


def guard(approved_seal: str) -> tuple[dict, dict]:
    assert sha(SEAL) == approved_seal, 'exact separately approved attempt_03 seal required'
    seal, plan = read(SEAL), read(PLAN)
    assert seal['schema'] == 'b28-c-repair03-source-seal-v1'
    assert sha(PLAN) == seal['repair_plan_sha256']
    assert sha(ROOT/'SOURCE_SEAL.json') == ORIGINAL_SEAL
    assert sha(ROOT/'evidence/attempt_01/receipt.json') == FIRST_RECEIPT
    assert sha(ROOT/'REPAIR_SEAL_ATTEMPT02.json') == SECOND_SEAL
    assert sha(ROOT/'evidence/attempt_02/receipt.json') == SECOND_RECEIPT
    for anchor in seal['parent_evidence_dag'].values():
        base = REPO if anchor['base'] == 'repo' else ROOT
        assert sha(local(base, anchor['path'])) == anchor['sha256'], 'parent DAG changed'
    old = read(ROOT/'SOURCE_SEAL.json')
    first = read(ROOT/'evidence/attempt_01/receipt.json')
    second = read(ROOT/'evidence/attempt_02/receipt.json')
    previous = read(ROOT/'REPAIR_SEAL_ATTEMPT02.json')
    assert first['status'] == 'FAILED_STOPPED' and first['first_failure'] == 'compile_p0'
    assert [c['status'] for c in first['children']] == ['PASS']*4 + ['FAIL'] + ['NOT_RUN']*28
    assert second['status'] == 'FAILED_STOPPED' and second['first_failure'] == 'main_p0_0'
    assert [c['status'] for c in second['children']] == ['PASS']*6 + ['FAIL'] + ['NOT_RUN']*22
    assert second['children'][6]['returncode'] == 3221225781
    assert second['children'][6]['stdout_bytes'] == second['children'][6]['stderr_bytes'] == 0
    assert seal['source_overrides'] == {}, 'attempt_03 must not alter HDL or numerical inputs'
    assert seal['inherited_source_overrides'] == previous['source_overrides']
    assert set(previous['source_overrides']) == {TB}
    tb_hash = previous['source_overrides'][TB]['to_sha256']
    assert sha(ROOT/TB) == tb_hash
    archive_guard('attempt_01', FIRST_ARCHIVE, 135, {TB: tb_hash})
    archived = archive_guard('attempt_02', SECOND_ARCHIVE, 84, {})
    actual_second = {p.relative_to(ROOT).as_posix() for p in (ROOT/'evidence/attempt_02').rglob('*') if p.is_file()}
    assert actual_second == set(archived['original_files_sha256']), 'attempt_02 inventory changed'
    assert plan['children'] == old['children'][10:]
    assert len(plan['children']) == 23
    assert sum(c['kind'] == 'simulation' for c in plan['children']) == 17
    assert sum(c['kind'] == 'reject' for c in plan['children']) == 6
    assert all(c['kind'] in ('simulation', 'reject') and c['hard_seconds'] == 20 for c in plan['children'])
    assert plan['omitted_previously_passed'] == [c['name'] for c in old['children'][:10]]
    assert plan['profile_compilation_rerun'] is plan['numerical_preparation_rerun'] is plan['oracle_rerun'] is False
    assert plan['max_children'] == 23 and plan['automatic_retry'] is False and plan['stop_on_first_failure'] is True
    assert plan['timeout_seconds_per_tree'] == HARD_SECONDS
    expected_inputs = dict(second['tested_copies_sha256'])
    expected_inputs['run_repair_attempt03.py'] = seal['copy_inputs']['run_repair_attempt03.py']
    expected_inputs[PLAN.name] = seal['repair_plan_sha256']
    assert len(expected_inputs) == 64 and seal['copy_inputs'] == expected_inputs
    for relative, digest in seal['copy_inputs'].items():
        assert sha(local(ROOT, relative)) == digest, 'attempt_03 source/fixture changed'
    assert seal['tools'] == old['tools'] and seal['external_sources'] == old['external_sources']
    for tool in seal['tools'].values():
        assert sha(Path(tool['path'])) == tool['sha256'], 'tool changed'
    for relative, digest in seal['external_sources'].items():
        assert sha(local(REPO, relative)) == digest, 'external DSU changed'
    dependency = read(ROOT/'DEPENDENCIES.json')
    assert sha(local(REPO, dependency['baseline_manifest'])) == dependency['baseline_manifest_sha256']
    suite = Path(seal['tools']['VVP']['path']).parent.parent
    assert seal['path_prefix'] == plan['path_prefix'] == [str(suite/'bin'), str(suite/'lib')]
    assert all(Path(p).is_dir() for p in seal['path_prefix'])
    diagnosis = read(REPO/'.git/b28-c-own-failure-review02.json')
    dlls = {p: v['sha256'] for p, v in diagnosis['runtime_environment_finding']['static_PE_import_graph'].items() if p.lower().endswith('.dll')}
    assert seal['runtime_dlls'] == dlls and len(dlls) == 6
    for relative, digest in dlls.items():
        assert sha(local(REPO, relative)) == digest, 'runtime DLL changed'
    expected_artifacts = {f'p{i}.vvp' for i in range(6)}
    assert set(seal['compiled_artifacts']) == expected_artifacts
    assert plan['compiled_artifacts'] == seal['compiled_artifacts']
    modules = set()
    for index, name in enumerate(f'p{i}.vvp' for i in range(6)):
        entry = seal['compiled_artifacts'][name]
        assert entry['source'] == f'evidence/attempt_02/artifacts/{name}'
        assert entry['compile_child'] == f'compile_p{index}'
        assert entry['sha256'] == archived['original_files_sha256'][entry['source']]
        assert sha(local(ROOT, entry['source'])) == entry['sha256'], 'compiled parent artifact changed'
        child = second['children'][index]
        assert child['name'] == entry['compile_child'] and child['status'] == 'PASS' and child['returncode'] == 0
        assert child['plan_argv'] == old['children'][index+4]['argv']
        assert child['timed_out'] is False and child['failure'] is None
        assert child['stdout_bytes'] == child['stderr_bytes'] == 0
        modules.update(Path(p).resolve() for p in re.findall(r'^:vpi_module "([^"]+)";', local(ROOT, entry['source']).read_text(encoding='utf-8'), re.MULTILINE))
    expected_modules = {p.relative_to(REPO).as_posix() for p in modules}
    assert set(seal['runtime_modules']) == expected_modules and len(expected_modules) == 6
    for relative, digest in seal['runtime_modules'].items():
        assert sha(local(REPO, relative)) == digest, 'embedded VPI runtime module changed'
    return seal, plan


def approval_guard(path: Path, approved_seal: str, seal: dict, plan: dict) -> str:
    path = path.resolve()
    assert not path.is_relative_to(ROOT), 'root approval must be external to package'
    approval = read(path)
    required = dict(schema='anscore-root-exact-c-repair03-hdl-v1', approved_by='root',
        attempt='attempt_03', repair_seal_sha256=approved_seal, repair_plan_sha256=sha(PLAN),
        original_source_seal_sha256=ORIGINAL_SEAL, original_failure_receipt_sha256=FIRST_RECEIPT,
        original_failure_archive_sha256=FIRST_ARCHIVE, previous_repair_seal_sha256=SECOND_SEAL,
        previous_failure_receipt_sha256=SECOND_RECEIPT, previous_failure_archive_sha256=SECOND_ARCHIVE,
        max_children=23, timeout_seconds_per_tree=20, stop_on_first_failure=True,
        automatic_retry=False, profile_compilation_rerun=False, numerical_preparation_rerun=False,
        oracle_rerun=False)
    assert all(approval.get(k) == v for k, v in required.items()), 'attempt_03 approval mismatch'
    assert approval['children'] == plan['children'], 'approval must enumerate exact 23 children'
    assert approval['compiled_artifacts'] == seal['compiled_artifacts'], 'approval must bind six reused VVP artifacts'
    assert approval['path_prefix'] == seal['path_prefix'], 'approval must bind bin+lib PATH prefix'
    assert len(approval['static_reviews']) >= 2, 'independent A/B static reviews required'
    for relative, digest in approval['static_reviews'].items():
        review = local(REPO, relative)
        assert not review.is_relative_to(ROOT) and sha(review) == digest
    return sha(path)


def copies_guard(copies: Path, hashes: dict) -> None:
    actual = {p.relative_to(copies).as_posix(): sha(p) for p in copies.rglob('*') if p.is_file()}
    assert actual == hashes, 'frozen tested-copy set/hash changed'


def artifacts_guard(hashes: dict) -> None:
    folder = OUT/'artifacts'
    actual = {p.relative_to(folder).as_posix(): sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual == hashes, 'reused artifact set/hash changed'


def load_reviewed_helpers(copies: Path):
    # Future approved runtime only: import frozen original helpers, no oracle/preparation.
    assert 'process_tree' not in sys.modules, 'unexpected preloaded process helper'
    sys.dont_write_bytecode = True
    previous = list(sys.path)
    try:
        sys.path.insert(0, str(copies))
        spec = importlib.util.spec_from_file_location('b28_c_attempt03_original_runner', copies/'run_tests.py')
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    assert module.ROOT == copies
    assert Path(sys.modules['process_tree'].__file__).resolve() == (copies/'process_tree.py').resolve()
    return module


def invoke(slot: dict, helpers, copies: Path, env: dict) -> None:
    assert slot['kind'] in ('simulation', 'reject'), 'no profile recompilation in attempt_03'
    argv = [arg.replace('{ARTIFACT}', str((OUT/'artifacts').resolve())) for arg in slot['plan_argv']]
    slot['working_directory'] = str(copies.resolve())
    result = helpers.execute(argv, copies, env, HARD_SECONDS)
    raw_out, raw_err = result.pop('stdout'), result.pop('stderr')
    for stream, raw in [('stdout', raw_out), ('stderr', raw_err)]:
        path = OUT/(slot['name']+'.'+stream+'.raw')
        with path.open('xb') as output:
            output.write(raw)
        slot[stream+'_file'] = path.relative_to(ROOT).as_posix()
        slot[stream+'_sha256'] = sha(path)
        slot[stream+'_bytes'] = len(raw)
    slot.update(result)
    assert not slot['timed_out'] and slot['failure'] is None, 'process-tree failure or timeout'
    assert 0 <= slot['elapsed_seconds'] < HARD_SECONDS, 'hard20s elapsed bound'
    if slot['kind'] == 'reject':
        lines = (raw_out+raw_err).decode('utf-8', errors='strict').splitlines()
        assert slot['returncode'] != 0 and any('grayscale_graph_segmentation_invalid_parameters__see_README' in line for line in lines), 'missing named reject'
        slot['status'] = 'EXPECTED_REJECT'
        return
    assert slot['returncode'] == 0, f'child returncode {slot["returncode"]}'
    assert raw_err == b'', 'unexpected simulator stderr'
    helpers.validate_simulation(slot, raw_out.decode('utf-8', errors='strict').splitlines())
    slot['status'] = 'PASS'


def archive_failure() -> str:
    target = ROOT/'failure_archive/attempt_03'
    target.mkdir(exist_ok=False)
    inventory = {}
    for source in sorted(OUT.rglob('*')):
        if source.is_file():
            relative = source.relative_to(ROOT).as_posix()
            dest = local(target, relative)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
            inventory[relative] = sha(dest)
            assert inventory[relative] == sha(source), 'failure archive copy mismatch'
    write(target/'ARCHIVE.json', dict(schema=1, status='FAILED_STOPPED_NO_RETRY',
        files=len(inventory), original_files_sha256=inventory,
        original_receipt_sha256=sha(OUT/'receipt.json'), original_parent_archive_sha256=SECOND_ARCHIVE,
        first_parent_archive_sha256=FIRST_ARCHIVE, automatic_retry=False))
    return sha(target/'ARCHIVE.json')


def run_once(approved_seal: str, approval_path: Path) -> int:
    # These checks must survive -O/PYTHONOPTIMIZE before any assertion-based gate.
    if sys.flags.optimize != 0:
        raise RuntimeError('optimized Python is forbidden for assertion-based approval gates')
    if os.name != 'nt':
        raise RuntimeError('this separately approved attempt requires Windows process-tree control')
    seal, plan = guard(approved_seal)
    approval_sha = approval_guard(approval_path, approved_seal, seal, plan)
    assert not OUT.exists() and not (ROOT/'failure_archive/attempt_03').exists(), 'one exclusive attempt; never retry'
    OUT.mkdir(parents=True, exist_ok=False)
    write(OUT/'LOCK.json', dict(schema=1, status='STARTED_ONCE', attempt='attempt_03',
        repair_seal_sha256=approved_seal, approval_sha256=approval_sha))
    slots = []
    for original in plan['children']:
        slot = copy.deepcopy(original)
        slot['plan_argv'] = slot.pop('argv')
        slot['status'] = 'NOT_RUN'
        slots.append(slot)
    receipt = dict(schema=1, status='STARTED', attempt='attempt_03',
        repair_seal_sha256=approved_seal, repair_plan_sha256=sha(PLAN), approval_sha256=approval_sha,
        original_source_seal_sha256=ORIGINAL_SEAL, original_failure_receipt_sha256=FIRST_RECEIPT,
        original_failure_archive_sha256=FIRST_ARCHIVE, previous_repair_seal_sha256=SECOND_SEAL,
        previous_failure_receipt_sha256=SECOND_RECEIPT, previous_failure_archive_sha256=SECOND_ARCHIVE,
        original_preparation_receipt_sha256=seal['parent_evidence_dag']['preparation_receipt']['sha256'],
        omitted_previously_passed=plan['omitted_previously_passed'], children=slots,
        source_overrides={}, inherited_source_overrides=seal['inherited_source_overrides'],
        hard_seconds=20, automatic_retry=False, stop_on_first_failure=True,
        profile_compilation_rerun=False, numerical_preparation_rerun=False, oracle_rerun=False,
        compiled_artifact_provenance=seal['compiled_artifacts'], path_prefix=seal['path_prefix'],
        runtime_dlls=seal['runtime_dlls'], runtime_modules=seal['runtime_modules'], hardware='HW_UNVERIFIED')
    write(OUT/'receipt.json', receipt)
    current = None
    try:
        copies = OUT/'sources'
        hashes = dict(seal['copy_inputs'], **{SEAL.name: approved_seal})
        for relative, digest in hashes.items():
            target = local(copies, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as destination:
                destination.write(local(ROOT, relative).read_bytes())
            assert sha(target) == digest
        (OUT/'artifacts').mkdir()
        artifact_hashes = {}
        for name, entry in seal['compiled_artifacts'].items():
            target = OUT/'artifacts'/name
            with target.open('xb') as destination:
                destination.write(local(ROOT, entry['source']).read_bytes())
            assert sha(target) == entry['sha256']
            artifact_hashes[name] = entry['sha256']
        receipt['tested_copies_sha256'] = hashes
        receipt['reused_artifacts_sha256'] = artifact_hashes
        copies_guard(copies, hashes)
        artifacts_guard(artifact_hashes)
        helpers = load_reviewed_helpers(copies)
        copies_guard(copies, hashes)
        env = os.environ.copy()
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        env['PYTHONIOENCODING'] = 'utf-8'
        inherited_path = env.get('PATH', '')
        env['PATH'] = os.pathsep.join(seal['path_prefix']) + (os.pathsep+inherited_path if inherited_path else '')
        receipt['inherited_PATH_sha256'] = hashlib.sha256(inherited_path.encode('utf-8')).hexdigest()
        receipt['effective_PATH_sha256'] = hashlib.sha256(env['PATH'].encode('utf-8')).hexdigest()
        write(OUT/'receipt.json', receipt)
        for current in slots:
            guard(approved_seal)
            assert sha(approval_path.resolve()) == approval_sha, 'approval changed'
            copies_guard(copies, hashes)
            artifacts_guard(artifact_hashes)
            invoke(current, helpers, copies, env)
            artifacts_guard(artifact_hashes)
            copies_guard(copies, hashes)
            guard(approved_seal)
            assert sha(approval_path.resolve()) == approval_sha, 'approval changed during child'
            write(OUT/'receipt.json', receipt)
        receipt.update(status='PASS_REPAIR_FIXED_23', completed_children=23, simulations=17,
            named_parameter_rejects=6, reused_successful_profile_compiles=6,
            normal_replays=88, normal_output_records=20394, reset_jobs=43,
            reset_fresh_output_records=2843, reset_aborted_output_records=4,
            original_attempt_status_remains='FAILED_STOPPED', previous_attempt_status_remains='FAILED_STOPPED')
        write(OUT/'receipt.json', receipt)
        print('PASS REPAIR attempt_03 children=23 simulations=17 rejects=6 REUSED_COMPILES=6 BOTH_FAILURES_RETAINED', flush=True)
        return 0
    except Exception as exc:
        if current is not None:
            current['status'] = 'TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED', first_failure=current['name'] if current else 'setup',
            failure=f'{type(exc).__name__}: {exc}',
            not_run_children=[c['name'] for c in slots if c['status'] == 'NOT_RUN'],
            failure_archive_path='failure_archive/attempt_03')
        write(OUT/'receipt.json', receipt)
        try:
            archive_sha = archive_failure()
            print('FAILED_STOPPED REPAIR attempt_03 archive_sha256='+archive_sha, flush=True)
        except Exception as archive_error:
            # Retain partial archives and all evidence; no cleanup or automatic retry.
            print('FAILED_STOPPED REPAIR attempt_03 archive_error='+str(archive_error), flush=True)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-repair-seal', required=True)
    parser.add_argument('--approval', type=Path, required=True)
    args = parser.parse_args()
    return run_once(args.approved_repair_seal, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
