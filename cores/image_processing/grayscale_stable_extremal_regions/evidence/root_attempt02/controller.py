"""Source-only C EOF repair draft:22 new fixed children and4 inherited PASS records.
This file is unexecuted. Root must construct/review an exact plan and issue a
separate hash-bound approval after independent controller/plan review.
"""
from pathlib import Path, PurePosixPath
import argparse
import copy
import hashlib
import importlib.util
import json
import os
import re
import sys

if sys.flags.optimize:
    raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode = True
R = Path(__file__).resolve().parent.parent
PACKAGE = 'cores/image_processing/grayscale_stable_extremal_regions'
NAME = 'grayscale_stable_extremal_regions'
ATTEMPT = 'evidence/root_attempt02'
AUTHOR_SHA = '7933e06929e2ba8b7e97c2ee8c8c30245ae03d1b42e92d40c2684c67a5d18151'
SEAL_SHA = '645daedaadff39c35a1bb99c3b28f03aecf4127ec974f06362d85b1f677155b1'
TEST_PLAN_SHA = 'abbff99dfb0398366e6135d19178062af97c9cbb23a4bbee2f08575523e51f92'
TOOL_SHA = '9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b'
FAILED_RECEIPT = 'evidence/attempt_01/receipt.json'
FAILED_SHA = 'd69ba0aaf1fc73f6d51f3082158357dd4a4c9b629bfc2df4ec63f0a4b1917ac6'
FAILED_ARCHIVE = 'failure_archive/attempt_01/ARCHIVE.json'
ARCHIVE_SHA = 'b73648bb0c6f28cddbaf221994df6e9e2990a718e8a2e3d77081ee9050e23088'
PRESERVED = '.git/b30-c-hdl-attempt01-static-preservation/PRESERVED.json'
PRESERVED_SHA = '2085883188b5bb840bf995ec6a337e3083de601db618303df292620e19d81cdd'
OVERLAY_NAME = NAME + '/sim/tb_grayscale_stable_extremal_regions.sv'
OVERLAY_PATH = '.git/b30-c-eof-tb-draft01/tb_grayscale_stable_extremal_regions.sv'
OVERLAY_SHA = '0bb92929d627ba2a3bd7eaf91d3cad9a30f4d5ba17d21b83c02efadec467beb1'
DEPENDENCY = 'cores/image_processing/grayscale_max_tree/rtl/grayscale_max_tree.sv'
DEPENDENCY_COPY = 'grayscale_max_tree/rtl/grayscale_max_tree.sv'
DEPENDENCY_SHA = '39d42c70847386e1094fbc6faa3a346cb3af721ff75cbf4a4632769b6364d2e5'
CARRY_NAMES = ['stored_only', 'ast_only', 'lint_core', 'lint_example']
ALLOWED_LOADS = {
    'runtime': '7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2',
    'process_tree': 'fe72a3898573434aaca538db6848aa185b770b610024df6e5e73b27e99964ba8',
    'validate': '578e361bc2c1991d249ce14f1bab2e7e68be8846fe9428ffcc109b4abcbf17e6',
}
CONTAINMENT = dict(created_suspended=True, assigned_to_job=True,
                   resumed=True, contained_before_resume=True)
SIMULATION_TOTALS = dict(inputs=3118, outputs=3118, frames=40,
                         reset_targets=10, probe_inputs=771)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def write(path, value, exclusive=False):
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')


def local(base, name):
    relative = PurePosixPath(name)
    assert name and not relative.is_absolute() and '..' not in relative.parts
    assert not any(c in name for c in ('\\', ':', '\0', '\r', '\n'))
    candidate = base / name
    assert not candidate.is_symlink()
    value = candidate.resolve()
    assert value.is_relative_to(base.resolve())
    return value


def inventory(folder, exclude=None):
    result = {}
    for path in folder.rglob('*'):
        if path.is_file():
            name = path.relative_to(folder).as_posix()
            if exclude and (name == exclude or name.startswith(exclude + '/')):
                continue
            assert not path.is_symlink() and path.resolve().is_relative_to(folder.resolve())
            result[name] = sha(path)
    return result


def exact(folder, expected):
    assert inventory(folder) == expected, 'exact path/hash inventory changed'


def reviews_guard(reviews):
    assert isinstance(reviews, dict) and len(reviews) >= 2
    for name, digest in reviews.items():
        path = local(R, name)
        assert path.is_relative_to(R / '.git') and sha(path) == digest


def external_guard(p):
    assert sha(local(R, PRESERVED)) == PRESERVED_SHA
    assert sha(local(R, OVERLAY_PATH)) == OVERLAY_SHA
    assert sha(local(R, DEPENDENCY)) == DEPENDENCY_SHA
    author = read(p / 'AUTHOR_SEAL.json')
    for entry in author['anchors'].values():
        assert sha(local(R, entry['path'])) == entry['sha256']
    for name, digest in author['external_sources'].items():
        assert sha(local(R, name)) == digest


def derive(p):
    assert sha(p / 'AUTHOR_SEAL.json') == AUTHOR_SHA
    assert sha(p / 'SOURCE_SEAL.json') == SEAL_SHA
    assert sha(p / 'TEST_PLAN.json') == TEST_PLAN_SHA
    assert sha(p / 'TOOL_INVENTORY.json') == TOOL_SHA
    seal = read(p / 'SOURCE_SEAL.json')
    assert seal['author_seal_sha256'] == AUTHOR_SHA
    assert seal['test_plan_sha256'] == TEST_PLAN_SHA and len(seal['files']) == 114
    own = dict(seal['files'])
    own['SOURCE_SEAL.json'] = SEAL_SHA
    sources = {NAME + '/' + name: digest for name, digest in own.items()}
    dependencies = read(p / 'DEPENDENCIES.json')['external_production']
    assert len(dependencies) == 1
    dependency = dependencies[0]
    assert dependency['repo_path'] == DEPENDENCY
    assert dependency['list_path'] == '../' + DEPENDENCY_COPY
    assert dependency['sha256'] == DEPENDENCY_SHA
    sources[DEPENDENCY_COPY] = DEPENDENCY_SHA
    assert len(sources) == 116
    sources[OVERLAY_NAME] = OVERLAY_SHA
    original = read(p / 'TEST_PLAN.json')
    assert len(original['children']) == 26
    assert [c['name'] for c in original['children'][:4]] == CARRY_NAMES
    children = copy.deepcopy(original['children'][4:])
    assert len(children) == 22
    assert [c['kind'] for c in children] == ['compile'] * 5 + ['simulation'] * 10 + ['reject'] * 7
    assert all(c['hard_seconds'] == 20 for c in children)
    assert [c['profile'] for c in children[:5]] == ['P0', 'P1', 'P2', 'P3', 'P4']
    for name, digest in ALLOWED_LOADS.items():
        assert sources[NAME + '/' + name + '.py'] == digest
    external_guard(p)
    return children, sources, {OVERLAY_NAME: dict(path=OVERLAY_PATH, sha256=OVERLAY_SHA)}


def carried_guard(p, plan):
    assert sha(local(p, FAILED_RECEIPT)) == FAILED_SHA == plan['parent_failed_receipt_sha256']
    assert sha(local(p, FAILED_ARCHIVE)) == ARCHIVE_SHA == plan['parent_failure_archive_sha256']
    parent = read(p / FAILED_RECEIPT)
    assert parent['status'] == 'FAILED_STOPPED'
    assert parent['preparation_rerun'] is False and parent['reference_rerun'] is False
    records = parent['children']
    assert len(records) == 26 and parent['completed_children'] == 10
    assert [(c['name'], c['status']) for c in records if c['launched']] == [
        ('stored_only', 'PASS'), ('ast_only', 'PASS'), ('lint_core', 'PASS'),
        ('lint_example', 'PASS'), ('compile_P0', 'PASS'), ('compile_P1', 'PASS'),
        ('compile_P2', 'PASS'), ('compile_P3', 'PASS'), ('compile_P4', 'PASS'),
        ('sim_p0_main', 'FAIL')]
    assert all(c['status'] == 'NOT_RUN' and c['launched'] is False for c in records[10:])
    selected = records[:4]
    assert plan['carried_records'] == selected and plan['carried_artifacts'] == {}
    original = read(p / 'TEST_PLAN.json')['children'][:4]
    stdout_expected = [b'STORED profiles=5 main=30 fresh=10 reset=10 groups=10 NO_MODEL\r\n',
                       b'AST_ONLY_PASS\r\n', b'', b'']
    old_cwd = p / 'evidence/attempt_01/sources' / NAME
    for index, passed in enumerate(selected):
        assert passed['name'] == CARRY_NAMES[index] and passed['status'] == 'PASS' and passed['launched'] is True
        assert passed['plan_argv'] == original[index]['argv'] == passed['argv']
        assert passed['working_directory'] == str(old_cwd)
        assert passed['returncode'] == 0 and passed['timed_out'] is False and passed['failure'] is None
        assert isinstance(passed['pid'], int) and passed['pid'] > 0
        assert 0 <= passed['elapsed_seconds'] < 20
        assert passed['windows_containment'] == CONTAINMENT
        assert passed['process_tree_cleanup'] == {'windows_kill_on_close_job_closed': True}
        for stream, expected in [('stdout', stdout_expected[index]), ('stderr', b'')]:
            entry = passed[stream]
            raw = local(p, entry['file'])
            assert sha(raw) == entry['sha256'] and raw.stat().st_size == entry['bytes']
            assert raw.read_bytes() == expected
    return [dict(**item, execution='CARRIED_NOT_RERUN', parent_receipt_sha256=FAILED_SHA)
            for item in selected]


def approved_context(plan_path, plan_digest, approval_path):
    assert plan_path.is_relative_to(R / '.git') and sha(plan_path) == plan_digest
    plan = read(plan_path)
    assert plan['schema'] == 'anscore-b30-c-eof-repair-plan-v1'
    assert plan['controller_sha256'] == sha(Path(__file__))
    assert plan['channel'] == 'c' and plan['package'] == PACKAGE and plan['attempt'] == ATTEMPT
    assert plan['parent_author_sha256'] == AUTHOR_SHA and plan['parent_source_seal_sha256'] == SEAL_SHA
    assert plan['parent_failed_receipt_path'] == FAILED_RECEIPT
    assert plan['parent_failed_receipt_sha256'] == FAILED_SHA
    assert plan['parent_failure_archive_path'] == FAILED_ARCHIVE
    assert plan['parent_failure_archive_sha256'] == ARCHIVE_SHA
    assert plan['preservation_manifest_path'] == PRESERVED and plan['preservation_manifest_sha256'] == PRESERVED_SHA
    assert plan['model_calls'] == 0 and plan['preparation_reexecution'] is False and plan['reference_rerun'] is False
    assert plan['first_failure_stop'] is True and plan['automatic_retry'] is False and plan['hard_seconds_per_tree'] == 20
    p = local(R, PACKAGE)
    children, sources, overlays = derive(p)
    assert plan['children'] == children and plan['copy_files_sha256'] == sources and plan['overlays'] == overlays
    assert len(plan['baseline_package_files_sha256']) == 402
    assert plan['baseline_package_files_sha256'] == read(local(R, PRESERVED))['files_sha256']
    exact(p, plan['baseline_package_files_sha256'])
    carried = carried_guard(p, plan)
    reviews_guard(plan['independent_source_reviews'])
    assert approval_path.is_relative_to(R / '.git')
    approval = read(approval_path)
    required = dict(schema='anscore-b30-c-eof-repair-approval-v1', approved_by='root', channel='c',
                    controller_sha256=sha(Path(__file__)), repair_plan_sha256=plan_digest,
                    max_invocations=1, hard_seconds_per_tree=20, first_failure_stop=True,
                    automatic_retry=False, preparation_reexecution=False, reference_rerun=False,
                    model_calls=0, fixed_new_children=22, carried_not_rerun=4)
    assert all(approval.get(name) == value for name, value in required.items())
    reviews_guard(approval['independent_reviews'])
    return p, plan, approval, carried


def load_copied(cwd, name):
    assert name in ALLOWED_LOADS
    path = local(cwd, name + '.py')
    assert sha(path) == ALLOWED_LOADS[name]
    # A distinct module name keeps validate.py's __main__ stored entry inactive.
    spec = importlib.util.spec_from_file_location('b30_c_eof_' + name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(plan_path, plan_digest, approval_path):
    assert os.name == 'nt'
    p, plan, approval, carried = approved_context(plan_path, plan_digest, approval_path)
    approved = sha(approval_path)
    controller = sha(Path(__file__))
    attempt = local(p, ATTEMPT)
    assert not attempt.exists()
    attempt.mkdir(parents=True, exist_ok=False)
    copies = attempt / 'sources'
    cwd = copies / NAME
    artifacts = attempt / 'artifacts'
    raw_root = attempt / 'raw'
    sources = plan['copy_files_sha256']
    receipt = dict(schema='anscore-b30-c-eof-repair-receipt-v1', status='STARTED_ONCE', channel='c',
                   repair_plan_sha256=plan_digest, approval_sha256=approved, controller_sha256=controller,
                   parent_author_sha256=AUTHOR_SHA, parent_source_seal_sha256=SEAL_SHA,
                   parent_failed_receipt_sha256=FAILED_SHA, parent_failure_archive_sha256=ARCHIVE_SHA,
                   preservation_manifest_sha256=PRESERVED_SHA, carried_records=carried, carried_artifacts={},
                   records=[dict(name=c['name'], kind=c['kind'], status='NOT_RUN', launched=False) for c in plan['children']],
                   copied_files_sha256=sources, generated_artifacts_sha256={}, results=[], model_calls=0,
                   preparation_reexecution=False, reference_rerun=False, hard_seconds_per_tree=20,
                   automatic_retry=False, hardware='HW_UNVERIFIED')
    lock = dict(status='STARTED_ONCE', repair_plan_sha256=plan_digest, approval_sha256=approved)
    retained = {'controller.py': controller, 'repair_plan.json': plan_digest, 'approval.json': approved}
    current = None
    phase = 'initial_receipt'
    runtime = tools = None

    def save():
        write(attempt / 'receipt.json', receipt)

    def boundary():
        assert sha(Path(__file__)) == controller and sha(plan_path) == plan_digest and sha(approval_path) == approved
        reviews_guard(approval['independent_reviews'])
        reviews_guard(plan['independent_source_reviews'])
        for name, digest in retained.items():
            assert sha(attempt / name) == digest, 'retained metadata changed'
        assert read(attempt / 'LOCK.json') == lock and sha(attempt / 'LOCK.json') == receipt['lock_sha256']
        assert inventory(p, exclude=ATTEMPT) == plan['baseline_package_files_sha256'], 'original402 package bytes changed'
        external_guard(p)
        carried_guard(p, plan)
        exact(copies, sources)
        raw_files = {}
        for row in receipt['records']:
            for stream in ('stdout', 'stderr'):
                if stream in row:
                    entry = row[stream]
                    raw_files[local(p, entry['file']).relative_to(raw_root).as_posix()] = entry['sha256']
        exact(raw_root, raw_files)
        exact(artifacts, receipt['generated_artifacts_sha256'])
        runtime.verify(tools)

    try:
        write(attempt / 'receipt.json', receipt, True)
        write(attempt / 'LOCK.json', lock, True)
        receipt['lock_sha256'] = sha(attempt / 'LOCK.json')
        for filename, origin in [('controller.py', Path(__file__)), ('repair_plan.json', plan_path), ('approval.json', approval_path)]:
            with (attempt / filename).open('xb') as stream:
                stream.write(origin.read_bytes())
        copies.mkdir()
        for name, digest in sources.items():
            if name in plan['overlays']:
                origin = local(R, plan['overlays'][name]['path'])
            elif name == DEPENDENCY_COPY:
                origin = local(R, DEPENDENCY)
            else:
                relative = PurePosixPath(name)
                assert relative.parts[0] == NAME
                origin = local(p, PurePosixPath(*relative.parts[1:]).as_posix())
            assert sha(origin) == digest
            destination = local(copies, name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with destination.open('xb') as stream:
                stream.write(origin.read_bytes())
            assert sha(destination) == digest
        exact(copies, sources)
        artifacts.mkdir()
        raw_root.mkdir()
        temporary = attempt / 'tmp'
        temporary.mkdir()
        tools = read(cwd / 'TOOL_INVENTORY.json')
        assert sha(cwd / 'TOOL_INVENTORY.json') == TOOL_SHA
        runtime = load_copied(cwd, 'runtime')
        supervisor = load_copied(cwd, 'process_tree')
        validator = load_copied(cwd, 'validate')
        system = next(Path(path).parent for path in tools['path_prefix'] if Path(path).name.lower() == 'system32')
        env = dict(SystemRoot=str(system), WINDIR=str(system), PATH=os.pathsep.join(tools['path_prefix']),
                   TEMP=str(temporary), TMP=str(temporary), PYTHONDONTWRITEBYTECODE='1', PYTHONNOUSERSITE='1',
                   PYTHONPATH='', PYTHONIOENCODING='utf-8', LANG='C', LC_ALL='C')
        receipt['fixed_environment'] = env
        receipt['environment_sha256'] = hashlib.sha256(json.dumps(env, sort_keys=True).encode()).hexdigest()
        original_plan = read(cwd / 'TEST_PLAN.json')
        for index, child in enumerate(plan['children']):
            current = None
            phase = 'pre_boundary:' + child['name']
            boundary()
            argv = [arg.replace('{ARTIFACT}', str(artifacts)) for arg in child['argv']]
            tool = 'VVP' if child['kind'] == 'simulation' else 'IVERILOG'
            assert argv[0] == tools['tools'][tool]['path']
            if child['kind'] == 'compile':
                filename = child['profile'] + '.vvp'
                assert not (artifacts / filename).exists()
            if child['kind'] == 'simulation':
                assert set(receipt['generated_artifacts_sha256']) == {'P0.vvp', 'P1.vvp', 'P2.vvp', 'P3.vvp', 'P4.vvp'}
            current = dict(name=child['name'], kind=child['kind'], status='RUNNING', launched=True,
                           argv=argv, working_directory=str(cwd))
            receipt['records'][index] = current
            phase = 'child:' + child['name']
            save()
            result = supervisor.execute(argv, cwd, env, 20)
            stdout, stderr = result.pop('stdout'), result.pop('stderr')
            current.update(result)
            # Persist every returned byte exclusively before checking process or raw semantics.
            for stream_name, data in [('stdout', stdout), ('stderr', stderr)]:
                path = raw_root / (child['name'] + '.' + stream_name + '.raw')
                with path.open('xb') as stream:
                    stream.write(data)
                current[stream_name] = dict(file=path.relative_to(p).as_posix(), sha256=sha(path), bytes=len(data))
            current['observed_artifacts_sha256'] = inventory(artifacts)
            save()
            assert current['argv'] == argv and current['working_directory'] == str(cwd) and current['environment'] == env
            assert current['failure'] is None and current['timed_out'] is False and 0 <= current['elapsed_seconds'] < 20
            assert isinstance(current['pid'], int) and current['pid'] > 0
            assert current['windows_containment'] == CONTAINMENT
            assert current['process_tree_cleanup'] == {'windows_kill_on_close_job_closed': True}
            if child['kind'] == 'reject':
                assert current['returncode'] == 1 and stdout == b''
                assert stderr.decode('ascii').splitlines() == original_plan['reject_stderr_lines']
                current['status'] = 'EXPECTED_REJECT'
            else:
                assert current['returncode'] == 0 and stderr == b'', 'nonzero child or unexpected stderr'
                if child['kind'] == 'compile':
                    assert stdout == b''
                    artifact = artifacts / filename
                    assert artifact.is_file() and artifact.stat().st_size > 0
                    modules = re.findall(r'^:vpi_module "([^"]+)";', artifact.read_text('utf-8'), re.MULTILINE)
                    assert len(modules) == 6
                    assert {str(Path(name).resolve()).casefold() for name in modules} == {str(Path(name).resolve()).casefold() for name in tools['runtime_modules_sha256']}
                    receipt['generated_artifacts_sha256'][filename] = sha(artifact)
                else:
                    assert child['kind'] == 'simulation'
                    # This is the only validate.py function called: no stored/__main__/checker entry.
                    validated = validator.simulation(child, stdout, cwd)
                    assert set(validated) == set(SIMULATION_TOTALS) | {'stored_only'} and validated['stored_only'] is True
                    receipt['results'].append(dict(name=child['name'], result=validated))
                current['status'] = 'PASS'
            phase = 'post_boundary:' + child['name']
            boundary()
            save()
        current = None
        phase = 'final_boundary'
        boundary()
        assert len(receipt['results']) == 10 and len(receipt['generated_artifacts_sha256']) == 5
        totals = {name: sum(item['result'][name] for item in receipt['results']) for name in SIMULATION_TOTALS}
        assert totals == SIMULATION_TOTALS
        assert [row['status'] for row in receipt['records']] == ['PASS'] * 15 + ['EXPECTED_REJECT'] * 7
        receipt.update(status='PASS_FIXED_QUALIFICATION_WITH_REVIEWED_EOF_REPAIR', actual_children=22,
                       effective_records=26, actual_tuples=totals,
                       max_child_seconds=max(row['elapsed_seconds'] for row in receipt['records']),
                       successful_artifacts_retained_for_independent_review=True)
        save()
        print('PASS REPAIRED_FIXED_QUALIFICATION c')
        return 0
    except Exception as error:
        if current is not None:
            current['status'] = 'FAIL'
        receipt.update(status='FAILED_STOPPED_NO_AUTOMATIC_RETRY',
                       failure=dict(type=type(error).__name__, message=str(error), phase=phase),
                       observed_artifacts_sha256=inventory(artifacts),
                       not_run=[row['name'] for row in receipt['records'] if row['status'] == 'NOT_RUN'])
        save()
        files = inventory(attempt)
        write(attempt / 'FAILURE_ARCHIVE.json',
              dict(status='PERMANENT_PRESERVED_IN_PLACE', files_sha256=files, automatic_retry=False), True)
        print('FAILED_STOPPED REPAIRED_FIXED_QUALIFICATION c')
        return 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--approved-plan', required=True)
    parser.add_argument('--approval', type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.plan.resolve(), args.approved_plan, args.approval.resolve()))
