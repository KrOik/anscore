"""B47 independently gated static snapshot auditor.

Only Python standard-library byte/JSON/lexical operations. No project imports,
AST, subprocesses, HDL tools, Git, cleanup or historical raw-evidence replay.
Execution requires exact frozen controls and independent root/peer approval.
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

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / '.git/anscore-b47-static-plan.json'
REVIEW = ROOT / '.git/anscore-b47-static-review.json'
SNAPSHOT = ROOT / 'docs/snapshots/b47'
BASE = 'd32ea87e268c5957b7203560a5b46864e282a6e1'
GATE = 'B47_STATIC_ONCE_01'
EXCLUDED = {'.work', '.build', '__pycache__', '.git'}
BINARY = {'.vvp', '.pyc', '.pyo', '.exe', '.dll', '.so', '.a', '.o', '.obj', '.lib', '.bin'}
COUNTERS = ('preparation_children', 'hdl_children', 'hdl_pass', 'hdl_fail', 'hdl_timeout', 'successful_simulations')
OBSERVED = {}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def path(value, base=ROOT):
    candidate = Path(str(value).replace('\\', '/'))
    candidate = candidate if candidate.is_absolute() else base / candidate
    require(not candidate.is_symlink(), 'Symlink input: ' + str(candidate))
    resolved = candidate.resolve(strict=True)
    if resolved.is_relative_to(ROOT):
        for component in (candidate, *candidate.parents):
            require(not component.is_symlink(), 'Symlink path component: ' + str(component))
            if component == ROOT:
                break
    return resolved


def rel(candidate):
    require(candidate.is_relative_to(ROOT), 'Input escaped repository: ' + str(candidate))
    return candidate.relative_to(ROOT).as_posix()


def observation(candidate):
    candidate = path(candidate)
    key = os.path.normcase(str(candidate))
    if key not in OBSERVED:
        before = candidate.stat()
        require(candidate.is_file(), 'Not a regular file: ' + str(candidate))
        data = candidate.read_bytes()
        after = candidate.stat()
        require((before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns),
                'Changed during observation: ' + str(candidate))
        OBSERVED[key] = dict(path=candidate, data=data, bytes=len(data), mtime_ns=after.st_mtime_ns,
                             sha256=hashlib.sha256(data).hexdigest())
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
            require(not (Path(folder) / name).is_symlink(), 'Formal symlink directory')
        directories[:] = sorted(name for name in directories if name not in EXCLUDED)
        for name in sorted(filenames):
            candidate = Path(folder) / name
            require(candidate.suffix.lower() not in BINARY, 'Binary outside excluded build directory: ' + str(candidate))
            item = observation(candidate)
            require(b'\0' not in item['data'], 'Binary content in formal domain: ' + str(candidate))
            result[candidate.relative_to(package).as_posix()] = item['sha256']
    return dict(sorted(result.items()))


def closure(base, filename):
    sources = set()
    for line in observation(path(filename, base))['data'].decode('utf-8-sig').splitlines():
        line = line.split('//', 1)[0].split('#', 1)[0].strip()
        if not line:
            continue
        require(not line.startswith(('-', '+')) and len(line.split()) == 1, 'Nonexplicit filelist entry: ' + line)
        source = path(line, base)
        require(source.suffix.lower() in ('.v', '.sv'), 'Non-HDL closure input: ' + line)
        sources.add(rel(source))
    return sources


def materialize(value, stamp):
    if isinstance(value, str):
        return value.replace('<stamp>', stamp)
    if isinstance(value, list):
        return [materialize(item, stamp) for item in value]
    if isinstance(value, dict):
        return {key: materialize(item, stamp) for key, item in value.items()}
    return value


def canonical_audit(parent, inherited, plan):
    inherited_paths = inherited['canonical_source_paths']
    require(len(inherited_paths) == len(set(inherited_paths)) == 403, 'B46 canonical source count')
    require(set(inherited['canonical_source_sha256']) == set(inherited_paths), 'B46 canonical hash coverage')
    known = {}
    for package in parent['packages']:
        for name, digest in package['sha256'].items():
            key = os.path.normpath(package['path'] + '/' + name).replace('\\', '/')
            require(key not in known or known[key] == digest, 'Conflicting inherited package hash')
            known[key] = digest
    for name, digest in parent['support_files'].items():
        require(name not in known or known[name] == digest, 'Conflicting inherited support hash')
        known[name] = digest
    for name, item in parent['batch_canonical_base_sources'].items():
        require(name not in known or known[name] == item['sha256'], 'Conflicting inherited bridge hash')
        known[name] = item['sha256']
    # B46 canonical HDL is an explicit raw-byte domain. Its four qualified JSON
    # normalizations and two root support domains do not intersect these 403 paths.
    # Retain that fact and all metadata; never apply a generic normalization.
    normalizations = parent['baseline_text_normalizations']
    support_domains = parent['batch_root_support_hash_domains']
    require(len(normalizations) == 4 and support_domains['qualified_entries'] == 2,
            'Inherited qualified hash-domain metadata')
    require(not set(normalizations).intersection(inherited_paths) and
            not set(support_domains['sources']).intersection(inherited_paths),
            'Qualified non-HDL hash domain unexpectedly intersects canonical HDL')
    canonical_hashes = {}
    for name in inherited_paths:
        expected = inherited['canonical_source_sha256'][name]
        require(known.get(name) == expected, 'Inherited hash-domain disagreement: ' + name)
        canonical_hashes[name] = bind(path(name), expected)['sha256']
    require(plan['new_dependency_bridges'] == [], 'No B47 dependency bridge has been authorized')
    aliases = {item['alias']: item['canonical'] for item in parent['exact_byte_dependency_aliases']}
    require(len(aliases) == 2, 'Inherited alias count')
    for item in parent['exact_byte_dependency_aliases']:
        bind(path(item['alias']), item['sha256'], item['bytes'])
        bind(path(item['canonical']), item['sha256'], item['bytes'])
    new = sorted(name for spec in plan['packages'] for name in spec['canonical_sources'])
    require(len(new) == len(set(new)) == 8 and not set(new).intersection(inherited_paths), 'Eight disjoint new canonical sources')
    for name in new:
        canonical_hashes[name] = bind(path(name), plan['input_sha256'][name])['sha256']
    all_sources = set(inherited_paths) | set(new)
    dependencies = {name for spec in plan['packages'] for name in spec['baseline_dependencies']}
    require(dependencies == set(plan['baseline_dependency_proofs']), 'Exact baseline dependency proof set')
    for name, proof in plan['baseline_dependency_proofs'].items():
        require(proof['baseline_commit'] == BASE and proof['mode'] == '100644' and proof['type'] == 'blob', 'Baseline dependency mode/type')
        require(isinstance(proof['oid'], str) and re.fullmatch('[0-9a-f]{40}', proof['oid']) is not None, 'Root committed-blob OID required')
        require(proof['root_verified'] is True and proof['sha256'] == plan['input_sha256'][name], 'Root baseline dependency proof required')
        require(aliases.get(name, name) in inherited_paths, 'New dependency is outside inherited canonical/alias domain')
        bind(path(name), proof['sha256'])
    declarations = {}
    declaration_count = 0
    for name in sorted(all_sources):
        text = observation(path(name))['data'].decode('utf-8-sig')
        text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
        modules = re.findall(r'(?m)^\s*module\s+(?:automatic\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\b', text)
        require(modules, 'No lexical module declaration: ' + name)
        declaration_count += len(modules)
        for module in modules:
            declarations.setdefault(module, []).append(name)
    collisions = {name: names for name, names in declarations.items() if len(names) != 1}
    require(len(all_sources) == 411 and declaration_count == 413 and not collisions, 'Canonical lexical inventory differs')
    closures = copy.deepcopy(inherited['source_list_closures'])
    for spec in plan['packages']:
        require(declarations.get(spec['top']) == [spec['canonical_sources'][0]], 'Top/source identity')
        for example in spec['examples']:
            require(declarations.get(example['top']) == [spec['path'] + '/' + example['file']], 'Example/source identity')
        for item in spec['source_lists']:
            raw = closure(path(item['base']), item['file'])
            require(sorted(raw) == item['expected_raw_sources'], 'Exact source closure differs')
            resolved = {aliases.get(name, name) for name in raw}
            require(resolved <= all_sources, 'Unclassified canonical closure')
            require(raw - set(spec['canonical_sources']) <= set(spec['baseline_dependencies']), 'Unproved dependency in closure')
            closures[rel(path(item['file'], path(item['base'])))] = sorted(resolved)
    return dict(canonical_source_paths=sorted(all_sources), canonical_sources=sorted(all_sources),
        canonical_source_sha256=canonical_hashes, new_canonical_sources=new, source_files=411,
        module_declarations=413, module_paths=declarations, unresolved_module_collisions=collisions,
        source_list_closures=closures, exact_byte_dependency_aliases=copy.deepcopy(parent['exact_byte_dependency_aliases']),
        retained_historical_source_list_closures=copy.deepcopy(inherited['retained_historical_source_list_closures']),
        inherited_baseline_text_normalizations=copy.deepcopy(normalizations),
        inherited_root_support_hash_domains=copy.deepcopy(support_domains),
        canonical_qualified_nonraw_hash_domain_intersections=[], existing_worktree_dependency_bridges=[])


def audit_receipt(spec, plan, images):
    candidate = path(spec['receipt'])
    bind(candidate, spec['sha256'])
    receipt = load(candidate)
    folder, package = candidate.parent, path(spec['package'])
    artifact_base = package if spec['artifact_mode'] == 'package' else folder
    require(receipt['status'] == spec['status'], 'Receipt status')
    require(receipt.get('active_child') is None and receipt.get('active_helper') is None and not receipt.get('active_helpers'), 'Active receipt process')
    require(receipt['automatic_retry'] is False and receipt['archive_complete'] is True, 'Receipt retry/archive state')
    require(receipt['inputs_unchanged'] is spec['retained_inputs_unchanged_flag'], 'Preserve literal unchanged flag')
    require(receipt['exact_plan_executed'] is spec['retained_exact_plan_executed_flag'], 'Preserve literal exact-plan flag')
    require(receipt['suite_complete'] is (spec['status'] == 'PASS'), 'Receipt suite-complete state')
    for binding in spec['control_bindings']:
        bind(path(binding['path']), receipt[binding['receipt_field']])
    require(set(receipt['source_sha256']) == set(receipt['archived_sources']), 'Source/archive key mismatch')
    require(len(receipt['source_sha256']) == spec['expected_source_pairs'], 'Source/archive pair count')
    for name, digest in receipt['source_sha256'].items():
        bind(path(name), digest)
        bind(path(receipt['archived_sources'][name], package), digest)
    prerequisites = receipt.get('prerequisite_files', {})
    require(prerequisites == spec.get('expected_prerequisite_files', {}), 'Exact prerequisite metadata')
    for name, entry in prerequisites.items():
        digest = entry['sha256'] if isinstance(entry, dict) else entry
        size = entry.get('bytes') if isinstance(entry, dict) else None
        bind(path(name), digest, size)
    for item in spec.get('additional_bindings', []):
        bind(path(item['path']), item['sha256'], item.get('bytes'))
    tools = receipt.get('tools_sha256', receipt.get('tools'))
    require(isinstance(tools, dict) and tools, 'Missing tool hash map')
    for name, digest in tools.items():
        require(plan['tool_sha256'][name] == digest, 'Tool metadata disagreement')
        bind(path(name), digest)
    children = receipt.get('children')
    if children is None:
        children = receipt['preparations'] + receipt['checks']
    archived_plan = load(path(spec['archived_plan']))
    planned = archived_plan['children']
    require(len(children) == spec['actual_children'] <= len(planned), 'Exact executed finite prefix')
    require(spec['status'] != 'PASS' or len(children) == len(planned), 'Incomplete successful finite command sequence')
    fields = ('name', 'kind', 'argv', 'cwd', 'marker', 'hard_seconds', 'tree_kill_seconds', 'drain_seconds', 'execution_deadline_seconds', 'profile', 'image')
    for child, expected in zip(children, planned):
        for key, value in materialize(expected, folder.name).items():
            if key in fields:
                require(child.get(key) == value, 'Archived command/order mismatch: ' + child['name'] + '/' + key)
    totals, compiled, raw_count, helper_raw_count = dict.fromkeys(COUNTERS, 0), {}, 0, 0
    require(len({child['name'] for child in children}) == len(children), 'Duplicate child names')
    exceptions = spec['exceptional_children']
    require(set(exceptions) == {child['name'] for child in children if child['status'] != 'PASS'}, 'Exact exceptional-child set')
    executed = []
    for index, child in enumerate(children):
        name = child['name']
        preparation = child['kind'] == 'PREPARATION'
        simulation = name in spec['simulation_children']
        exceptional = exceptions.get(name)
        terminal_status = exceptional['status'] if exceptional else 'PASS'
        require(terminal_status in ('PASS', 'FAIL', 'TIMEOUT'), 'Unsupported explicitly retained terminal state')
        require(child['status'] == terminal_status and child.get('exit_code', child.get('returncode')) == (exceptional['exit_code'] if exceptional else 0), 'Child status/exit mismatch')
        totals['preparation_children' if preparation else 'hdl_children'] += 1
        if not preparation:
            totals[{'PASS': 'hdl_pass', 'FAIL': 'hdl_fail', 'TIMEOUT': 'hdl_timeout'}[terminal_status]] += 1
        require(isinstance(child['pid'], int) and child['pid'] > 0, 'Child PID evidence')
        require(child.get('process_exited', child.get('exit_confirmed')) is True and child['output_capture_complete'] is True and child['process_evidence_saved'] is True, 'Child terminal evidence')
        require(child.get('active_child') is None and not child.get('capture_errors'), 'Nonterminal child')
        require(child.get('hard_seconds', child.get('execution_deadline_seconds')) == 20 and child['tree_kill_seconds'] == 5 and child['drain_seconds'] == 2, 'Child 20/5/sole2 policy')
        if terminal_status == 'TIMEOUT':
            require(not preparation and index == len(children) - 1 and spec['status'] == 'FAIL_STOP', 'Timeout must terminate executed prefix')
            require(exceptional['diagnostic_mode'] == 'TIMEOUT_RECEIPT_ONLY' and exceptional['policy'] == '20S_CHILD_5S_HELPER_SOLE2S_TARGET_OBSERVATION', 'Explicit retained timeout policy')
            for key, value in exceptional['literal_child_fields'].items():
                require(key in child and child[key] == value, 'Retained timeout literal field: ' + key)
            require(child['cleanup'] == exceptional['cleanup'] and len(child['cleanup']) == 1, 'Exact retained timeout cleanup')
            cleanup = child['cleanup'][0]
            require(cleanup['kind'] == 'TREE_TERMINATION' and cleanup['status'] == 'EXITED' and cleanup['hard_seconds'] == 5 and cleanup['exit_code'] == 0, 'Timeout helper policy/status')
            require(isinstance(cleanup['pid'], int) and cleanup['pid'] > 0 and cleanup['process_exited'] is True and cleanup['active_helper'] is None, 'Timeout helper termination')
            require(cleanup['output_capture_complete'] is True and not cleanup['capture_errors'] and 0 <= cleanup['helper_seconds'] < 5, 'Timeout helper capture/deadline')
            require(0 <= cleanup['target_observation_seconds'] < 2 and not cleanup.get('target_observation_deadline_exceeded') and cleanup.get('target_observation') != 'UNCONFIRMED', 'Sole target observation closure')
            require(20 <= child['seconds'] < 27, 'Retained timeout total elapsed bound')
            runner_text = observation(path(exceptional['reviewed_runner']))['data'].decode('utf-8-sig')
            require(runner_text.count('child.wait(timeout=2)') == 1 and 'remaining=20-(time.monotonic()-start)' in runner_text and 'remaining=5-(time.monotonic()-hs)' in runner_text, 'Reviewed timeout source policy changed')
            for stream in ('stdout', 'stderr'):
                item = cleanup[stream]
                bind(path(item['path'], artifact_base), item['sha256'], item['bytes'])
                helper_raw_count += 1
        else:
            require(not child['cleanup'] and not child.get('timed_out'), 'Unexpected ordinary child cleanup/timeout')
            elapsed = child.get('execution_seconds', child.get('elapsed_seconds'))
            require(isinstance(elapsed, (int, float)) and 0 <= elapsed < 20, 'Child elapsed limit')
        raw = {}
        for stream in ('stdout', 'stderr'):
            item = child[stream]
            raw[stream] = bind(path(item['path'], artifact_base), item['sha256'], item['bytes'])['data'].decode('utf-8', errors='replace')
            raw_count += 1
        marker = child.get('marker')
        if marker and terminal_status == 'PASS':
            require(raw['stdout'].count(marker) == 1, 'Finite marker mismatch')
        if terminal_status == 'FAIL':
            require(exceptional['diagnostic_mode'] == 'RAW_TEXT' and exceptional['diagnostic_text'] and exceptional['diagnostic_text'] in raw['stdout'] + raw['stderr'], 'Retained failure diagnostic')
        if terminal_status == 'TIMEOUT':
            require(not raw['stdout'] and not raw['stderr'], 'Retain literal empty timeout child streams')
        if '-o' in child['argv'] and terminal_status == 'PASS':
            image = path(child['argv'][child['argv'].index('-o') + 1], path(child['cwd']))
            digest = child['compiled_image_sha256']
            bind(image, digest)
            compiled[rel(image)] = digest
        if simulation:
            image = path(child['argv'][1], path(child['cwd']))
            digest = child['execution_image_sha256']
            require(compiled.get(rel(image)) == digest, 'Compile/execute image linkage')
            mode = spec['image_binding_mode']
            if mode == 'START_RECORD_PRECHECKED':
                require(child['execution_image_prechecked'] is True, 'Retained initial-record image precheck')
            elif mode == 'DURABLE_EXECUTION_IMAGES':
                entry = receipt['execution_images'][name]
                require(path(entry['path'], package) == image and entry['sha256'] == digest, 'Durable report execution-image linkage')
            else:
                require(mode == 'COMPLETED_IMAGE_HASH_MATCH', 'Unknown literal image evidence mode')
            bind(image, digest)
            require(rel(image) not in images, 'Repeated original image path')
            images[rel(image)] = dict(sha256=digest, successful_simulation=terminal_status == 'PASS',
                failed_simulation=terminal_status == 'FAIL', timed_out_simulation=terminal_status == 'TIMEOUT',
                terminal_status=terminal_status, receipt=spec['receipt'], child=name, original_image_retained=True)
            executed.append(rel(image))
            if terminal_status == 'PASS':
                require(marker and not raw['stderr'] and '$finish called' in raw['stdout'], 'Successful simulation marker/stderr/finish')
                observed = child['observed']
                tokens = dict(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)', raw['stdout']))
                require(all(tokens.get(key) == str(value) for key, value in observed.items()), 'Raw simulation counters')
                expected = child.get('expected') or {}
                require(all(observed.get(key) == value for key, value in expected.items()), 'Expected simulation counters')
                totals['successful_simulations'] += 1
    require(totals == spec['expected_counts'], 'Exact actual finite counts')
    require(raw_count == 2 * len(children) and helper_raw_count == spec['expected_helper_raw_streams'], 'Exact child/helper raw stream count')
    if spec.get('reused_preparations'):
        reused = spec['reused_preparations']
        original = load(path(reused['receipt']))
        bind(path(reused['receipt']), reused['receipt_sha256'])
        require(not any(child['kind'] == 'PREPARATION' for child in planned) and totals['preparation_children'] == 0, 'Followup must have zero new preparations')
        require(len(reused['vectors']) == 3 and reused['vectors'] == original['vectors'] == receipt['vectors'], 'Exactly three original prepared vectors reused')
        require(receipt['original_receipt_sha256'] == reused['receipt_sha256'] and receipt['preparation_children'] == 0, 'Literal followup original-receipt/zero-preparation provenance')
        require(receipt['prerequisites_sha256'] == archived_plan['prerequisites_sha256'], 'Followup prerequisite control provenance')
        prerequisites_path = path(reused['prerequisites'])
        bind(prerequisites_path, receipt['prerequisites_sha256'])
        prerequisite_manifest = load(prerequisites_path)
        require(prerequisite_manifest['original_receipt_sha256'] == reused['receipt_sha256'], 'Prerequisite original receipt identity')
        require(prerequisite_manifest['files_sha256'] == {item['path']: item['sha256'] for item in spec['additional_bindings']}, 'Exact72 original prerequisite bindings')
        original_preparations = [child for child in original['children'] if child['kind'] == 'PREPARATION']
        require([child['name'] for child in original_preparations] == reused['original_preparation_names'] and all(child['status'] == 'PASS' for child in original_preparations), 'Original preparation terminal linkage')
        argv_text = '\n'.join(' '.join(child['argv']) for child in children)
        for name, digest in reused['vectors'].items():
            vector = path(name, package)
            bind(vector, digest)
            require(str(vector).replace('\\', '/') in argv_text.replace('\\', '/'), 'Reused vector absent from executed argv')
            require(any(path(binding['path']) == vector and binding['sha256'] == digest for binding in spec['additional_bindings']), 'Reused vector missing explicit provenance binding')
        require(any(path(binding['path']) == path(reused['receipt']) and binding['sha256'] == reused['receipt_sha256'] for binding in spec['additional_bindings']), 'Original receipt missing followup provenance binding')
    records = receipt['child_records']
    require(len(records) == len(children), 'Terminal child JSON count')
    saved_names = set()
    for name, entry in records.items():
        digest = entry['sha256'] if isinstance(entry, dict) else entry
        size = entry.get('bytes') if isinstance(entry, dict) else None
        child_path = path(name, artifact_base)
        bind(child_path, digest, size)
        saved = load(child_path)
        matches = [child for child in children if child['name'] == saved['name']]
        require(len(matches) == 1 and saved == matches[0], 'Terminal child JSON differs')
        saved_names.add(saved['name'])
    require(saved_names == {child['name'] for child in children}, 'Terminal child JSON coverage')
    for name, digest in receipt['images'].items():
        image = path(name, package)
        require(compiled.get(rel(image)) == digest, 'Aggregate compile image differs')
        bind(image, digest)
    for name, digest in receipt.get('vectors', {}).items():
        bind(path(name, package), digest)
    for name, entry in receipt.get('raw_evidence', {}).items():
        bind(path(name, package), entry['sha256'], entry['bytes'])
    profiles = receipt.get('profiles')
    if isinstance(profiles, dict):
        for profile in profiles.values():
            for item in profile['files']:
                bind(path(item['path'], folder), item['sha256'], item['bytes'])
    return dict(role=spec['role'], path=spec['receipt'], sha256=spec['sha256'], status=spec['status'],
        source_archive_pairs=spec['expected_source_pairs'], archive_complete=True,
        archive_proof='INDEPENDENT_EXACT_CURRENT_ARCHIVE_HASH_AND_BYTES',
        retained_inputs_unchanged_flag=receipt['inputs_unchanged'],
        retained_exact_plan_executed_flag=receipt['exact_plan_executed'], raw_streams=raw_count,
        helper_raw_streams=helper_raw_count, retained_original_images=executed, **totals)

def audit(plan):
    for name, digest in plan['input_sha256'].items():
        require(rel(path(name)) == name, 'Noncanonical repo input')
        bind(path(name), digest)
    for name, digest in plan['tool_sha256'].items():
        bind(path(name), digest)
    parent, inherited, closeout = (load(path(plan[name])) for name in ('parent_snapshot', 'parent_structure', 'parent_closeout'))
    require(len(parent['packages']) == inherited['packages'] == closeout['packages'] == 184, 'B46 package inheritance')
    require(inherited['source_files'] == closeout['canonical_hdl_sources'] == 403 and inherited['module_declarations'] == closeout['module_declarations'] == 405, 'B46 structural inheritance')
    structural = canonical_audit(parent, inherited, plan)
    new_packages = []
    for spec in plan['packages']:
        files = formal_files(path(spec['path']))
        require(files == spec['formal_sha256'], 'Formal file-set/hash changed: ' + spec['path'])
        require('DELIVERY.md' in files and 'QUALIFICATION.json' in files, 'Missing final additive delivery')
        new_packages.append(dict(path=spec['path'], top=spec['top'], baseline_commit=BASE, evidence='QUALIFICATION.json',
            evidence_kind='b47_bounded_receipts_original_raw_and_images', hardware_status='HW_UNVERIFIED',
            examples=spec['examples'], sha256=files, formal_files=len(files),
            actual_source_lists=[dict(base=item['base'], file=item['file']) for item in spec['source_lists']]))
    images = {}
    receipts = [audit_receipt(spec, plan, images) for spec in plan['attempts']]
    require({spec['role'] for spec in plan['attempts']} == {'root', 'A', 'B', 'C'}, 'Four role evidence coverage')
    require(all(any(spec['role'] == role and spec['status'] == 'PASS' for spec in plan['attempts']) for role in ('root', 'A', 'B', 'C')), 'Each role needs its actual PASS receipt')
    totals = {key: sum(item[key] for item in receipts) for key in COUNTERS}
    require(totals == plan['expected_counts'] and len(images) == plan['expected_images'], 'Aggregate counts/images differ')
    scope = dict(inherited_package_objects='EXACT_JSON_METADATA_INHERITANCE_184', inherited_support_mapping='EXACT_JSON_METADATA_INHERITANCE',
        inherited_canonical_raw_sources_rehashed=403, historical_raw_evidence_rehashed=False,
        historical_raw_evidence_scope='B46 and earlier evidence/artifact metadata inherited; no historical runner/model/HDL/raw audit',
        inherited_retained_artifacts_metadata=len(closeout['all_retained_artifacts']),
        new_package_formal_text='Exact raw-byte SHA256 and complete sets; .work/.build/__pycache__ excluded; binary suffix/content rejected elsewhere',
        current_evidence='All explicitly planned B47 receipts, source/archive pairs, terminal JSON/raw, vectors and original images',
        baseline_dependency_proof='Root committed mode/type/OID attestation required for every reused source; no new bridge authorized',
        observation='Read-once byte cache plus final size/mtime check; not an atomic cross-file snapshot',
        git_committed_mode_type_oid_proof='DEFERRED_TO_ROOT_STAGE_AND_CLOSEOUT',
        model_imports=0, hdl_executions=0, subprocesses=0, synthesis=False, pnr=False, sta=False, board=False, ppa=False)
    source = copy.deepcopy(parent)
    source.update(date=plan['date'], baseline_commit=BASE, batch_baseline_commit=BASE,
        previous_snapshot=plan['parent_snapshot'], parent_snapshot=dict(path=plan['parent_snapshot'], sha256=plan['input_sha256'][plan['parent_snapshot']]),
        previous_batch_static_audit=copy.deepcopy(parent['batch_static_audit']),
        batch_evidence_receipts=receipts, batch_actual_counts=totals,
        batch_static_audit=dict(status='PASS', batch='B47', scope=scope), source_freeze='B47_RAW_BYTES_AND_EXACT_INHERITED_METADATA',
        batch_status='SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_HW_UNVERIFIED', batch_new_capabilities=copy.deepcopy(plan['capability_index']))
    source['packages'].extend(new_packages)
    require(source['packages'][:184] == parent['packages'] and source['support_files'] == parent['support_files'], 'Inherited package/support metadata changed')
    for key in ('batch_canonical_base_sources', 'exact_byte_dependency_aliases', 'baseline_text_normalizations', 'batch_root_support_hash_domains'):
        require(source[key] == parent[key], 'Inherited hash-domain/bridge/alias metadata changed')
    structure = dict(schema='anscore-b47-independent-static-v1', status='PASS', packages=188,
        inherited_package_objects_exact=184, inherited_support_mapping_exact=True, actual_finite_counts=totals,
        evidence_receipts=receipts, retained_images=dict(sorted(images.items())), scope=scope,
        parent_snapshot=source['parent_snapshot'], input_sha256=plan['input_sha256'], tool_sha256=plan['tool_sha256'], **structural)
    for item in OBSERVED.values():
        current = item['path'].stat()
        require((current.st_size, current.st_mtime_ns) == (item['bytes'], item['mtime_ns']), 'Changed after observation: ' + str(item['path']))
    return source, structure


def main():
    require(sys.argv[1:] == ['--execute-approved-plan'], 'Exact approved CLI required')
    plan, review = load(PLAN), load(REVIEW)
    require(plan['status'] == 'FROZEN' and not plan['pending_inputs'], 'Draft or incomplete plan cannot execute')
    require(plan['schema'] == 'anscore-b47-static-plan-v1' and plan['baseline_commit'] == BASE and plan['automatic_retry'] is False, 'Plan identity/retry policy')
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['root'] == review['peer'] == 'NO_BLOCKER', 'Separate root and peer gate required')
    require(review['peer_reviewer'] in ('worker_a', 'worker_c') and review['execution_gate'] == GATE, 'Unique static gate required')
    require(path(plan['helper']) == Path(__file__).resolve(), 'Draft helper cannot be executed')
    bind(PLAN, review['plan_sha256'])
    bind(Path(__file__), review['helper_sha256'])
    bind(path(plan['launcher']), review['launcher_sha256'])
    require(plan['outputs'] == ['source.json', 'structure.json', 'audit_once.json', 'failure.json'], 'Exact output list')
    require(SNAPSHOT.is_dir() and all(not (SNAPSHOT / name).exists() for name in plan['outputs']), 'Prior output/guard exists')
    for name, expected in (('plan.json', review['plan_sha256']), ('audit_source.py', review['helper_sha256']),
                           ('root_review.json', observation(REVIEW)['sha256']), ('launcher.py', review['launcher_sha256'])):
        bind(SNAPSHOT / name, expected)
    save_new(SNAPSHOT / 'audit_once.json', dict(schema='anscore-b47-static-once-v1', status='ATTEMPT_STARTED',
        started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), automatic_retry=False,
        plan_sha256=review['plan_sha256'], helper_sha256=review['helper_sha256'], review_sha256=observation(REVIEW)['sha256']))
    try:
        source, structure = audit(plan)
        structure['control_sha256'] = dict(plan=review['plan_sha256'], helper=review['helper_sha256'],
            review=observation(REVIEW)['sha256'], launcher=review['launcher_sha256'])
        save_new(SNAPSHOT / 'source.json', source)
        save_new(SNAPSHOT / 'structure.json', structure)
        print('B47_STATIC_PASS packages=188 source_files=411 module_declarations=413')
        return 0
    except BaseException:
        save_new(SNAPSHOT / 'failure.json', dict(status='FAIL_STOP', automatic_retry=False, exception=traceback.format_exc()))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
