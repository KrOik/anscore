"""B46 independent metadata/byte/lexical snapshot audit. No subprocesses, model imports or HDL execution. Historical B45 package/support metadata is inherited exactly; 394 canonical raw HDL files are rehashed with eight new sources. All B46 formal text, retained failed and successful receipts, source/archive pairs, terminal raw streams and original VVP images are bound. Read-once bytes plus final size/mtime checks do not claim an atomic cross-file snapshot."""
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
ROOT = HERE.parents[3]
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
    require(len(inherited) == len(set(inherited)) == 394, 'Inherited canonical path count')
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
    bridges = plan['existing_worktree_dependency_bridges']
    require(len(bridges) == 1, 'Exactly one existing worktree dependency bridge')
    bridge_paths = {item['path'] for item in bridges}
    require(len(bridge_paths) == 1 and not bridge_paths.intersection(set(inherited) | set(new)), 'Bridge source uniqueness')
    for item in bridges:
        require(item['path'] == 'cores/acceleration/stream_phase_unwrap/rtl/stream_phase_unwrap.sv'
                and item['module'] == 'stream_phase_unwrap' and item['new_capability'] is False,
                'Exact existing dependency bridge identity')
        canonical_hashes[item['path']] = bind(path(item['path']), item['sha256'], item['bytes'])['sha256']
    all_sources = set(inherited) | set(new) | bridge_paths
    declarations = {}
    declaration_count = 0
    for name in sorted(all_sources):
        text = observation(path(name))['data'].decode('utf-8-sig')
        text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
        modules = re.findall(r'(?m)^\s*module\s+(?:automatic\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\b', text)
        require(modules, 'Canonical source has no module declaration: ' + name)
        if name in bridge_paths:
            require(modules == ['stream_phase_unwrap'], 'Bridge module declaration identity')
        declaration_count += len(modules)
        for module in modules:
            declarations.setdefault(module, []).append(name)
    collisions = {name: names for name, names in declarations.items() if len(names) != 1}
    require(len(all_sources) == 403 and declaration_count == 405 and not collisions, 'Canonical lexical inventory')
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
    return dict(canonical_source_paths=sorted(all_sources), canonical_sources=sorted(all_sources), canonical_source_sha256=canonical_hashes,
                existing_worktree_dependency_bridges=copy.deepcopy(bridges),
                new_canonical_sources=new, source_files=403, module_declarations=405,
                module_paths=declarations, unresolved_module_collisions=collisions,
                source_list_closures=closures, retained_historical_source_list_closures=historical,
                exact_byte_dependency_aliases=copy.deepcopy(parent['exact_byte_dependency_aliases']))


def source_pairs(receipt, spec, package, folder):
    pairs = []
    if spec['role'] == 'A':
        for item in receipt['sources']:
            pairs.append((path(item['path']), path(item['archive'], folder), item['sha256'], item['bytes']))
    elif spec['role'] in ('B', 'C'):
        require(set(receipt['source_sha256']) == set(receipt['archived_sources']), 'Source/archive key mismatch')
        for name, digest in receipt['source_sha256'].items():
            pairs.append((path(name), path(receipt['archived_sources'][name], path(spec['artifact_base'])), digest, None))
    else:
        require(set(receipt['source_inputs_sha256']) == set(receipt['archived_inputs']), 'Root source/archive key mismatch')
        for name, digest in receipt['source_inputs_sha256'].items():
            pairs.append((path(name, package), path(receipt['archived_inputs'][name], package), digest, None))
    require(len(pairs) == spec['expected_source_pairs'], 'Source/archive pair count')
    for current, archive, digest, size in pairs:
        bind(current, digest, size)
        bind(archive, digest, size)
    for name, item in receipt.get('prerequisite_files', {}).items():
        bind(path(name), item['sha256'], item['bytes'])
    return len(pairs)


def materialize(value, stamp):
    if isinstance(value, str):
        return value.replace('<stamp>', stamp)
    if isinstance(value, list):
        return [materialize(item, stamp) for item in value]
    if isinstance(value, dict):
        return {key: materialize(item, stamp) for key, item in value.items()}
    return value


def audit_receipt(spec, plan, images):
    candidate = path(spec['receipt'])
    receipt = load(candidate)
    folder, package, artifact_base = candidate.parent, path(spec['package']), path(spec['artifact_base'])
    require(receipt['status'] == spec['status'], 'Receipt status: ' + spec['receipt'])
    require(receipt.get('active_child') is None and receipt.get('active_helper') is None and not receipt.get('active_helpers'),
            'Active process in receipt: ' + spec['receipt'])
    require(receipt.get('automatic_retry') is False and receipt.get('archive_complete') is True, 'Receipt retry/archive state')
    require(receipt.get('inputs_unchanged') is spec['retained_inputs_unchanged_flag'], 'Retained unchanged flag differs')
    if spec['status'] == 'PASS':
        require(receipt['suite_complete'] is True and receipt['exact_plan_executed'] is True, 'Incomplete successful suite')
    else:
        require(receipt['suite_complete'] is False, 'Failed receipt marked complete')
    for item in spec['control_bindings']:
        bind(path(item['path']), receipt[item['receipt_field']])
    pair_count = source_pairs(receipt, spec, package, folder)
    tools = receipt.get('tools_sha256', receipt.get('tools'))
    if isinstance(tools, list):
        tools = {item['path']: item['sha256'] for item in tools}
    for name, digest in tools.items():
        require(plan['tool_sha256'][name] == digest, 'Tool metadata disagreement: ' + name)
        bind(path(name), digest)
    children = receipt.get('children')
    if children is None:
        children = receipt.get('preparations', []) + receipt.get('checks', [])
    archived_plan = load(path(spec['archived_plan']))
    planned = archived_plan.get('children', archived_plan.get('commands'))
    require(isinstance(planned, list), 'Missing archived finite commands')
    require(len(children) <= len(planned), 'More children than planned')
    require(spec['status'] != 'PASS' or len(children) == len(planned), 'Incomplete successful command sequence')
    fields = ('name', 'kind', 'argv', 'cwd', 'marker', 'hard_seconds', 'tree_kill_seconds', 'drain_seconds', 'execution_deadline_seconds')
    for child, expected in zip(children, planned):
        expected = materialize(expected, folder.name)
        for key in fields:
            if key in expected:
                require(child.get(key) == expected[key], 'Archived plan/order: ' + child['name'] + '/' + key)
    totals, compiled, executed, raw_count = dict.fromkeys(COUNTERS, 0), {}, [], 0
    require(len({child['name'] for child in children}) == len(children), 'Duplicate child names')
    for child in children:
        name = child['name']
        preparation = child['kind'] == 'PREPARATION'
        simulation = child['kind'] == 'HDL_SIMULATION' or name.startswith(('sim_', 'simulate_'))
        failed = name in spec['failed_children']
        expected_code = spec['failed_children'].get(name, 0)
        require(child['status'] == ('FAIL' if failed else 'PASS') and child.get('exit_code', child.get('returncode')) == expected_code,
                'Child status/exit: ' + spec['receipt'] + '/' + name)
        totals['preparation_children' if preparation else 'hdl_children'] += 1
        if not preparation:
            totals['hdl_fail' if failed else 'hdl_pass'] += 1
        require(isinstance(child.get('pid'), int) and child['pid'] > 0 and not child['cleanup'], 'Child PID/cleanup: ' + name)
        require(child.get('process_exited', child.get('exit_confirmed')) is True and child.get('output_capture_complete') is True
                and child.get('process_evidence_saved') is True, 'Child exit/capture evidence: ' + name)
        require(child.get('active_child') is None and not child.get('timed_out') and not child.get('capture_errors'), 'Nonterminal child: ' + name)
        elapsed = child.get('execution_seconds', child.get('elapsed_seconds'))
        require(isinstance(elapsed, (int, float)) and 0 <= elapsed < 20, 'Child time bound: ' + name)
        require(child['tree_kill_seconds'] == 5 and child['drain_seconds'] == 2, 'Child cleanup bounds: ' + name)
        raw = {}
        for stream in ('stdout', 'stderr'):
            entry = child[stream]
            item = bind(path(entry['path'], artifact_base if spec['role'] in ('B', 'C') else folder), entry['sha256'], entry['bytes'])
            raw[stream] = item['data'].decode('utf-8', errors='replace')
            raw_count += 1
        marker = child.get('marker') or ('PASS SE ' if spec['role'] == 'root' and simulation else None)
        if marker and not failed:
            require(raw['stdout'].count(marker) == 1, 'PASS marker: ' + name)
        if failed:
            require(spec['failure_raw_text'] in raw['stdout'] + raw['stderr'], 'Retained failure diagnostic: ' + name)
        if '-o' in child['argv'] and not failed:
            image = path(child['argv'][child['argv'].index('-o') + 1], path(child['cwd']))
            digest = child.get('compiled_image_sha256', child.get('image_sha256'))
            require(digest is not None, 'Missing compiled image hash: ' + name)
            bind(image, digest)
            compiled[rel(image)] = digest
        if simulation:
            require(not preparation, 'Preparation classified as simulation')
            image = path(child['argv'][1], path(child['cwd']))
            digest = child.get('execution_image_sha256', child.get('executed_image_sha256'))
            require(digest is not None and compiled.get(rel(image)) == digest, 'Compile/execute image linkage: ' + name)
            bind(image, digest)
            require(rel(image) not in images, 'Duplicate original image path')
            images[rel(image)] = dict(sha256=digest, successful_simulation=not failed, failed_simulation=failed,
                receipt=spec['receipt'], child=name, original_image_retained=True)
            executed.append(rel(image))
            if not failed:
                require(marker and not raw['stderr'] and '$finish called' in raw['stdout'], 'Simulation marker/stderr/finish: ' + name)
                observed = child.get('observed')
                require(isinstance(observed, dict), 'Missing simulation counters: ' + name)
                tokens = dict(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)', raw['stdout']))
                require(all(tokens.get(key) == str(value) for key, value in observed.items()), 'Raw counter mismatch: ' + name)
                if 'expected' in child:
                    require(observed == child['expected'], 'Expected counter mismatch: ' + name)
                totals['successful_simulations'] += 1
    require(set(spec['failed_children']) == {child['name'] for child in children if child['status'] == 'FAIL'}, 'Failure set')
    require(totals == spec['expected_counts'], 'Actual finite counts: ' + spec['receipt'])
    records = receipt['child_records']
    require(len(records) == len(children), 'Terminal child record count')
    saved_names = set()
    for name, entry in records.items():
        expected = entry['sha256'] if isinstance(entry, dict) else entry
        size = entry.get('bytes') if isinstance(entry, dict) else None
        child_path = path(name, artifact_base if spec['role'] in ('B', 'C') else folder)
        bind(child_path, expected, size)
        saved = load(child_path)
        matches = [child for child in children if child['name'] == saved['name']]
        require(len(matches) == 1 and saved == matches[0], 'Terminal record disagreement: ' + name)
        saved_names.add(saved['name'])
    require(saved_names == {child['name'] for child in children}, 'Terminal record coverage')
    for name, digest in receipt.get('images', {}).items():
        image = path(name, artifact_base if spec['role'] in ('B', 'C') else package)
        require(compiled.get(rel(image)) == digest, 'Aggregate image disagreement')
        bind(image, digest)
    if spec['role'] == 'root':
        for item in receipt['profiles'].values():
            bind(path(item['file']), item['sha256'], item['bytes'])
    elif spec['role'] == 'A':
        for item in receipt['vectors']:
            bind(path(item['path'], path(spec['vector_base'])), item['sha256'], item['bytes'])
    else:
        for name, digest in receipt.get('vectors', {}).items():
            bind(path(name, artifact_base), digest)
        for name, entry in receipt.get('raw_evidence', {}).items():
            bind(path(name, artifact_base), entry['sha256'], entry['bytes'])
    return dict(role=spec['role'], phase=spec['phase'], path=spec['receipt'], sha256=observation(candidate)['sha256'],
        status=spec['status'], source_archive_pairs=pair_count, archive_complete=True,
        archive_proof='INDEPENDENT_EXACT_CURRENT_ARCHIVE_HASH_AND_BYTES', retained_inputs_unchanged_flag=receipt.get('inputs_unchanged'),
        raw_streams=raw_count, retained_original_images=executed, **totals)


def verify_prior_static(plan):
    prior = plan['prior_static_attempt']
    for item in prior['files']:
        bind(path(item['path']), item['sha256'], item['bytes'])
        bind(path(item['archive']), item['sha256'], item['bytes'])
    receipt = load(path(prior['receipt']))
    require(receipt['status'] == 'FAIL_STOP' and receipt['suite_complete'] is False and receipt['automatic_retry'] is False,
            'Original static attempt failure state')
    require(receipt['active_child'] is None and receipt['active_helper'] is None and not receipt['active_helpers'],
            'Original static attempt still active')
    require(receipt['inputs_unchanged'] is False and len(receipt['children']) == 1, 'Retained original static flags')
    child = receipt['children'][0]
    require(child['status'] == 'FAIL' and child['exit_code'] == 1 and child['process_exited'] is True
            and child['output_capture_complete'] is True and child['process_evidence_saved'] is True
            and not child['cleanup'] and 0 <= child['execution_seconds'] < 20, 'Original static child terminal state')
    folder = path(prior['receipt']).parent
    for stream in ('stdout', 'stderr'):
        item = child[stream]
        bind(path(item['path'], folder), item['sha256'], item['bytes'])
    require(load(folder / 'static_audit.json') == child, 'Original static terminal JSON disagrees')
    failure = load(path(prior['failure']))
    require(failure['status'] == 'FAIL_STOP' and 'Unclassified canonical closure: files.f' in failure['exception'],
            'Original static failure diagnostic')
    old_plan = load(path(prior['plan']))
    require(receipt['input_sha256'] == old_plan['input_sha256'], 'Original static input pin map disagrees')
    for name, expected in old_plan['input_sha256'].items():
        bind(path(name), expected)
    for name, expected in old_plan['tool_sha256'].items():
        bind(path(name), expected)


def audit(plan):
    for name, digest in plan['input_sha256'].items():
        require(rel(path(name)) == name, 'Noncanonical plan input: ' + name)
        bind(path(name), digest)
    for name, digest in plan['tool_sha256'].items():
        bind(path(name), digest)
    verify_prior_static(plan)
    parent, inherited_structure = load(path(plan['parent_snapshot'])), load(path(plan['parent_structure']))
    require(len(parent['packages']) == 180 and len(parent['support_files']) == 29, 'Inherited metadata counts')
    structural = canonical_audit(parent, inherited_structure, plan)
    new_packages = []
    for spec in plan['packages']:
        files = formal_files(path(spec['path']))
        require(files == spec['formal_sha256'], 'Formal set/hash changed: ' + spec['path'])
        require('DELIVERY.md' in files and 'QUALIFICATION.json' in files, 'Missing final delivery files')
        new_packages.append(dict(path=spec['path'], top=spec['top'], baseline_commit=plan['baseline_commit'], evidence='QUALIFICATION.json',
            evidence_kind='b46_bounded_receipts_with_retained_initial_and_followup_failures', hardware_status='HW_UNVERIFIED',
            examples=spec['examples'], sha256=files, formal_files=len(files),
            actual_source_lists=[dict(base=item['base'], file=item['file']) for item in spec['source_lists']]))
    images = {}
    receipts = [audit_receipt(spec, plan, images) for spec in plan['attempts']]
    totals = {key: sum(item[key] for item in receipts) for key in COUNTERS}
    require(totals == plan['expected_counts'] and len(images) == 22, 'Aggregate finite counts/images')
    require(sum(item['successful_simulation'] for item in images.values()) == 19 and sum(item['failed_simulation'] for item in images.values()) == 3,
            'Retained successful/failed image counts')
    scope = dict(inherited_package_objects='EXACT_JSON_METADATA_INHERITANCE_180', inherited_support_mapping='EXACT_JSON_METADATA_INHERITANCE_29',
        inherited_canonical_raw_sources_rehashed=394, historical_raw_evidence_rehashed=False,
        historical_raw_evidence_scope='B45 and earlier metadata inherited; no historical helper/model execution or raw evidence re-audit',
        new_package_formal_text='Exact file-set/raw-byte SHA256 including raw and archives; every .work/.build/__pycache__ and binary suffix excluded',
        current_evidence='Eight HDL receipts, current/archive pairs, terminal JSON/raw streams, 22 original VVP images including 3 failed simulations, retained initial static FAIL',
        existing_worktree_dependency_bridge='One exact 1807-byte stream_phase_unwrap source newly delivered this batch, not a new capability or inherited committed source',
        failed_receipt_inputs_unchanged='Retained literal flags including B false; independent current/archive hash closure proves actual unchanged inputs',
        observation='Cached read-once bytes with final size/mtime stability checks; not a cross-file atomic snapshot',
        git_committed_mode_type_oid_proof='DEFERRED_TO_ROOT_STAGE_AND_CLOSEOUT', model_imports=0, hdl_executions=0, subprocesses=0,
        synthesis=False, pnr=False, sta=False, board=False, ppa=False)
    source = copy.deepcopy(parent)
    source.update(date=plan['date'], baseline_commit=plan['baseline_commit'], batch_baseline_commit=plan['baseline_commit'],
        previous_snapshot=plan['parent_snapshot'], parent_snapshot=dict(path=plan['parent_snapshot'], sha256=plan['input_sha256'][plan['parent_snapshot']]),
        batch_evidence_receipts=receipts, batch_actual_counts=totals, batch_static_audit=dict(status='PASS', batch='B46', scope=scope),
        source_freeze='B46_RAW_BYTE_INPUTS_AND_EXACT_INHERITED_METADATA',
        batch_status='SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_WITH_RETAINED_FAILURES_HW_UNVERIFIED')
    source['packages'].extend(new_packages)
    previous_bridges = copy.deepcopy(parent['batch_canonical_base_sources'])
    require(len(previous_bridges) == 12, 'Twelve inherited bridge objects')
    source['batch_canonical_base_sources'] = copy.deepcopy(previous_bridges)
    for item in plan['existing_worktree_dependency_bridges']:
        require(item['path'] not in source['batch_canonical_base_sources'], 'Existing bridge overwritten')
        source['batch_canonical_base_sources'][item['path']] = {key: copy.deepcopy(value) for key, value in item.items() if key != 'path'}
    require(all(source['batch_canonical_base_sources'][name] == value for name, value in previous_bridges.items())
            and len(source['batch_canonical_base_sources']) == 13, 'Inherited bridge metadata changed')
    source['batch_static_audit']['retained_prior_static_attempt'] = copy.deepcopy(plan['prior_static_attempt'])
    require(source['packages'][:180] == parent['packages'] and source['support_files'] == parent['support_files'], 'Inherited package/support objects changed')
    require(source['baseline_text_normalizations'] == parent['baseline_text_normalizations'] and
            source['batch_root_support_hash_domains'] == parent['batch_root_support_hash_domains'], 'Inherited hash-domain qualifications changed')
    structure = dict(schema='anscore-b46-independent-static-followup01-v1', status='PASS', packages=184, inherited_package_objects_exact=180,
        inherited_support_mapping_exact=True, actual_finite_counts=totals, evidence_receipts=receipts, retained_images=dict(sorted(images.items())),
        scope=scope, retained_prior_static_attempt=copy.deepcopy(plan['prior_static_attempt']), parent_snapshot=source['parent_snapshot'],
        input_sha256=plan['input_sha256'], tool_sha256=plan['tool_sha256'], **structural)
    for item in OBSERVED.values():
        current = item['path'].stat()
        require((current.st_size, current.st_mtime_ns) == (item['bytes'], item['mtime_ns']), 'Changed after observation: ' + str(item['path']))
    return source, structure


def main():
    require(sys.argv[1:] == ['--execute-approved-plan'], 'Exact approved CLI required')
    plan_path, review_path = HERE / 'plan.json', HERE / 'root_review.json'
    plan, review = load(plan_path), load(review_path)
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['root'] == review['peer'] == 'NO_BLOCKER', 'Root and peer source gate required')
    require(review['peer_reviewer'] == 'worker_a' and review['execution_gate'] == 'B46_STATIC_FOLLOWUP01_ONCE_01', 'Unique static execution gate required')
    bind(plan_path, review['plan_sha256'])
    bind(Path(__file__), review['helper_sha256'])
    bind(path(plan['launcher']), review['launcher_sha256'])
    require(plan['schema'] == 'anscore-b46-static-plan-followup01-v1' and plan['automatic_retry'] is False, 'Plan schema/retry policy')
    require(plan['outputs'] == ['source.json', 'structure.json', 'audit_once.json', 'failure.json'], 'Output path plan')
    require(all(not (HERE / name).exists() for name in plan['outputs']), 'Output or once guard exists')
    save_new(HERE / 'audit_once.json', dict(schema='anscore-b46-static-followup01-once-v1', status='ATTEMPT_STARTED', plan_sha256=review['plan_sha256'],
        helper_sha256=review['helper_sha256'], review_sha256=observation(review_path)['sha256'], launcher_sha256=review['launcher_sha256'],
        automatic_retry=False, started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat()))
    try:
        source, structure = audit(plan)
        structure['control_sha256'] = dict(plan=review['plan_sha256'], helper=review['helper_sha256'],
            review=observation(review_path)['sha256'], launcher=review['launcher_sha256'])
        save_new(HERE / 'source.json', source)
        save_new(HERE / 'structure.json', structure)
        print('B46_STATIC_FOLLOWUP01_PASS packages=184 source_files=403 module_declarations=405 preparation_children=15 hdl_children=57 successful_simulations=19')
        return 0
    except Exception:
        save_new(HERE / 'failure.json', dict(status='FAIL_STOP', exception=traceback.format_exc(), automatic_retry=False))
        raise


if __name__ == '__main__':
    raise SystemExit(main())


