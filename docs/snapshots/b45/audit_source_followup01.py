"""B45 followup01 independent, once-gated metadata/byte/lexical audit.

This helper neither launches tools nor evaluates HDL, reference models, or old
audit helpers. Historical package/evidence metadata is inherited exactly; only
the 386 inherited canonical HDL sources are read again. New package formal text,
five finite receipts and their current artifacts, and 16 original VVP images are
checked. File observations are read-once with final size/mtime checks, not an
atomic cross-file snapshot. Git committed mode/type/OID proof is a root-stage task.
"""
from pathlib import Path
import copy
import datetime
import hashlib
import json
import os
import re
import sys
import traceback

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
EXCLUDED = {'.work', '.build', '__pycache__', '.git'}
BINARY = {'.vvp', '.pyc', '.pyo', '.exe', '.dll', '.so', '.a', '.o', '.obj', '.lib', '.bin'}
COUNTERS = ('preparation_children', 'hdl_children', 'hdl_pass', 'hdl_fail', 'successful_simulations')
PATHS = {}
OBSERVED = {}


def require(test, message):
    if not test:
        raise RuntimeError(message)


def path(value, base=ROOT):
    candidate = Path(str(value).replace('\\', '/'))
    candidate = candidate if candidate.is_absolute() else base / candidate
    key = os.path.normcase(os.path.abspath(candidate))
    if key not in PATHS:
        require(not candidate.is_symlink(), 'Symlink input: ' + str(candidate))
        PATHS[key] = candidate.resolve(strict=True)
    return PATHS[key]


def rel(candidate):
    require(candidate.is_relative_to(ROOT), 'Path escaped repository: ' + str(candidate))
    return candidate.relative_to(ROOT).as_posix()


def observation(candidate):
    candidate = path(candidate)
    key = os.path.normcase(str(candidate))
    if key not in OBSERVED:
        before = candidate.stat()
        require(candidate.is_file(), 'Not a regular input: ' + str(candidate))
        data = candidate.read_bytes()
        after = candidate.stat()
        require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns),
                'Changed while reading: ' + str(candidate))
        OBSERVED[key] = dict(path=candidate, sha256=hashlib.sha256(data).hexdigest(),
                             bytes=len(data), mtime_ns=after.st_mtime_ns, data=data)
    return OBSERVED[key]


def bind(candidate, expected, size=None):
    item = observation(candidate)
    require(item['sha256'] == expected, 'SHA256 mismatch: ' + str(candidate))
    require(size is None or item['bytes'] == size, 'Byte count mismatch: ' + str(candidate))
    return item


def load(candidate):
    return json.loads(observation(candidate)['data'])


def save_new(candidate, value):
    with candidate.open('x', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, indent=2, ensure_ascii=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def formal_files(package):
    result = {}
    for folder, directories, filenames in os.walk(package, followlinks=False):
        for name in directories:
            require(not (Path(folder) / name).is_symlink(), 'Symlink directory: ' + folder + '/' + name)
        directories[:] = sorted(name for name in directories if name not in EXCLUDED)
        for name in sorted(filenames):
            candidate = Path(folder) / name
            if candidate.suffix.lower() in BINARY:
                continue
            require(not candidate.is_symlink(), 'Formal symlink: ' + str(candidate))
            item = observation(candidate)
            require(b'\0' not in item['data'], 'Binary in formal text domain: ' + str(candidate))
            result[candidate.relative_to(package).as_posix()] = item['sha256']
    return dict(sorted(result.items()))


def closure(base, filename, active=None):
    active = set() if active is None else active
    candidate = path(filename, base)
    require(candidate not in active, 'Recursive filelist: ' + rel(candidate))
    active.add(candidate)
    sources = set()
    for line in observation(candidate)['data'].decode('utf-8-sig').splitlines():
        line = line.split('//', 1)[0].split('#', 1)[0].strip()
        if not line:
            continue
        if line.startswith('-f '):
            sources.update(closure(base, line[3:].strip(), active))
        else:
            require(not line.startswith(('-', '+')) and len(line.split()) == 1,
                    'Unsupported filelist entry: ' + line)
            source = path(line, base)
            require(source.suffix.lower() in ('.v', '.sv'), 'Non-HDL filelist entry: ' + line)
            sources.add(rel(source))
    active.remove(candidate)
    return sources


def canonical_audit(parent, inherited_structure, plan):
    expected = {}

    for package in parent['packages']:
        for name, digest in package['sha256'].items():
            # Do not resolve or read inherited evidence paths merely to build metadata.
            name = os.path.normpath(package['path'] + '/' + name).replace('\\', '/')
            require(name not in expected or expected[name] == digest, 'Conflicting parent metadata: ' + name)
            expected[name] = digest
    for name, digest in parent['support_files'].items():
        require(name not in expected or expected[name] == digest, 'Conflicting support metadata: ' + name)
        expected[name] = digest
    for name, item in parent['batch_canonical_base_sources'].items():
        require(name not in expected or expected[name] == item['sha256'], 'Conflicting bridge metadata: ' + name)
        expected[name] = item['sha256']
    inherited = inherited_structure['canonical_source_paths']
    require(len(inherited) == len(set(inherited)) == 386, 'Inherited canonical path count')
    canonical_hashes = {}
    for name in inherited:
        require(name in expected, 'Missing inherited canonical hash: ' + name)
        canonical_hashes[name] = bind(path(name), expected[name])['sha256']
    aliases = {item['alias']: item['canonical'] for item in parent['exact_byte_dependency_aliases']}
    require(len(aliases) == 2, 'Inherited exact-byte alias count')
    for item in parent['exact_byte_dependency_aliases']:
        bind(path(item['canonical']), item['sha256'], item['bytes'])
    new = sorted(name for spec in plan['packages'] for name in spec['canonical_sources'])
    require(len(new) == len(set(new)) == 8 and not set(new).intersection(inherited), 'New canonical path count')
    for name in new:
        canonical_hashes[name] = bind(path(name), plan['input_sha256'][name])['sha256']
    all_sources = set(inherited) | set(new)
    declarations = {}
    declaration_count = 0
    for name in sorted(all_sources):
        text = observation(path(name))['data'].decode('utf-8-sig')
        text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
        modules = re.findall(r'(?m)^\s*module\s+(?:automatic\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\b', text)
        require(modules, 'Canonical source has no module declaration: ' + name)
        declaration_count += len(modules)
        for module in modules:
            declarations.setdefault(module, []).append(name)
    collisions = {name: names for name, names in declarations.items() if len(names) != 1}
    require(len(all_sources) == 394 and declaration_count == 396 and not collisions, 'Canonical lexical inventory')
    closures = copy.deepcopy(inherited_structure['source_list_closures'])
    historical = {}
    for spec in plan['packages']:
        require(spec['top'] in declarations, 'Missing package top: ' + spec['top'])
        for example in spec['examples']:
            require(declarations.get(example['top']) == [spec['path'] + '/' + example['file']],
                    'Example module mapping: ' + example['top'])
        for item in spec['source_lists']:
            sources = closure(path(item['base']), item['file'])
            require(sorted(sources) == item['expected_raw_sources'], 'Filelist closure differs: ' + item['file'])
            resolved = {aliases.get(name, name) for name in sources}
            require(resolved <= all_sources, 'Unclassified canonical closure: ' + item['file'])
            closures[rel(path(item['file'], path(item['base'])))] = sorted(resolved)
        for item in spec.get('historical_source_lists', []):
            sources = closure(path(item['base']), item['file'])
            require(sorted(sources) == item['expected_raw_sources'], 'Historical closure differs')
            historical[rel(path(item['file'], path(item['base'])))] = dict(
                sources=sorted(sources), canonical=False, reason='Retained failed original A attempt')
    return dict(canonical_source_paths=sorted(all_sources), canonical_source_sha256=canonical_hashes,
                new_canonical_sources=new, source_files=394, module_declarations=396,
                module_paths=declarations, unresolved_module_collisions=collisions,
                source_list_closures=closures, retained_historical_source_list_closures=historical,
                exact_byte_dependency_aliases=copy.deepcopy(parent['exact_byte_dependency_aliases']))


def source_pairs(receipt, spec, package, folder):
    pairs = []
    if spec['role'] == 'A':
        for item in receipt['sources']:
            pairs.append((path(item['path']), path(item['archive'], folder), item['sha256'], item['bytes']))
    elif spec['role'] in ('B', 'C'):
        for name, digest in receipt['source_sha256'].items():
            pairs.append((path(name), path(receipt['archived_sources'][name], package), digest, None))
    else:
        for name, digest in receipt['source_inputs_sha256'].items():
            pairs.append((path(name, package), path(receipt['archived_inputs'][name], package), digest, None))
    for current, archive, digest, size in pairs:
        bind(current, digest, size)
        bind(archive, digest, size)
    return len(pairs)


def audit_receipt(spec, plan, images):
    candidate = path(spec['receipt'])
    receipt = load(candidate)
    folder = candidate.parent
    package = path(spec['package'])
    for item in spec['control_bindings']:
        bind(path(item['path']), receipt[item['receipt_field']])
    require(receipt['status'] == spec['status'], 'Receipt status: ' + spec['receipt'])
    require(receipt.get('active_child') is None and receipt.get('active_helper') is None,
            'Receipt has active process: ' + spec['receipt'])
    archive_proof = 'RECEIPT_ARCHIVE_COMPLETE_FLAG'
    archive_complete = receipt.get('archive_complete') is True
    if spec['role'] == 'C':
        seal_bindings = [item for item in spec['control_bindings'] if item['receipt_field'] == 'source_seal_sha256']
        require(len(seal_bindings) == 1, 'C unique archived seal binding')
        archived_seal = load(path(seal_bindings[0]['path']))
        current_sources = receipt['source_sha256']
        archived_sources = receipt['archived_sources']
        archive_complete = (len(current_sources) == 25 and set(archived_sources) == set(current_sources)
                            and all(isinstance(name, str) and name for name in archived_sources.values())
                            and archived_seal['source_sha256'] == current_sources)
        archive_proof = 'DERIVED_25_SOURCE_KEYS_EQUAL_PINNED_ARCHIVED_SEAL_AND_POSITIVE_BYTE_PAIRS'
    require(receipt.get('automatic_retry') is False and archive_complete,
            'Receipt retry/archive state: ' + spec['receipt'])
    if spec['status'] == 'PASS':
        require(receipt['suite_complete'] is True, 'Incomplete successful suite')
    pair_count = source_pairs(receipt, spec, package, folder)
    tools = receipt.get('tools_sha256', receipt.get('tools'))
    if isinstance(tools, list):
        tools = {item['path']: item['sha256'] for item in tools}
    for name, digest in tools.items():
        require(plan['tool_sha256'][name] == digest, 'Tool metadata disagreement: ' + name)
        bind(path(name), digest)
    children = receipt.get('children')
    if children is None:
        children = receipt['preparations'] + receipt['checks']
    archived_plan = load(path(spec['archived_plan']))
    planned = archived_plan.get('children')
    if planned is None:
        planned = archived_plan.get('preparations', []) + archived_plan.get('checks', [])
    actual_planned = children
    require(len(actual_planned) <= len(planned), 'More children than archived plan')
    require(spec['status'] != 'PASS' or len(actual_planned) == len(planned), 'Incomplete archived plan sequence')

    def materialize(value):
        if isinstance(value, str):
            return value.replace('<stamp>', folder.name)
        if isinstance(value, list):
            return [materialize(item) for item in value]
        if isinstance(value, dict):
            return {key: materialize(item) for key, item in value.items()}
        return value

    for child, expected_child in zip(actual_planned, planned):
        for key, value in materialize(expected_child).items():
            if key in ('name', 'kind', 'argv', 'cwd', 'marker', 'hard_seconds', 'tree_kill_seconds',
                       'drain_seconds', 'execution_seconds', 'sole_exit_observation_seconds',
                       'execution_deadline_seconds'):
                require(child.get(key) == value, 'Archived plan field/order: ' + child['name'] + '/' + key)
    totals = dict.fromkeys(COUNTERS, 0)
    compiled = {}
    executed = []
    raw_count = 0
    require(len({child['name'] for child in children}) == len(children), 'Duplicate child names')
    for child in children:
        name = child['name']
        preparation = child['kind'] == 'PREPARATION'
        simulation = 'SIMULATION' in child['kind'] or name.startswith(('sim_', 'simulate_', 'sim0', 'sim1', 'sim2', 'sim3', 'sim4'))
        totals['preparation_children' if preparation else 'hdl_children'] += 1
        code = child.get('exit_code', child.get('returncode'))
        failed = spec['role'] == 'A' and spec['phase'] == 'initial' and name == 'syntax_d32_t1'
        require(child['status'] == ('FAIL' if failed else 'PASS') and code == (2 if failed else 0),
                'Child exit/status: ' + spec['receipt'] + '/' + name)
        if not preparation:
            totals['hdl_fail' if failed else 'hdl_pass'] += 1
        require(isinstance(child.get('pid'), int) and child['pid'] > 0 and not child['cleanup'], 'Child PID/cleanup: ' + name)
        require(child.get('process_exited', child.get('exit_confirmed')) is True,
                'Unconfirmed child exit: ' + name)
        require(child.get('output_capture_complete', child.get('raw_finalized')) is True
                and child['process_evidence_saved'] is True, 'Incomplete raw evidence: ' + name)
        require(child.get('active_child') is None and not child.get('timed_out') and not child.get('capture_errors'),
                'Child terminal state: ' + name)
        elapsed = child.get('execution_elapsed_seconds', child.get('elapsed_seconds', child.get('execution_seconds')))
        require(isinstance(elapsed, (float, int)) and 0 <= elapsed < 20, 'Child 20s bound: ' + name)
        require(child.get('tree_kill_seconds') == 5 and child.get('drain_seconds', child.get('sole_exit_observation_seconds')) == 2,
                'Child cleanup bounds: ' + name)
        raw = {}
        for stream in ('stdout', 'stderr'):
            if isinstance(child.get(stream), dict):
                item = child[stream]
                base = package if spec['role'] == 'C' else folder
                item = bind(path(item['path'], base), item['sha256'], item['bytes'])
            else:
                item = bind(folder / (name + '.' + stream + '.raw'), child[stream + '_sha256'], child[stream + '_bytes'])
            raw[stream] = item['data'].decode('utf-8', errors='replace')
            raw_count += 1
        marker = child.get('marker') or ('PASS profile ' if spec['role'] == 'root' and simulation else None)
        if marker and not failed:
            require(raw['stdout'].count(marker) == 1, 'Raw PASS marker: ' + name)
        if '-o' in child['argv'] and not failed:
            image = path(child['argv'][child['argv'].index('-o') + 1], path(child['cwd']))
            digest = child.get('compiled_image_sha256', child.get('image_sha256'))
            require(digest is not None, 'Missing compiled image hash: ' + name)
            bind(image, digest)
            compiled[rel(image)] = digest
        if simulation:
            require(not preparation and not failed and marker, 'Simulation classification: ' + name)
            image = path(child['argv'][1], path(child['cwd']))
            digest = child.get('execution_image_sha256', child.get('executed_image_sha256'))
            require(compiled.get(rel(image)) == digest, 'Compile/execute image linkage: ' + name)
            bind(image, digest)
            require(rel(image) not in images, 'Repeated successful image path: ' + name)
            images[rel(image)] = dict(sha256=digest, successful_simulation=True, failed_simulation=False,
                                     receipt=spec['receipt'], child=name, original_image_retained=True)
            executed.append(rel(image))
            require(not raw['stderr'] and '$finish called' in raw['stdout'], 'Simulation stderr/finish: ' + name)
            observed = child.get('observed')
            if isinstance(observed, dict):
                tokens = dict(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)', raw['stdout']))
                for key, value in observed.items():
                    require(tokens.get(key) == str(value), 'Raw observed counter: ' + name + '/' + key)
            elif isinstance(observed, str):
                require(observed in raw['stdout'], 'Raw observed line: ' + name)
            totals['successful_simulations'] += 1
    require(totals == spec['expected_counts'], 'Actual finite counts: ' + spec['receipt'])
    for name, digest in receipt.get('child_records', {}).items():
        child_path = path(name, package if spec['role'] == 'C' else folder)
        bind(child_path, digest)
        saved = load(child_path)
        matches = [child for child in children if child['name'] == saved['name']]
        require(len(matches) == 1 and saved == matches[0], 'Saved child record disagreement: ' + name)
    for name, digest in receipt.get('images', receipt.get('compiled_images', {})).items():
        image = path(name, package)
        require(compiled.get(rel(image)) == digest, 'Aggregate image disagreement: ' + name)
        bind(image, digest)
    return dict(role=spec['role'], phase=spec['phase'], path=spec['receipt'],
                sha256=observation(candidate)['sha256'], status=spec['status'],
                source_archive_pairs=pair_count, archive_complete=True, archive_proof=archive_proof, raw_streams=raw_count,
                retained_successful_images=executed, **totals)


def audit(plan):
    for name, digest in plan['input_sha256'].items():
        require(rel(path(name)) == name, 'Noncanonical plan input path: ' + name)
        bind(path(name), digest)
    for name, digest in plan['tool_sha256'].items():
        bind(path(name), digest)
    parent = load(path(plan['parent_snapshot']))
    inherited_structure = load(path(plan['parent_structure']))
    require(len(parent['packages']) == 176 and len(parent['support_files']) == 29,
            'Inherited package/support count')
    structural = canonical_audit(parent, inherited_structure, plan)
    new_packages = []
    for spec in plan['packages']:
        files = formal_files(path(spec['path']))
        require(files == spec['formal_sha256'], 'Formal file set/hash changed: ' + spec['path'])
        require('DELIVERY.md' in files and 'QUALIFICATION.json' in files, 'Missing final delivery')
        new_packages.append(dict(path=spec['path'], top=spec['top'], baseline_commit=plan['baseline_commit'],
            evidence='QUALIFICATION.json', evidence_kind='b45_bounded_receipts_with_retained_initial_failure',
            hardware_status='HW_UNVERIFIED', examples=spec['examples'], sha256=files, formal_files=len(files),
            actual_source_lists=[dict(base=item['base'], file=item['file']) for item in spec['source_lists']]))
    images = {}
    receipts = [audit_receipt(spec, plan, images) for spec in plan['attempts']]
    totals = {key: sum(item[key] for item in receipts) for key in COUNTERS}
    require(totals == plan['expected_counts'] and len(images) == 16, 'Aggregate actual finite counts/images')
    scope = dict(inherited_package_objects='EXACT_JSON_METADATA_INHERITANCE_176',
        inherited_support_mapping='EXACT_JSON_METADATA_INHERITANCE_29',
        inherited_canonical_raw_sources_rehashed=386, historical_raw_evidence_rehashed=False,
        historical_raw_evidence_scope='Inherited parent metadata only; no historical ~16k raw file re-audit',
        new_package_formal_text='Exact file-set and raw-byte SHA256 check, retaining archives and failed files',
        current_evidence='Five pinned receipts, source/archive pairs, terminal child/raw metadata and image linkage',
        support_hash_domains='Inherited unchanged explicit B44 bridge; no generic normalization or raw-equality claim',
        observation='Cached read-once bytes, final size/mtime stability checks; no cross-file atomicity claim',
        git_committed_mode_type_oid_proof='DEFERRED_TO_ROOT_STAGE_AND_CLOSEOUT',
        model_imports=0, hdl_executions=0, subprocesses=0, synthesis=False, pnr=False, sta=False, board=False, ppa=False)
    source = copy.deepcopy(parent)
    source['date'] = plan['date']
    source['baseline_commit'] = plan['baseline_commit']
    source['batch_baseline_commit'] = plan['baseline_commit']
    source['previous_snapshot'] = plan['parent_snapshot']
    source['packages'].extend(new_packages)
    source['parent_snapshot'] = dict(path=plan['parent_snapshot'], sha256=plan['input_sha256'][plan['parent_snapshot']])
    source['batch_evidence_receipts'] = receipts
    source['batch_actual_counts'] = totals
    source['batch_static_audit'] = dict(status='PASS', batch='B45', scope=scope)
    source['source_freeze'] = 'B45_RAW_BYTE_INPUTS_AND_EXACT_INHERITED_METADATA'
    source['batch_status'] = 'SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_WITH_RETAINED_FAILURE_HW_UNVERIFIED'
    require(source['packages'][:176] == parent['packages'] and source['support_files'] == parent['support_files'],
            'Inherited package/support objects changed')
    require(source['baseline_text_normalizations'] == parent['baseline_text_normalizations'] and
            source['batch_root_support_hash_domains'] == parent['batch_root_support_hash_domains'],
            'Inherited explicit hash-domain qualifications changed')
    source['batch_static_audit']['retained_prior_static_attempt'] = plan['prior_static_attempt']
    structure = dict(schema='anscore-b45-independent-static-followup01-v1', status='PASS', packages=180,
        inherited_package_objects_exact=176, inherited_support_mapping_exact=True,
        actual_finite_counts=totals, evidence_receipts=receipts, retained_images=dict(sorted(images.items())),
        scope=scope, retained_prior_static_attempt=plan['prior_static_attempt'],
        parent_snapshot=source['parent_snapshot'], input_sha256=plan['input_sha256'],
        tool_sha256=plan['tool_sha256'], **structural)
    # These are stability checks, not repeated hashes or a cross-file atomicity proof.
    for item in OBSERVED.values():
        current = item['path'].stat()
        require((current.st_size, current.st_mtime_ns) == (item['bytes'], item['mtime_ns']),
                'Input changed after observation: ' + str(item['path']))
    return source, structure


def main():
    require(sys.argv[1:] == ['--execute-approved-plan'], 'Exact approved CLI required')
    plan_path, review_path = HERE / 'plan_followup01.json', HERE / 'root_review_followup01.json'
    plan, review = load(plan_path), load(review_path)
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['root'] == review['peer'] == 'NO_BLOCKER',
            'Root and peer source review required')
    require(review['peer_reviewer'] == 'worker_b' and review['execution_gate'] == 'B45_STATIC_FOLLOWUP01_ONCE_01',
            'Unique B45 static execution gate required')
    bind(plan_path, review['plan_sha256'])
    bind(Path(__file__), review['helper_sha256'])
    bind(path(plan['launcher']), review['launcher_sha256'])
    require(plan['schema'] == 'anscore-b45-static-plan-followup01-v1' and plan['automatic_retry'] is False,
            'Plan schema/retry policy')
    require(plan['outputs'] == ['source.json', 'structure.json', 'audit_followup01_once.json', 'failure_followup01.json'], 'Output path plan')
    require(all(not (HERE / name).exists() for name in plan['outputs']), 'Output/once guard already exists')
    save_new(HERE / 'audit_followup01_once.json', dict(schema='anscore-b45-static-followup01-once-v1', status='ATTEMPT_STARTED',
        plan_sha256=review['plan_sha256'], helper_sha256=review['helper_sha256'],
        review_sha256=observation(review_path)['sha256'], launcher_sha256=review['launcher_sha256'],
        automatic_retry=False, started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat()))
    try:
        source, structure = audit(plan)
        structure['control_sha256'] = dict(plan=review['plan_sha256'], helper=review['helper_sha256'],
            review=observation(review_path)['sha256'], launcher=review['launcher_sha256'])
        save_new(HERE / 'source.json', source)
        save_new(HERE / 'structure.json', structure)
        print('B45_STATIC_FOLLOWUP01_PASS packages=180 source_files=394 module_declarations=396 preparation_children=14 hdl_children=43 successful_simulations=16')
        return 0
    except Exception:
        save_new(HERE / 'failure_followup01.json', dict(status='FAIL_STOP', exception=traceback.format_exc(), automatic_retry=False))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
