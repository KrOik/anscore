"""Separately approved 29-child continuation; never reruns preparation or oracle.

The original failed attempt and its archive are immutable parents of this repair.
Only the TB predicate string dispatch is overridden. No package module is imported
until the exact repair seal and an external root approval have both been checked.
"""
from __future__ import annotations
import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PLAN = ROOT / 'REPAIR_PLAN_ATTEMPT02.json'
SEAL = ROOT / 'REPAIR_SEAL_ATTEMPT02.json'
OUT = ROOT / 'evidence/attempt_02'
ARCHIVE = ROOT / 'failure_archive/attempt_01'
TB = 'sim/tb_grayscale_graph_segmentation.sv'
HARD_SECONDS = 20
ORIGINAL_SEAL = '015df1ae9a19644b6dcc88ae333e4cc05e396a9930103fdd0fd039b345b34077'
ORIGINAL_RECEIPT = '8ec0fdd87081b5c1c4075510e3c9cbafb634d4dd3a62e433a296767337dad52f'
ORIGINAL_ARCHIVE = 'ec38eb85352dcb64110ccbc862bf2ea19a93258080776ee41abff8fbacb1562a'


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


def guard(approved_seal: str) -> tuple[dict, dict]:
    assert sha(SEAL) == approved_seal, 'exact separately approved repair seal required'
    seal, plan = read(SEAL), read(PLAN)
    assert seal['schema'] == 'b28-c-repair-source-seal-v1'
    assert sha(PLAN) == seal['repair_plan_sha256']
    assert sha(ROOT/'SOURCE_SEAL.json') == ORIGINAL_SEAL
    assert sha(ROOT/'evidence/attempt_01/receipt.json') == ORIGINAL_RECEIPT
    assert sha(ARCHIVE/'ARCHIVE.json') == ORIGINAL_ARCHIVE
    for anchor in seal['original_evidence_dag'].values():
        base = REPO if anchor['base'] == 'repo' else ROOT
        assert sha(local(base, anchor['path'])) == anchor['sha256'], 'parent DAG changed'
    old = read(ROOT/'SOURCE_SEAL.json')
    failed = read(ROOT/'evidence/attempt_01/receipt.json')
    archived = read(ARCHIVE/'ARCHIVE.json')
    assert failed['status'] == 'FAILED_STOPPED' and failed['first_failure'] == 'compile_p0'
    assert [c['status'] for c in failed['children']] == ['PASS']*4 + ['FAIL'] + ['NOT_RUN']*28
    assert plan['children'] == old['children'][4:]
    assert len(plan['children']) == 29
    assert sum(c['kind'] == 'compile' for c in plan['children']) == 6
    assert sum(c['kind'] == 'simulation' for c in plan['children']) == 17
    assert sum(c['kind'] == 'reject' for c in plan['children']) == 6
    assert plan['omitted_previously_passed'] == [c['name'] for c in old['children'][:4]]
    override = seal['source_overrides']
    assert set(override) == {TB}
    assert override[TB]['from_sha256'] == old['sources'][TB]
    assert sha(ROOT/TB) == override[TB]['to_sha256']
    assert archived['files'] == len(archived['original_files_sha256']) == 135
    archive_files = {p.relative_to(ARCHIVE).as_posix() for p in ARCHIVE.rglob('*') if p.is_file()}
    assert archive_files == set(archived['original_files_sha256']) | {'ARCHIVE.json'}
    for relative, digest in archived['original_files_sha256'].items():
        assert sha(local(ARCHIVE, relative)) == digest, 'failed archive bytes changed'
        current = override[TB]['to_sha256'] if relative == TB else digest
        assert sha(local(ROOT, relative)) == current, 'protected original evidence changed'
    expected_inputs = dict(failed['tested_copies_sha256'])
    expected_inputs[TB] = override[TB]['to_sha256']
    expected_inputs['run_repair_attempt02.py'] = seal['copy_inputs']['run_repair_attempt02.py']
    expected_inputs[PLAN.name] = seal['repair_plan_sha256']
    assert seal['copy_inputs'] == expected_inputs
    for relative, digest in seal['copy_inputs'].items():
        assert sha(local(ROOT, relative)) == digest, 'repair source/fixture changed'
    assert seal['tools'] == old['tools'] and seal['external_sources'] == old['external_sources']
    for tool in seal['tools'].values():
        assert sha(Path(tool['path'])) == tool['sha256'], 'tool changed'
    for relative, digest in seal['external_sources'].items():
        assert sha(local(REPO, relative)) == digest, 'original DSU changed'
    dependency = read(ROOT/'DEPENDENCIES.json')
    assert sha(local(REPO, dependency['baseline_manifest'])) == dependency['baseline_manifest_sha256']
    return seal, plan


def approval_guard(path: Path, approved_seal: str, plan: dict) -> str:
    path = path.resolve()
    assert not path.is_relative_to(ROOT), 'root approval must be external to package'
    approval = read(path)
    required = dict(schema='anscore-root-exact-c-repair-hdl-v1', approved_by='root',
                    attempt='attempt_02', repair_seal_sha256=approved_seal,
                    repair_plan_sha256=sha(PLAN), original_source_seal_sha256=ORIGINAL_SEAL,
                    original_failure_receipt_sha256=ORIGINAL_RECEIPT,
                    original_failure_archive_sha256=ORIGINAL_ARCHIVE,
                    max_children=29, timeout_seconds_per_tree=20,
                    stop_on_first_failure=True, automatic_retry=False)
    assert all(approval.get(k) == v for k, v in required.items()), 'repair approval mismatch'
    assert approval['children'] == plan['children'], 'approval must enumerate exact 29 children'
    assert len(approval['static_reviews']) >= 2, 'root-required independent A/B reviews'
    for relative, digest in approval['static_reviews'].items():
        review = (REPO/relative).resolve()
        assert not review.is_relative_to(ROOT) and sha(review) == digest
    return sha(path)


def copies_guard(copies: Path, hashes: dict) -> None:
    actual = {p.relative_to(copies).as_posix(): sha(p) for p in copies.rglob('*') if p.is_file()}
    assert actual == hashes, 'frozen tested-copy set/hash changed'


def load_reviewed_helpers(copies: Path):
    # Future approved runtime only. No oracle or preparation module is imported.
    assert 'process_tree' not in sys.modules, 'unexpected preloaded process helper'
    sys.dont_write_bytecode = True
    previous = list(sys.path)
    try:
        sys.path.insert(0, str(copies))
        spec = importlib.util.spec_from_file_location('b28_c_attempt02_original_runner', copies/'run_tests.py')
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    assert module.ROOT == copies
    assert Path(sys.modules['process_tree'].__file__).resolve() == (copies/'process_tree.py').resolve()
    return module


def invoke(slot: dict, helpers, copies: Path, env: dict) -> None:
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
    if slot['kind'] == 'compile':
        assert raw_out == raw_err == b'', 'unexpected compiler diagnostic'
    elif slot['kind'] == 'simulation':
        assert raw_err == b'', 'unexpected simulator stderr'
        helpers.validate_simulation(slot, raw_out.decode('utf-8', errors='strict').splitlines())
    else:
        raise RuntimeError('repair may launch compile/simulation/reject only')
    slot['status'] = 'PASS'


def archive_failure() -> str:
    target = ROOT/'failure_archive/attempt_02'
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
          original_receipt_sha256=sha(OUT/'receipt.json'),
          original_parent_archive_sha256=ORIGINAL_ARCHIVE, automatic_retry=False))
    return sha(target/'ARCHIVE.json')


def run_once(approved_seal: str, approval_path: Path) -> int:
    # These explicit checks must survive -O/PYTHONOPTIMIZE before any assert gate.
    if sys.flags.optimize != 0:
        raise RuntimeError('optimized Python is forbidden for assertion-based approval gates')
    if os.name != 'nt':
        raise RuntimeError('this separately approved attempt requires Windows process-tree control')
    seal, plan = guard(approved_seal)
    approval_sha = approval_guard(approval_path, approved_seal, plan)
    assert not OUT.exists() and not (ROOT/'failure_archive/attempt_02').exists(), 'one exclusive attempt; never retry'
    OUT.mkdir(parents=True, exist_ok=False)
    write(OUT/'LOCK.json', dict(schema=1, status='STARTED_ONCE', attempt='attempt_02',
          repair_seal_sha256=approved_seal, approval_sha256=approval_sha))
    slots = []
    for original in plan['children']:
        slot = copy.deepcopy(original)
        slot['plan_argv'] = slot.pop('argv')
        slot['status'] = 'NOT_RUN'
        slots.append(slot)
    receipt = dict(schema=1, status='STARTED', attempt='attempt_02',
        repair_seal_sha256=approved_seal, repair_plan_sha256=sha(PLAN),
        approval_sha256=approval_sha, original_source_seal_sha256=ORIGINAL_SEAL,
        original_failure_receipt_sha256=ORIGINAL_RECEIPT,
        original_failure_archive_sha256=ORIGINAL_ARCHIVE,
        original_preparation_receipt_sha256=seal['original_evidence_dag']['preparation_receipt']['sha256'],
        omitted_previously_passed=plan['omitted_previously_passed'], source_overrides=seal['source_overrides'],
        children=slots, hard_seconds=20, automatic_retry=False, stop_on_first_failure=True,
        numerical_preparation_rerun=False, oracle_rerun=False, hardware='HW_UNVERIFIED')
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
        receipt['tested_copies_sha256'] = hashes
        write(OUT/'receipt.json', receipt)
        copies_guard(copies, hashes)
        helpers = load_reviewed_helpers(copies)
        copies_guard(copies, hashes)
        env = os.environ.copy()
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        env['PYTHONIOENCODING'] = 'utf-8'
        tool_bin = str(Path(seal['tools']['IVERILOG']['path']).parent)
        env['PATH'] = tool_bin + os.pathsep + env.get('PATH', '')
        for current in slots:
            guard(approved_seal)
            assert sha(approval_path.resolve()) == approval_sha, 'approval changed'
            copies_guard(copies, hashes)
            invoke(current, helpers, copies, env)
            copies_guard(copies, hashes)
            guard(approved_seal)
            assert sha(approval_path.resolve()) == approval_sha, 'approval changed during child'
            write(OUT/'receipt.json', receipt)
        artifacts = {p.relative_to(OUT).as_posix(): sha(p) for p in sorted((OUT/'artifacts').glob('*.vvp'))}
        assert set(artifacts) == {f'artifacts/p{i}.vvp' for i in range(6)}
        receipt.update(status='PASS_REPAIR_FIXED_29', completed_children=29, simulations=17,
            named_parameter_rejects=6, normal_replays=88, normal_output_records=20394,
            reset_jobs=43, reset_fresh_output_records=2843, reset_aborted_output_records=4,
            artifacts_sha256=artifacts, original_attempt_status_remains='FAILED_STOPPED')
        write(OUT/'receipt.json', receipt)
        print('PASS REPAIR attempt_02 children=29 simulations=17 rejects=6 ORIGINAL_FAILURE_RETAINED', flush=True)
        return 0
    except Exception as exc:
        if current is not None:
            current['status'] = 'TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED', first_failure=current['name'] if current else 'setup',
            failure=f'{type(exc).__name__}: {exc}',
            not_run_children=[c['name'] for c in slots if c['status'] == 'NOT_RUN'],
            failure_archive_path='failure_archive/attempt_02')
        write(OUT/'receipt.json', receipt)
        try:
            archive_sha = archive_failure()
            print('FAILED_STOPPED REPAIR archive_sha256='+archive_sha, flush=True)
        except Exception as archive_error:
            # No retry and no cleanup: partial archive and all original evidence stay.
            print('FAILED_STOPPED REPAIR archive_error='+str(archive_error), flush=True)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-repair-seal', required=True)
    parser.add_argument('--approval', type=Path, required=True)
    args = parser.parse_args()
    return run_once(args.approved_repair_seal, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
