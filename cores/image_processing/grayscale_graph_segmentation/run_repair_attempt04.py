"""Separately approved scalar-scan TB repair with exactly 29 original children.

All three failures and their raw artifacts remain immutable. Six fresh profile
compiles are required; no old VVP program is reused and no preparation is run.
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
PLAN = ROOT/'REPAIR_PLAN_ATTEMPT04.json'
SEAL = ROOT/'REPAIR_SEAL_ATTEMPT04.json'
OUT = ROOT/'evidence/attempt_04'
TB = 'sim/tb_grayscale_graph_segmentation.sv'
HARD_SECONDS = 20
ORIGINAL_SEAL = '015df1ae9a19644b6dcc88ae333e4cc05e396a9930103fdd0fd039b345b34077'
SECOND_SEAL = '28222a72139356e613ae4b12636961c66c418f0fbeb8dc1b92a4772e320b4a04'
THIRD_SEAL = '675786772348a1e629f291362f7c84a34e354405ff4184744829f4960e41b757'
PARENT_RECEIPTS = {
    'attempt_01': '8ec0fdd87081b5c1c4075510e3c9cbafb634d4dd3a62e433a296767337dad52f',
    'attempt_02': '685a379cb526ceeb4e386b93bf6d961236f82969e87895c23a5f6b3f51538b04',
    'attempt_03': 'bf275157f1f2cda4280014fbcca89ef95fb1da87caec82f611649f669823ce8f'}
PARENT_ARCHIVES = {
    'attempt_01': 'ec38eb85352dcb64110ccbc862bf2ea19a93258080776ee41abff8fbacb1562a',
    'attempt_02': '9adc9c003ef591794e2f33bfb5589aba305b6dc18b6eafe006519c69bfb92b28',
    'attempt_03': '36183bd40be65c6b1986725c287577532b28738cb3262d8c95c6cb19979e749c'}


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
    assert sha(SEAL) == approved_seal, 'exact separately approved attempt_04 seal required'
    seal, plan = read(SEAL), read(PLAN)
    assert seal['schema'] == 'b28-c-repair04-source-seal-v1'
    assert sha(PLAN) == seal['repair_plan_sha256']
    assert sha(ROOT/'SOURCE_SEAL.json') == ORIGINAL_SEAL
    assert sha(ROOT/'REPAIR_SEAL_ATTEMPT02.json') == SECOND_SEAL
    assert sha(ROOT/'REPAIR_SEAL_ATTEMPT03.json') == THIRD_SEAL
    assert seal['parent_receipts_sha256'] == PARENT_RECEIPTS and seal['parent_archives_sha256'] == PARENT_ARCHIVES
    for anchor in seal['parent_evidence_dag'].values():
        base = REPO if anchor['base'] == 'repo' else ROOT
        assert sha(local(base, anchor['path'])) == anchor['sha256'], 'parent DAG changed'
    parents = {}
    for attempt, digest in PARENT_RECEIPTS.items():
        path = ROOT/'evidence'/attempt/'receipt.json'
        assert sha(path) == digest
        parents[attempt] = read(path)
        assert parents[attempt]['status'] == 'FAILED_STOPPED'
    assert [c['status'] for c in parents['attempt_01']['children']] == ['PASS']*4+['FAIL']+['NOT_RUN']*28
    assert [c['status'] for c in parents['attempt_02']['children']] == ['PASS']*6+['FAIL']+['NOT_RUN']*22
    assert [c['status'] for c in parents['attempt_03']['children']] == ['FAIL']+['NOT_RUN']*22
    assert parents['attempt_03']['children'][0]['returncode'] == 1
    previous = read(ROOT/'REPAIR_SEAL_ATTEMPT03.json')
    assert seal['inherited_source_overrides'] == previous['inherited_source_overrides']
    assert set(seal['source_overrides']) == {TB}
    override = seal['source_overrides'][TB]
    assert override['from_sha256'] == previous['copy_inputs'][TB]
    assert sha(ROOT/TB) == override['to_sha256']
    archived = {}
    historical_vvp = {}
    for attempt, count in [('attempt_01',135),('attempt_02',84),('attempt_03',75)]:
        archived[attempt] = archive_guard(attempt, PARENT_ARCHIVES[attempt], count,
            {TB: override['to_sha256']} if attempt == 'attempt_01' else {})
        payload = archived[attempt]['original_files_sha256']
        primary = 'evidence/'+attempt+'/'
        actual = {p.relative_to(ROOT).as_posix() for p in (ROOT/'evidence'/attempt).rglob('*') if p.is_file()}
        assert actual == {n for n in payload if n.startswith(primary)}, 'historical evidence inventory changed'
        for relative, digest in payload.items():
            if relative.endswith('.vvp'):
                historical_vvp[relative] = digest
                historical_vvp['failure_archive/'+attempt+'/'+relative] = digest
    assert seal['historical_vvp_sha256'] == historical_vvp and len(historical_vvp) == 26
    for relative, digest in historical_vvp.items():
        assert sha(local(ROOT, relative)) == digest, 'historical VVP changed'
    old = read(ROOT/'SOURCE_SEAL.json')
    assert plan['children'] == old['children'][4:] and len(plan['children']) == 29
    assert [c['name'] for c in plan['children'][:6]] == [f'compile_p{i}' for i in range(6)]
    assert sum(c['kind']=='compile' for c in plan['children']) == 6
    assert sum(c['kind']=='simulation' for c in plan['children']) == 17
    assert sum(c['kind']=='reject' for c in plan['children']) == 6
    assert all(c['hard_seconds']==20 for c in plan['children'])
    assert plan['omitted_previously_passed'] == [c['name'] for c in old['children'][:4]]
    assert plan['max_children']==29 and plan['stop_on_first_failure'] is True and plan['automatic_retry'] is False
    assert plan['profile_compilation_rerun'] is True and plan['reuse_old_vvp'] is False
    assert plan['numerical_preparation_rerun'] is plan['oracle_rerun'] is False
    expected = dict(parents['attempt_03']['tested_copies_sha256'])
    expected[TB] = override['to_sha256']
    expected['run_repair_attempt04.py'] = seal['copy_inputs']['run_repair_attempt04.py']
    expected[PLAN.name] = seal['repair_plan_sha256']
    assert seal['copy_inputs'] == expected and len(expected) == 67
    for relative, digest in seal['copy_inputs'].items():
        assert sha(local(ROOT, relative)) == digest, 'source or fixture changed'
    assert seal['tools']==old['tools'] and seal['external_sources']==old['external_sources']
    for tool in seal['tools'].values():
        assert sha(Path(tool['path'])) == tool['sha256'], 'tool changed'
    for relative, digest in seal['external_sources'].items():
        assert sha(local(REPO, relative)) == digest, 'external DSU changed'
    dependency = read(ROOT/'DEPENDENCIES.json')
    assert sha(local(REPO, dependency['baseline_manifest'])) == dependency['baseline_manifest_sha256']
    suite = Path(seal['tools']['VVP']['path']).parent.parent
    assert seal['path_prefix'] == plan['path_prefix'] == [str(suite/'bin'), str(suite/'lib')]
    assert all(Path(p).is_dir() for p in seal['path_prefix'])
    for draft in [seal['unexecuted_author_draft'], seal['package_author_history']]:
        assert draft['base'] in ('repo', 'package')
        draft_dir = local(REPO if draft['base'] == 'repo' else ROOT, draft['directory'])
        assert sha(local(draft_dir, draft['manifest'])) == draft['manifest_sha256']
        preserved = read(local(draft_dir, draft['manifest']))
        assert preserved['status'] == 'UNEXECUTED_AUTHOR_DRAFT_PRESERVED'
        assert preserved['files_sha256'] == draft['files_sha256']
        assert set(draft['files_sha256']) == {'run_repair_attempt03.py', 'REPAIR_PLAN_ATTEMPT03.json', 'REPAIR_SEAL_ATTEMPT03.json'}
        assert preserved['package_execution'] == preserved['hdl_execution'] == preserved['numerical_execution'] == 0
        actual_draft = {p.relative_to(draft_dir).as_posix() for p in draft_dir.rglob('*') if p.is_file()}
        assert actual_draft == set(draft['files_sha256']) | {draft['manifest']}
        for relative, digest in draft['files_sha256'].items():
            assert sha(local(draft_dir, relative)) == digest, 'unexecuted author draft changed'
    assert seal['package_author_history']['files_sha256'] == seal['unexecuted_author_draft']['files_sha256']
    assert seal['package_author_history']['manifest_sha256'] == seal['unexecuted_author_draft']['manifest_sha256']
    graph_anchor = seal['runtime_static_import_review']
    assert graph_anchor == seal['parent_evidence_dag']['runtime_static_import_review'] and graph_anchor['base'] == 'repo'
    static_review = read(local(REPO, graph_anchor['path']))
    assert static_review['reviewed_final_sha256'] == seal['unexecuted_author_draft']['files_sha256']
    graph = dict(static_review['static_PE_byte_parse']['graph'])
    supplement = static_review['static_PE_byte_parse']['additional_closure']
    assert not set(graph) & set(supplement)
    graph.update(supplement)
    cross_anchor = seal['runtime_independent_crosscheck_review']
    assert cross_anchor == seal['parent_evidence_dag']['runtime_independent_crosscheck_review'] and cross_anchor['base'] == 'repo'
    crosscheck = read(local(REPO, cross_anchor['path']))
    assert crosscheck['reviewed_initial_draft_sha256'] == seal['unexecuted_author_draft']['files_sha256']
    assert crosscheck['preservation_manifest_sha256'] == seal['unexecuted_author_draft']['manifest_sha256']
    observations = crosscheck['independent_PE_metadata_observations']
    assert observations['local_DLL_closure'] == 8 and observations['read_PE_files'] == 15 and observations['embedded_VPI_modules'] == 6
    assert crosscheck['blockers'][0]['additional_local_DLLs'] == {p: v['sha256'] for p, v in supplement.items()}
    dlls = {p: v['sha256'] for p, v in graph.items() if p.lower().endswith('.dll')}
    assert seal['runtime_dlls'] == dlls and len(dlls) == 8
    assert len(graph) == 15  # vvp.exe plus six embedded VPI modules plus eight local DLLs.
    assert {p: v['sha256'] for p, v in graph.items() if p.lower().endswith('.vpi')} == seal['runtime_modules']
    vvp_relative = Path(seal['tools']['VVP']['path']).relative_to(REPO).as_posix()
    assert graph[vvp_relative]['sha256'] == seal['tools']['VVP']['sha256']
    for relative, digest in dlls.items():
        assert sha(local(REPO, relative)) == digest, 'runtime DLL changed'
    for relative, digest in seal['runtime_modules'].items():
        assert sha(local(REPO, relative)) == digest, 'embedded VPI module changed'
    return seal, plan


def approval_guard(path: Path, approved_seal: str, seal: dict, plan: dict) -> str:
    path = path.resolve()
    assert not path.is_relative_to(ROOT), 'root approval must be external to package'
    approval = read(path)
    required = dict(schema='anscore-root-exact-c-repair04-hdl-v1', approved_by='root',
        attempt='attempt_04', repair_seal_sha256=approved_seal, repair_plan_sha256=sha(PLAN),
        original_source_seal_sha256=ORIGINAL_SEAL, previous_repair_seal_sha256=THIRD_SEAL,
        parent_receipts_sha256=PARENT_RECEIPTS, parent_archives_sha256=PARENT_ARCHIVES,
        max_children=29, timeout_seconds_per_tree=20, stop_on_first_failure=True,
        automatic_retry=False, profile_compilation_rerun=True, reuse_old_vvp=False,
        numerical_preparation_rerun=False, oracle_rerun=False)
    assert all(approval.get(k)==v for k,v in required.items()), 'attempt_04 approval mismatch'
    assert approval['children']==plan['children']
    assert approval['source_overrides']==seal['source_overrides']
    assert approval['path_prefix']==seal['path_prefix']
    assert len(approval['static_reviews'])>=2, 'independent A/B reviews required'
    for relative, digest in approval['static_reviews'].items():
        review = local(REPO, relative)
        assert not review.is_relative_to(ROOT) and sha(review)==digest
    return sha(path)


def copies_guard(copies: Path, hashes: dict) -> None:
    actual = {p.relative_to(copies).as_posix(): sha(p) for p in copies.rglob('*') if p.is_file()}
    assert actual == hashes, 'frozen tested-copy set/hash changed'


def artifacts_guard(hashes: dict) -> None:
    folder = OUT/'artifacts'
    actual = {p.relative_to(folder).as_posix(): sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual == hashes, 'generated artifact set/hash changed'


def load_reviewed_helpers(copies: Path):
    # Future approved runtime only: import frozen original helpers, no oracle/preparation.
    assert 'process_tree' not in sys.modules, 'unexpected preloaded process helper'
    sys.dont_write_bytecode = True
    previous = list(sys.path)
    try:
        sys.path.insert(0, str(copies))
        spec = importlib.util.spec_from_file_location('b28_c_attempt04_original_runner', copies/'run_tests.py')
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    finally:
        sys.path[:] = previous
    assert module.ROOT == copies
    assert Path(sys.modules['process_tree'].__file__).resolve() == (copies/'process_tree.py').resolve()
    return module


def invoke(slot: dict, helpers, copies: Path, env: dict) -> None:
    assert slot['kind'] in ('compile', 'simulation', 'reject')
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
    if slot['kind'] == 'compile':
        artifact = OUT/'artifacts'/(slot['profile']+'.vvp')
        if artifact.exists():
            slot['produced_artifact'] = dict(name=artifact.name, sha256=sha(artifact), bytes=artifact.stat().st_size)
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
        assert slot.get('produced_artifact',{}).get('bytes',0)>0, 'missing nonempty fresh VVP'
        slot['status'] = 'PASS'
        return
    assert raw_err == b'', 'unexpected simulator stderr'
    helpers.validate_simulation(slot, raw_out.decode('utf-8', errors='strict').splitlines())
    slot['status'] = 'PASS'


def register_compile(slot: dict, hashes: dict, seal: dict) -> None:
    name = slot['profile']+'.vvp'
    assert name not in hashes and name in {f'p{i}.vvp' for i in range(6)}
    entry = slot['produced_artifact']
    assert entry['name']==name and sha(OUT/'artifacts'/name)==entry['sha256']
    hashes[name] = entry['sha256']
    artifacts_guard(hashes)
    text = (OUT/'artifacts'/name).read_text(encoding='utf-8')
    modules = {Path(p).resolve().relative_to(REPO).as_posix() for p in re.findall(r'^:vpi_module "([^"]+)";', text, re.MULTILINE)}
    assert modules==set(seal['runtime_modules']), 'fresh VVP embedded runtime path set changed'


def archive_failure() -> str:
    target = ROOT/'failure_archive/attempt_04'
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
        parent_failure_archives_sha256=PARENT_ARCHIVES, automatic_retry=False))
    return sha(target/'ARCHIVE.json')


def run_once(approved_seal: str, approval_path: Path) -> int:
    if sys.flags.optimize != 0:
        raise RuntimeError('optimized Python is forbidden for assertion-based approval gates')
    if os.name != 'nt':
        raise RuntimeError('this separately approved attempt requires Windows process-tree control')
    seal, plan = guard(approved_seal)
    approval_sha = approval_guard(approval_path, approved_seal, seal, plan)
    assert not OUT.exists() and not (ROOT/'failure_archive/attempt_04').exists(), 'exclusive attempt; no retry'
    OUT.mkdir(parents=True, exist_ok=False)
    write(OUT/'LOCK.json', dict(schema=1, status='STARTED_ONCE', attempt='attempt_04',
        repair_seal_sha256=approved_seal, approval_sha256=approval_sha))
    slots = []
    for command in plan['children']:
        slot = copy.deepcopy(command)
        slot['plan_argv'] = slot.pop('argv')
        slot['status'] = 'NOT_RUN'
        slots.append(slot)
    receipt = dict(schema=1, status='STARTED', attempt='attempt_04', repair_seal_sha256=approved_seal,
        repair_plan_sha256=sha(PLAN), approval_sha256=approval_sha,
        original_source_seal_sha256=ORIGINAL_SEAL, previous_repair_seal_sha256=THIRD_SEAL,
        parent_receipts_sha256=PARENT_RECEIPTS, parent_archives_sha256=PARENT_ARCHIVES,
        omitted_previously_passed=plan['omitted_previously_passed'], children=slots,
        parent_evidence_dag=seal['parent_evidence_dag'],
        source_overrides=seal['source_overrides'], inherited_source_overrides=seal['inherited_source_overrides'],
        historical_vvp_sha256=seal['historical_vvp_sha256'], hard_seconds=20, automatic_retry=False,
        stop_on_first_failure=True, profile_compilation_rerun=True, reuse_old_vvp=False,
        numerical_preparation_rerun=False, oracle_rerun=False, path_prefix=seal['path_prefix'],
        runtime_dlls=seal['runtime_dlls'], runtime_modules=seal['runtime_modules'], hardware='HW_UNVERIFIED')
    write(OUT/'receipt.json', receipt)
    current = None
    artifact_hashes = {}
    try:
        copies = OUT/'sources'
        hashes = {**seal['copy_inputs'],SEAL.name:approved_seal}
        for relative, digest in hashes.items():
            target = local(copies, relative)
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('xb') as destination:
                destination.write(local(ROOT, relative).read_bytes())
            assert sha(target)==digest
        (OUT/'artifacts').mkdir()
        receipt['tested_copies_sha256'] = hashes
        receipt['generated_artifacts_sha256'] = {}
        copies_guard(copies, hashes)
        artifacts_guard(artifact_hashes)
        helpers = load_reviewed_helpers(copies)
        copies_guard(copies, hashes)
        env = os.environ.copy()
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        env['PYTHONIOENCODING'] = 'utf-8'
        inherited_path = env.get('PATH','')
        env['PATH'] = os.pathsep.join(seal['path_prefix'])+(os.pathsep+inherited_path if inherited_path else '')
        receipt['inherited_PATH_sha256'] = hashlib.sha256(inherited_path.encode('utf-8')).hexdigest()
        receipt['effective_PATH_sha256'] = hashlib.sha256(env['PATH'].encode('utf-8')).hexdigest()
        write(OUT/'receipt.json', receipt)
        for current in slots:
            guard(approved_seal)
            assert sha(approval_path.resolve())==approval_sha, 'approval changed'
            copies_guard(copies, hashes)
            artifacts_guard(artifact_hashes)
            if current['kind']=='compile':
                assert current['profile']+'.vvp' not in artifact_hashes
                assert not (OUT/'artifacts'/(current['profile']+'.vvp')).exists(), 'fresh exclusive compile target required'
            else:
                assert set(artifact_hashes)=={f'p{i}.vvp' for i in range(6)}
            invoke(current, helpers, copies, env)
            if current['kind']=='compile':
                register_compile(current, artifact_hashes, seal)
            artifacts_guard(artifact_hashes)
            copies_guard(copies, hashes)
            guard(approved_seal)
            assert sha(approval_path.resolve())==approval_sha, 'approval changed during child'
            receipt['generated_artifacts_sha256'] = dict(artifact_hashes)
            write(OUT/'receipt.json', receipt)
        assert set(artifact_hashes)=={f'p{i}.vvp' for i in range(6)}
        receipt.update(status='PASS_REPAIR_FIXED_29', completed_children=29, profile_compiles=6,
            simulations=17, named_parameter_rejects=6, normal_replays=88, normal_output_records=20394,
            reset_jobs=43, reset_fresh_output_records=2843, reset_aborted_output_records=4,
            all_parent_attempt_statuses_remain='FAILED_STOPPED')
        write(OUT/'receipt.json', receipt)
        print('PASS REPAIR attempt_04 children=29 compiles=6 simulations=17 rejects=6 THREE_FAILURES_RETAINED', flush=True)
        return 0
    except Exception as exc:
        if current is not None:
            current['status'] = 'TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED', first_failure=current['name'] if current else 'setup',
            failure=f'{type(exc).__name__}: {exc}', generated_artifacts_sha256=dict(artifact_hashes),
            observed_artifacts_sha256={p.relative_to(OUT/'artifacts').as_posix():sha(p) for p in (OUT/'artifacts').rglob('*') if p.is_file()},
            not_run_children=[c['name'] for c in slots if c['status']=='NOT_RUN'],
            failure_archive_path='failure_archive/attempt_04')
        write(OUT/'receipt.json', receipt)
        try:
            archive_sha = archive_failure()
            print('FAILED_STOPPED REPAIR attempt_04 archive_sha256='+archive_sha, flush=True)
        except Exception as archive_error:
            print('FAILED_STOPPED REPAIR attempt_04 archive_error='+str(archive_error), flush=True)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--approved-repair-seal', required=True)
    parser.add_argument('--approval', type=Path, required=True)
    args = parser.parse_args()
    return run_once(args.approved_repair_seal, args.approval)


if __name__ == '__main__':
    raise SystemExit(main())
