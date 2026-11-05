"""Root-owned draft: A first fixed25 HDL qualification, no preparation/model replay.

This file is inert until a separate exact plan and root approval are supplied.
The embedded simulation validator is an unchanged static copy of the frozen A
runner routine. The old runner is never imported. Successful artifacts remain.
"""
from pathlib import Path, PurePosixPath
import argparse, ast, hashlib, importlib.util, json, os, re, sys
if sys.flags.optimize:
    raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode = True

R = Path(__file__).resolve().parent.parent
PACKAGE = 'cores/storage/ram_range_min_index'
P = R / PACKAGE
ATTEMPT = 'evidence/root_attempt01'
A = '474202814626d9cf7f9ad1dddc3a9e2802e6006557257bed6426816a116e143e'
AUTHOR_SEAL = '8aff538286c1f53da328e77bc8559751cb98733f3cafdf9c36fc04539dff154a'
PREPARATION_PLAN = '28ad33540f2cce30461247d1d8b7d4f46727f4540ddaee713c489207c68c4fee'
SOURCE_SEAL = '92824c2f5021b4717ca6b8b349d933aab012a269f08f895627591da4eb8fa47b'
TEST_PLAN = 'a82e20cba202b03053150895fe37445203b40270426f67956417072284576889'
TOOLCHAIN = '66451fe901727a9c43cff679811f20e7b47524fe86f4ea76a3067a1c75569646'
PREPARATION_EVIDENCE = '603f9938d11b98cb73959d36376a322d3ee4d989b234a0e04a1e842be04ffee4'
PREPARED_RECEIPT = 'a9589c3e620b9480918e876b0abd9f6fe033c6ed20315079e81eebc078ba630c'
PREPARED_LOCK = '374f12ede80955a1ceaee78b79a6339bdc42a29af5b2a409cb96a43c9b5db2db'
PREPARATION_APPROVAL = '78e5a053124d520d049596cac6f0e1de9cd84d49c4c8600097fafa8c1ceb9946'
PREPARATION_OUTER_RECEIPT = 'fd48b55a7389e7fe08ad05e52eb4a55e03b3e9adcbdc22a2779245c6e61c7f75'
BASELINE_MAP_SHA256 = 'dfc87f33d808fd5cbc84bb20a509776cd217ebac4ba941882802bad21aabf7ba'
COPY_MAP_SHA256 = '9c1199937ed87f66e5db327492e97e9276314393d1cc26361b675f77b81467bd'
SIMULATION_PARSER_SHA256 = '39524862081c9c23145c1a629f7f6d6eb57a6f8d8155105fe46ab195d65320cb'
RUNTIME_INPUTS = {
    "TOOL_INVENTORY.json": {
        "path": "cores/signal_processing/exact_1d_transport/TOOL_INVENTORY.json",
        "sha256": "9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b"
    },
    "tool_runtime.py": {
        "path": "cores/signal_processing/exact_1d_transport/sim/runtime.py",
        "sha256": "7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2"
    },
    "tree_process.py": {
        "path": "cores/acceleration/exact_undirected_steiner_tree/tree_process.py",
        "sha256": "4e72238dd4ad0836df7a614914e67a5e57cf871cb60fe0b0251a85b2e6f71a2a"
    }
}
PROVENANCE_FILES_SHA256 = {
    ".git/anscore-b30-a-prepare-outer.py": "f19120356c939a68590a678ae38ee487e649c26b1548f295849c8c2d8e22e272",
    ".git/anscore-b30-a-source-seal-metadata.py": "36e2bc23f76350aea0b84483f56e1941f10e7e759340baa1876adff62cd09aa8",
    ".git/b30-a-preparation-outer-execution01/LOCK.json": "936331cb6ecad93da8003e266499599a3fbae265a9aebef817465f4a48d77b27",
    ".git/b30-a-preparation-outer-execution01/TOOL_INVENTORY.json": "9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b",
    ".git/b30-a-preparation-outer-execution01/approval.json": "78e5a053124d520d049596cac6f0e1de9cd84d49c4c8600097fafa8c1ceb9946",
    ".git/b30-a-preparation-outer-execution01/launcher.py": "f19120356c939a68590a678ae38ee487e649c26b1548f295849c8c2d8e22e272",
    ".git/b30-a-preparation-outer-execution01/receipt.json": "fd48b55a7389e7fe08ad05e52eb4a55e03b3e9adcbdc22a2779245c6e61c7f75",
    ".git/b30-a-preparation-outer-execution01/stderr.raw": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    ".git/b30-a-preparation-outer-execution01/stdout.raw": "8360865aea83cbb15869e4c37216ff570874bf8e10fd5854d7843e6c2fe42d0b",
    ".git/b30-a-preparation-outer-execution01/tool_runtime.py": "7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2",
    ".git/b30-a-preparation-outer-execution01/tree_process.py": "4e72238dd4ad0836df7a614914e67a5e57cf871cb60fe0b0251a85b2e6f71a2a",
    ".git/b30-a-prepare01-approval.json": "78e5a053124d520d049596cac6f0e1de9cd84d49c4c8600097fafa8c1ceb9946",
    ".git/b30-a-source-seal-creation01/LOCK.json": "6fd3a143f1771f9212918119ce213379edb201506f248065852f526cd96b53ea",
    ".git/b30-a-source-seal-creation01/approval.json": "2e43d2f4802ae669851fa758276752e086cafb9a1fb00e7de4e6f19c38bd9b73",
    ".git/b30-a-source-seal-creation01/builder.py": "36e2bc23f76350aea0b84483f56e1941f10e7e759340baa1876adff62cd09aa8",
    ".git/b30-a-source-seal-creation01/receipt.json": "9f1ebffa7725a025ed64ce1feab5ca8f2b214a69906acd5ed108021216330260",
    ".git/b30-a-source-seal-metadata-approval01.json": "2e43d2f4802ae669851fa758276752e086cafb9a1fb00e7de4e6f19c38bd9b73",
    ".git/b30-b-a-prepare-outer-review01.json": "65bd13178afbacf99ad125fd4e424d535cc5354630da9255af5adb0ad63c014a",
    ".git/b30-b-a-source-seal-metadata-review01.json": "938dbddd8ae2d705d20c6be1ab38eeb09cc186159b608f9e5a03b881ed809383",
    ".git/b30-c-a-prepare-context-review.json": "f389f14dd8a69388ae2179f59dec975724f68593151225bec7e7485b517f0c48",
    ".git/b30-c-a-prepare-outer-review01.json": "a4fe5956d44defc2abe0d6466dc5f922afe493bd9c4d77b783327b8240c024ea",
    ".git/b30-c-a-prepare-outer-review02.json": "478b31465a8582b264a7723ed4546b4d276a706597d4650e778136204bd64fd0",
    ".git/b30-c-a-prepared-actual-review01.json": "588b17fffdb129f88ebd895367df7a9dd4b9c5ad7495d7d022b5f30d04680ef6",
    ".git/b30-c-a-repair02-review.json": "1d39747efecddfbcbf9b2e6e5aaba94d0ceaad4a171f4687372a36c95a534500",
    "cores/acceleration/exact_undirected_steiner_tree/tree_process.py": "4e72238dd4ad0836df7a614914e67a5e57cf871cb60fe0b0251a85b2e6f71a2a",
    "cores/signal_processing/exact_1d_transport/TOOL_INVENTORY.json": "9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b",
    "cores/signal_processing/exact_1d_transport/sim/runtime.py": "7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2"
}
KIND_COUNTS = dict(stored=1, compile_lint=2, compile=4, simulation=12, reject=6)
REJECT_MARKER = b'ram_range_min_index_invalid_parameters__see_README'
STORED_PASS = b'PASS STORED HASHES NO_ORACLE_REEXECUTION\r\n'


def require(value, message):
    if not value:
        raise RuntimeError(message)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def map_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def exact_fields(obj, expected, message):
    require(all(type(obj.get(k)) is type(v) and obj[k] == v for k, v in expected.items()), message)


def local(base, name):
    require(isinstance(name, str) and name, 'empty or non-string relative path')
    relative = PurePosixPath(name)
    require(not relative.is_absolute() and '..' not in relative.parts and name == relative.as_posix(), 'noncanonical relative path')
    require(not any(c in name for c in ('\\', ':', '\0', '\r', '\n')), 'invalid path character')
    candidate = base / name
    resolved = candidate.resolve()
    require(resolved.is_relative_to(base.resolve()), 'path escapes its fixed root')
    current = candidate
    while current != base:
        require(not current.is_symlink() and not current.is_junction(), 'symlink/junction is forbidden')
        current = current.parent
    return candidate


def inventory(folder, exclude=None):
    result = {}
    for path in folder.rglob('*'):
        if exclude is not None and (path == exclude or path.is_relative_to(exclude)):
            continue
        name = path.relative_to(folder).as_posix()
        checked = local(folder, name)
        if checked.is_file():
            result[name] = sha(checked)
        else:
            require(checked.is_dir(), 'unexpected filesystem object')
    return result


def exact_inventory(folder, expected, exclude=None):
    require(inventory(folder, exclude) == expected, 'file inventory/hash drift: ' + str(folder))


def raw_write(path, raw):
    with path.open('xb') as stream:
        stream.write(raw)


def json_write(path, value, exclusive=False):
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(value, indent=2) + '\n')


def reviews_guard(reviews):
    require(type(reviews) is dict and len(reviews) >= 2, 'two or more independently reviewed artifacts required')
    for name, digest in reviews.items():
        require(name.startswith('.git/'), 'review must be a root-owned external artifact')
        require(sha(local(R, name)) == digest, 'independent review drift')


def parser_digest():
    # Inspect this root file only; never import or execute the frozen runner.
    text = Path(__file__).read_text(encoding='utf-8')
    nodes = [n for n in ast.parse(text).body if isinstance(n, ast.FunctionDef) and n.name == 'validate_simulation']
    require(len(nodes) == 1, 'embedded parser function is not unique')
    node = nodes[0]
    fragment = '\n'.join(text.splitlines()[node.lineno - 1:node.end_lineno]) + '\n'
    return hashlib.sha256(fragment.encode()).hexdigest()


def fixed_source_context(source_seal_digest):
    require(source_seal_digest == SOURCE_SEAL and sha(P / 'SOURCE_SEAL.json') == SOURCE_SEAL, 'approved source seal mismatch')
    for name, expected in [('AUTHOR_INPUTS.json', A), ('AUTHOR_SEAL.json', AUTHOR_SEAL),
                           ('PREPARATION_PLAN.json', PREPARATION_PLAN), ('TEST_PLAN.json', TEST_PLAN),
                           ('TOOLCHAIN.json', TOOLCHAIN), ('preparation_evidence/receipt.json', PREPARATION_EVIDENCE),
                           ('prepared/receipt.json', PREPARED_RECEIPT), ('prepared/LOCK.json', PREPARED_LOCK)]:
        require(sha(local(P, name)) == expected, 'original preparation/source anchor changed')
    seal = read(P / 'SOURCE_SEAL.json')
    exact_fields(seal, dict(schema='b30-a-source-seal-v2', status='FROZEN_NOT_EXECUTION_APPROVAL',
                           author_sha256=A, author_seal_sha256=AUTHOR_SEAL, test_plan_sha256=TEST_PLAN,
                           toolchain_sha256=TOOLCHAIN, hardware='HW_UNVERIFIED'), 'source seal identity')
    author = read(P / 'AUTHOR_INPUTS.json')
    author_seal = read(P / 'AUTHOR_SEAL.json')
    prepared = read(P / 'prepared/receipt.json')
    lock = read(P / 'prepared/LOCK.json')
    evidence = read(P / 'preparation_evidence/receipt.json')
    prep_approval = read(R / '.git/b30-a-prepare01-approval.json')
    own = {**author['sources'], 'AUTHOR_INPUTS.json': A, 'AUTHOR_SEAL.json': AUTHOR_SEAL}
    require(len(author['sources']) == 24 and len(own) == 26, 'fixed author closure count')
    require(author_seal['sources'] == {**author['sources'], 'AUTHOR_INPUTS.json': A}, 'author seal closure')
    require(author_seal['author_inputs_sha256'] == A, 'author seal identity')
    identities = dict(author_sha256=A, author_seal_sha256=AUTHOR_SEAL, preparation_plan_sha256=PREPARATION_PLAN,
                      approval_path=str(R / '.git/b30-a-prepare01-approval.json'), approval_sha256=PREPARATION_APPROVAL)
    execution = prep_approval['execution_context']
    original_argv = [x.replace('{APPROVAL_SHA256}', PREPARATION_APPROVAL) for x in execution['preparation_argv_template']]
    executed = {n:author['sources'][n] for n in ('prepare.py', 'oracle.py')}
    for record in (evidence, prepared, lock):
        exact_fields(record, identities, 'preparation identity drift')
        require(record['execution_context'] == execution and record['argv'] == original_argv, 'preparation context/argv drift')
        require(record['working_directory'] == execution['preparation_cwd'] and record['executed_sources_sha256'] == executed, 'preparation execution source drift')
    exact_fields(evidence, dict(status='PREPARATION_PASS', returncode=0, timed_out=False, failure=None,
                               max_invocations=1, hard_seconds=20, automatic_retry=False), 'original preparation did not pass')
    require(0 <= evidence['elapsed_seconds'] < 20 and evidence['process_tree_cleanup']['windows_kill_on_close_job_closed'] is True, 'original numerical Job20 evidence')
    exact_fields(prepared, dict(status='PREPARED_FIXED_FINITE', preparation_invocations=1, input_expansion=False,
                               automatic_retry=False, hardware='HW_UNVERIFIED'), 'prepared receipt finite identity')
    require(lock['status'] == 'STARTED_ONCE', 'prepared LOCK changed')
    require(evidence['prepared_receipt_sha256'] == PREPARED_RECEIPT and evidence['prepared_lock_sha256'] == PREPARED_LOCK, 'prepared linkage drift')
    for stream, expected in [('stdout', b'PASS PREPARATION FIXED_PROGRAMS\r\n'), ('stderr', b'')]:
        path = local(P, evidence[stream + '_file'])
        require(path.read_bytes() == expected and sha(path) == evidence[stream + '_sha256']
                and path.stat().st_size == evidence[stream + '_bytes'], 'original numerical raw drift')
    fixtures = prepared['files_sha256']
    require(len(fixtures) == 198 and all(n.startswith('prepared/fixtures/') for n in fixtures), 'fixed fixture closure')
    prepared_map = {**fixtures, 'prepared/receipt.json': PREPARED_RECEIPT, 'prepared/LOCK.json': PREPARED_LOCK}
    exact_inventory(P / 'prepared', {n.removeprefix('prepared/'):h for n,h in prepared_map.items()})
    require(seal['sources'] == {**own, **prepared_map} and len(seal['sources']) == 226, 'sealed source226 closure')
    require(seal['external_sources'] == author['external_sources'], 'external RAM closure drift')
    prep_copies = {PACKAGE + '/' + n:h for n,h in own.items()}
    prep_copies.update(author['external_sources'])
    prep_copies[author['baseline_manifest']] = author['baseline_manifest_sha256']
    require(len(prep_copies) == 28 and execution['tested_copies_sha256'] == prep_copies
            and evidence['tested_copies_sha256'] == prep_copies, 'original preparation28 copies')
    exact_inventory(P / 'preparation_evidence/sources', prep_copies)
    prep_context = {**identities, 'prepared_receipt_sha256': PREPARED_RECEIPT,
                    'preparation_evidence_receipt_sha256': PREPARATION_EVIDENCE,
                    'prepared_lock_sha256': PREPARED_LOCK, 'execution_context': execution,
                    'argv': original_argv, 'working_directory': evidence['working_directory']}
    require(seal['preparation'] == prep_context, 'seal preparation provenance drift')
    finite = read(P / 'TEST_PLAN.json')
    require(seal['children'] == finite['children'] and len(finite['children']) == 25, 'fixed25 children changed')
    counts = {k:sum(c['kind'] == k for c in finite['children']) for k in KIND_COUNTS}
    require(counts == KIND_COUNTS and finite['children'][0]['name'] == 'stored_hashes'
            and finite['children'][0]['kind'] == 'stored', 'first stored checker / finite kind counts changed')
    exact_fields(finite, dict(child_count=25, simulations=12, named_parameter_rejects=6,
                             hard_seconds=20, automatic_retry=False, stop_on_first_failure=True), 'finite plan policy')
    require(len({c['name'] for c in finite['children']}) == 25, 'duplicate child name')
    prep_map = {'preparation_evidence/sources/' + n:h for n,h in prep_copies.items()}
    prep_map.update({'preparation_evidence/receipt.json': PREPARATION_EVIDENCE,
                     'preparation_evidence/stdout.raw': evidence['stdout_sha256'],
                     'preparation_evidence/stderr.raw': evidence['stderr_sha256']})
    baseline = {**own, **prepared_map, **prep_map, 'SOURCE_SEAL.json': SOURCE_SEAL}
    require(len(baseline) == 258 and map_digest(baseline) == BASELINE_MAP_SHA256, 'original258 baseline identity')
    copies = {PACKAGE + '/' + n:h for n,h in {**seal['sources'], 'SOURCE_SEAL.json': SOURCE_SEAL}.items()}
    copies.update(author['external_sources'])
    copies[author['baseline_manifest']] = author['baseline_manifest_sha256']
    require(len(copies) == 229 and map_digest(copies) == COPY_MAP_SHA256, 'repository-shaped229 source closure')
    for name, digest in copies.items():
        require(sha(local(R, name)) == digest, 'original source/external dependency drift')
    metadata = seal['root_metadata_only_creation']
    require(metadata['model_calls'] == 0 and metadata['tool_children'] == 0, 'metadata-only seal creation required')
    for filename, key in [('builder.py', 'builder_sha256'), ('approval.json', 'approval_sha256')]:
        require(sha(R / '.git/b30-a-source-seal-creation01' / filename) == metadata[key], 'metadata seal creation capture drift')
    created = read(R / '.git/b30-a-source-seal-creation01/receipt.json')
    exact_fields(created, dict(status='PASS_METADATA_ONLY_SOURCE_SEAL_CREATED', source_seal_sha256=SOURCE_SEAL,
                              builder_sha256=metadata['builder_sha256'], approval_sha256=metadata['approval_sha256'],
                              model_calls=0, tool_children=0), 'metadata creation receipt drift')
    return baseline, copies, finite['children']


def approved_context(plan_path, plan_digest, approval_path, source_seal_digest):
    require(os.name == 'nt', 'Windows Job execution required')
    require(parser_digest() == SIMULATION_PARSER_SHA256, 'embedded parser source drift')
    plan_path = plan_path.resolve()
    approval_path = approval_path.resolve()
    require(plan_path.is_relative_to(R / '.git') and approval_path.is_relative_to(R / '.git'), 'external root plan/approval required')
    require(sha(plan_path) == plan_digest, 'approved plan digest mismatch')
    plan = read(plan_path)
    controller = sha(Path(__file__))
    required_plan = dict(schema='anscore-b30-a-fixed-hdl-plan-v1', channel='a', package=PACKAGE, attempt=ATTEMPT,
                         controller_sha256=controller, source_seal_sha256=SOURCE_SEAL, author_sha256=A,
                         author_seal_sha256=AUTHOR_SEAL, preparation_plan_sha256=PREPARATION_PLAN,
                         test_plan_sha256=TEST_PLAN, simulation_parser_sha256=SIMULATION_PARSER_SHA256,
                         runtime_inputs=RUNTIME_INPUTS, provenance_files_sha256=PROVENANCE_FILES_SHA256,
                         max_invocations=1, hard_seconds_per_tree=20, first_failure_stop=True,
                         automatic_retry=False, preparation_reexecution=False, model_calls=0, hardware='HW_UNVERIFIED')
    exact_fields(plan, required_plan, 'fixed root HDL plan mismatch')
    require(source_seal_digest == plan['source_seal_sha256'], 'CLI/source seal plan mismatch')
    baseline, copies, children = fixed_source_context(source_seal_digest)
    require(plan['baseline_package_files_sha256'] == baseline and plan['copy_files_sha256'] == copies
            and plan['children'] == children, 'exact original/copy/child plan maps mismatch')
    reviews_guard(plan['independent_reviews'])
    for name, digest in PROVENANCE_FILES_SHA256.items():
        require(sha(local(R, name)) == digest, 'fixed preparation/runtime provenance drift')
    exact_inventory(P, baseline, local(P, ATTEMPT))
    approval = read(approval_path)
    required_approval = dict(schema='anscore-b30-a-fixed-hdl-approval-v1', approved_by='root', channel='a',
                             controller_sha256=controller, plan_sha256=plan_digest, source_seal_sha256=SOURCE_SEAL,
                             simulation_parser_sha256=SIMULATION_PARSER_SHA256, attempt=ATTEMPT,
                             children=children, max_invocations=1, hard_seconds_per_tree=20,
                             first_failure_stop=True, automatic_retry=False, preparation_reexecution=False,
                             model_calls=0, hardware='HW_UNVERIFIED')
    exact_fields(approval, required_approval, 'separate exact root HDL approval mismatch')
    reviews_guard(approval['independent_reviews'])
    require(all(approval['independent_reviews'].get(name) == digest for name, digest in plan['independent_reviews'].items()),
            'approval reviews must preserve the plan review map with identical hashes')
    return plan, approval, baseline, copies, children


def load_root_helper(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    require(spec is not None and spec.loader is not None, 'root helper loader unavailable')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    require(Path(module.__file__).resolve() == path.resolve(), 'root helper source path mismatch')
    return module


# BEGIN FROZEN ROOT-LOCAL PARSER: exact static source, no old-runner import.
def validate_simulation(c,raw,copies):
    lines=raw.decode('utf-8','strict').splitlines()
    assert lines,'empty simulation stdout'
    assert re.fullmatch(r'sim[/\\]tb_ram_range_min_index\.sv:\d+: \$finish called at \d+ \(1ps\)',lines[-1])
    assert sum('$finish' in x for x in lines)==1
    lines=lines[:-1];profile=c['profile']
    plan=read(copies/'RAW_INPUTS.json');p=next(x for x in plan['profiles'] if x['name']==profile)
    def program(label):
        rows=read(copies/'prepared/fixtures'/profile/(label+'.json'));result=[]
        for i,row in enumerate(rows):
            result.append(' '.join(map(str,['CMD',profile,label,i]+row['command'])))
            result.append(' '.join(map(str,['REC',profile,label,i]+row['response'])))
        return result,len(rows)
    if c['mode']=='main':
        expected,count=program('main')
        expected.append(f'PASS MAIN profile={profile} stall={c["stall"]} commands={count} records={count}')
        assert lines==expected,'exact main command/record stream mismatch';return
    cursor=total=0
    for job in p['reset_jobs']:
        label=job['name'];number=int(label[1:]);want,count=program('pre_'+label)
        assert lines[cursor:cursor+len(want)]==want;cursor+=len(want);total+=count
        assert lines[cursor]==' '.join(map(str,['CANCEL',profile,label]+job['cancel_command']));cursor+=1
        fields=lines[cursor].split();cursor+=1
        assert len(fields)==14 and fields[:3]==['PROBE',profile,label]
        # Canonical unsigned decimal fields, no alternate spellings or extra tokens.
        assert all(re.fullmatch(r'0|[1-9][0-9]*',x) for x in fields[3:])
        st,op,node,span,valid,status,ready,offer_valid,write,ret,lazy=map(int,fields[3:])
        P=1<<(p['buckets']-1).bit_length()
        assert op==job['cancel_command'][0] and 1<=node<2*P
        assert span and span<=P and span&(span-1)==0 and ready==0
        assert lazy in [0,1]
        assert valid==int(number>=8) and status==int(number==9) and offer_valid==int(number==11)
        if number==1:assert st==3 and node==1 and span==P
        elif number in [2,7]:
            assert st==13 and write==0 and ret==4
            if number==7:assert op==1 and node==1 and span==P
        elif number==3:assert st==13 and write==1 and ret==5
        elif number==4:assert st==13 and write==1 and ret==6
        elif number==5:
            assert st==13 and op==0 and write==1 and ret==7 and span==1 and lazy==1
            assert node==P+job['cancel_command'][1]
        elif number==6:
            assert st==13 and op==0 and write==1 and ret==7 and span==2 and lazy==0
            assert node==(P+job['cancel_command'][1])//2
        else:assert st==11
        assert lines[cursor]==' '.join(map(str,['OFFER',profile,label]+job['fresh'][0][1:]));cursor+=1
        for edge in range(3):
            assert lines[cursor]==f'RESETEDGE {profile} {label} {edge} 1 0 0';cursor+=1
        want,count=program('fresh_'+label)
        assert lines[cursor:cursor+len(want)]==want;cursor+=len(want);total+=count
        assert lines[cursor]==f'RESETDONE {profile} {label}';cursor+=1
    assert lines[cursor:]==[f'PASS RESET profile={profile} probes={len(p["reset_jobs"])} commands={total} records={total}']
# END FROZEN ROOT-LOCAL PARSER.


def run(plan_path, plan_digest, approval_path, source_seal_digest):
    plan_path = plan_path.resolve()
    approval_path = approval_path.resolve()
    plan, approval, baseline, copies, children = approved_context(plan_path, plan_digest, approval_path, source_seal_digest)
    controller_path = Path(__file__).resolve()
    controller_digest = sha(controller_path)
    approval_digest = sha(approval_path)
    attempt = local(P, ATTEMPT)
    require(not attempt.exists(), 'unique attempt already exists; no retry is allowed')
    attempt.mkdir(parents=True, exist_ok=False)
    sources = attempt / 'sources'
    copied_package = sources / PACKAGE
    artifacts = attempt / 'artifacts'
    raw_dir = attempt / 'raw'
    runtime_dir = attempt / 'runtime'
    expected_output_files = {}
    retained_files = {}
    raw_files = {}
    generated = {}
    runtime = tools = supervisor = None
    receipt = dict(schema='anscore-b30-a-fixed-hdl-receipt-v1', status='STARTED_ONCE', channel='a',
                   controller_sha256=controller_digest, plan_sha256=plan_digest,
                   approval_sha256=approval_digest, source_seal_sha256=SOURCE_SEAL,
                   simulation_parser_sha256=SIMULATION_PARSER_SHA256,
                   author_sha256=A, author_seal_sha256=AUTHOR_SEAL, preparation_plan_sha256=PREPARATION_PLAN,
                   copied_files_sha256=copies, baseline_package_files_sha256=baseline,
                   provenance_files_sha256=PROVENANCE_FILES_SHA256,
                   records=[], generated_artifacts_sha256={}, validated_simulations=[],
                   model_calls=0, preparation_reexecution=False, carried_records=[],
                   hard_seconds_per_tree=20, automatic_retry=False, hardware='HW_UNVERIFIED')
    for child in children:
        argv = [x.replace('{ARTIFACT}', str(artifacts)) for x in child['argv']]
        require(not any('{' in x or '}' in x for x in argv), 'unresolved child argv token')
        receipt['records'].append(dict(child, argv_template=child['argv'][:], argv=argv,
                                       cwd=str(copied_package), status='NOT_RUN', execution_started=False))
    lock = dict(status='STARTED_ONCE', controller_sha256=controller_digest, plan_sha256=plan_digest,
                approval_sha256=approval_digest, source_seal_sha256=SOURCE_SEAL)
    current = None
    phase = 'setup'

    def save():
        previous = expected_output_files.get('receipt.json')
        if previous is not None:
            require((attempt / 'receipt.json').is_file() and sha(attempt / 'receipt.json') == previous,
                    'receipt drift before controller update')
        receipt['generated_artifacts_sha256'] = dict(generated)
        json_write(attempt / 'receipt.json', receipt)
        expected_output_files['receipt.json'] = sha(attempt / 'receipt.json')

    def boundary():
        require(sha(controller_path) == controller_digest and sha(plan_path) == plan_digest
                and sha(approval_path) == approval_digest, 'controller/plan/approval drift')
        reviews_guard(plan['independent_reviews'])
        reviews_guard(approval['independent_reviews'])
        for name, digest in PROVENANCE_FILES_SHA256.items():
            require(sha(local(R, name)) == digest, 'preparation/tool/runtime provenance drift')
        exact_inventory(P, baseline, attempt)
        for name, digest in copies.items():
            require(sha(local(R, name)) == digest, 'original repository dependency drift')
        exact_inventory(sources, copies)
        exact_inventory(artifacts, generated)
        exact_inventory(raw_dir, raw_files)
        for name, digest in retained_files.items():
            require(sha(local(attempt, name)) == digest, 'retained controller metadata drift')
        require(read(attempt / 'LOCK.json') == lock and read(attempt / 'receipt.json') == receipt, 'retained LOCK/receipt drift')
        expected = {**{'sources/' + n:h for n,h in copies.items()},
                    **{'artifacts/' + n:h for n,h in generated.items()},
                    **{'raw/' + n:h for n,h in raw_files.items()},
                    **retained_files, **expected_output_files}
        exact_inventory(attempt, expected)
        require(not list((attempt / 'tmp').iterdir()), 'unexpected retained temporary output')
        runtime.verify(tools)

    try:
        save()
        json_write(attempt / 'LOCK.json', lock, True)
        retained_files['LOCK.json'] = sha(attempt / 'LOCK.json')
        sources.mkdir()
        artifacts.mkdir()
        raw_dir.mkdir()
        runtime_dir.mkdir()
        (attempt / 'tmp').mkdir()
        for name, source in [('controller.py', controller_path), ('plan.json', plan_path), ('approval.json', approval_path)]:
            raw_write(attempt / name, source.read_bytes())
            retained_files[name] = sha(attempt / name)
        require(sha(attempt / 'controller.py') == controller_digest, 'retained controller differs from approved original')
        require(sha(attempt / 'plan.json') == plan_digest, 'retained plan differs from approved original')
        require(sha(attempt / 'approval.json') == approval_digest, 'retained approval differs from approved original')
        for name, entry in RUNTIME_INPUTS.items():
            original = local(R, entry['path'])
            require(sha(original) == entry['sha256'], 'runtime input changed before copy')
            destination = runtime_dir / name
            raw_write(destination, original.read_bytes())
            require(sha(destination) == entry['sha256'], 'runtime capture mismatch')
            retained_files['runtime/' + name] = entry['sha256']
        for name, digest in copies.items():
            source = local(R, name)
            require(sha(source) == digest, 'source changed during frozen copy')
            destination = local(sources, name)
            destination.parent.mkdir(parents=True, exist_ok=True)
            raw_write(destination, source.read_bytes())
            require(sha(destination) == digest, 'frozen source copy mismatch')
        tools = read(runtime_dir / 'TOOL_INVENTORY.json')
        require(sha(runtime_dir / 'TOOL_INVENTORY.json') == RUNTIME_INPUTS['TOOL_INVENTORY.json']['sha256'], 'complete runtime inventory changed')
        runtime = load_root_helper(runtime_dir / 'tool_runtime.py', 'b30_a_root_fixed_runtime')
        supervisor = load_root_helper(runtime_dir / 'tree_process.py', 'b30_a_root_fixed_job20')
        require(Path(sys.executable).resolve() == Path(tools['tools']['PYTHON']['path']).resolve()
                and sha(Path(sys.executable)) == tools['tools']['PYTHON']['sha256'], 'controller interpreter mismatch')
        system = Path(r'C:\Windows').resolve(strict=True)
        environment = dict(SystemRoot=str(system), WINDIR=str(system), PATH=os.pathsep.join(tools['path_prefix']),
                           TEMP=str(attempt / 'tmp'), TMP=str(attempt / 'tmp'), PYTHONDONTWRITEBYTECODE='1',
                           PYTHONNOUSERSITE='1', PYTHONPATH='', PYTHONIOENCODING='utf-8', LANG='C', LC_ALL='C')
        receipt['environment'] = environment
        receipt['environment_sha256'] = hashlib.sha256(json.dumps(environment, sort_keys=True).encode()).hexdigest()
        receipt['retained_inputs_sha256'] = dict(retained_files)
        save()
        for record, child in zip(receipt['records'], children):
            current = None
            phase = 'pre_boundary:' + child['name']
            boundary()
            current = record
            record['status'] = 'RUNNING'
            record['execution_started'] = True
            phase = 'child:' + child['name']
            save()
            metadata, stdout, stderr = supervisor.run_child(dict(argv=record['argv'], cwd=record['cwd']), environment)
            # Save both untouched streams before every status/diagnostic/parser gate.
            for stream, raw in [('stdout', stdout), ('stderr', stderr)]:
                filename = child['name'] + '.' + stream + '.raw'
                raw_write(raw_dir / filename, raw)
                digest = sha(raw_dir / filename)
                raw_files[filename] = digest
                record[stream] = dict(path=(raw_dir / filename).relative_to(P).as_posix(), sha256=digest, bytes=len(raw))
            record['process'] = metadata
            record['observed_artifacts_sha256'] = inventory(artifacts)
            save()
            require(metadata['launch_error'] is None and metadata['timed_out'] is False
                    and 0 <= metadata['elapsed_seconds'] < 20, 'child launch/error/Job20 timeout')
            supervision = metadata['supervision']
            require(type(supervision['pid']) is int and supervision['pid'] > 0
                    and supervision['contained_before_resume'] is True and supervision['job_closed'] is True, 'child process-tree containment/closure failed')
            code = metadata['exit_code']
            if child['kind'] == 'reject':
                require(type(code) is int and code != 0 and REJECT_MARKER in stdout + stderr, 'named parameter rejection gate')
                record['status'] = 'EXPECTED_REJECT'
            else:
                require(code == 0 and stderr == b'', 'child process error or unexpected stderr')
                if child['kind'] in ('compile_lint', 'compile'):
                    require(stdout == b'', 'unexpected compiler stdout')
                elif child['kind'] == 'stored':
                    require(stdout == STORED_PASS, 'first stored hash/tuple checker gate')
                else:
                    require(child['kind'] == 'simulation', 'unknown child kind')
                    validate_simulation(child, stdout, copied_package)
                    receipt['validated_simulations'].append(child['name'])
                if child['kind'] == 'compile':
                    filename = child['profile'] + '.vvp'
                    produced = artifacts / filename
                    require(produced.is_file() and produced.stat().st_size > 0, 'missing fresh compiled VVP')
                    module_lines = re.findall(r'^:vpi_module "([^"]+)";', produced.read_text(encoding='utf-8'), re.MULTILINE)
                    require(len(module_lines) == 6 and len(set(module_lines)) == 6, 'expected exactly six embedded VPI module lines')
                    modules = {str(Path(n).resolve()).casefold() for n in module_lines}
                    require(modules == {str(Path(n).resolve()).casefold() for n in tools['runtime_modules_sha256']}, 'embedded VPI path set mismatch')
                    generated[filename] = sha(produced)
                    record['produced_artifact'] = dict(name=filename, sha256=generated[filename], bytes=produced.stat().st_size)
                record['status'] = 'PASS'
            phase = 'post_boundary:' + child['name']
            save()
            boundary()
        current = None
        phase = 'final_boundary'
        boundary()
        require(len(receipt['validated_simulations']) == 12 and len(generated) == 4, 'final finite counts')
        require(sum(r['status'] == 'EXPECTED_REJECT' for r in receipt['records']) == 6
                and sum(r['status'] == 'PASS' for r in receipt['records']) == 19, 'final fixed25 statuses')
        receipt.update(status='PASS_FIXED25_ROOT_QUALIFICATION', actual_children=25, carried_records=[],
                       simulations=12, named_parameter_rejects=6, successful_artifacts_retained_for_independent_review=True,
                       max_child_seconds=max(r['process']['elapsed_seconds'] for r in receipt['records']))
        save()
        phase = 'sealed_success_boundary'
        boundary()
        print('PASS A_ROOT_FIXED25 simulations=12 rejects=6')
        return 0
    except Exception as error:
        if current is not None:
            current['status'] = 'TIMEOUT' if current.get('process', {}).get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED_NO_RETRY', failure=dict(phase=phase, type=type(error).__name__, message=str(error)),
                       supervisor_invocations=sum(r['execution_started'] for r in receipt['records']),
                       not_run_children=[r['name'] for r in receipt['records'] if r['status'] == 'NOT_RUN'],
                       successful_artifacts_retained_for_independent_review=True)
        archive = dict(status='PERMANENT_PRESERVED_IN_PLACE', failure=receipt['failure'], automatic_retry=False,
                       no_cleanup_performed=True, expected_raw_streams_sha256=dict(raw_files),
                       completed_artifacts_sha256=dict(generated))
        try:
            save()
        except Exception as receipt_error:
            # Preserve an unexpected/missing old receipt rather than overwrite drift.
            archive['receipt_update_error'] = repr(receipt_error)
            json_write(attempt / 'FAILURE_RECEIPT.json', receipt, True)
        try:
            archive['files_sha256'] = inventory(attempt)
            archive['observed_artifacts_sha256'] = inventory(artifacts)
        except Exception as snapshot_error:
            archive['snapshot_error'] = repr(snapshot_error)
        json_write(attempt / 'FAILURE_ARCHIVE.json', archive, True)
        raise


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--approved-plan', required=True)
    parser.add_argument('--approval', type=Path, required=True)
    parser.add_argument('--source-seal-sha256', required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.plan, args.approved_plan, args.approval, args.source_seal_sha256))
