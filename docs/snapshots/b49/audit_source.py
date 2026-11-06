"""B49 nonexecutable candidate for the independently gated static snapshot auditor.

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

ROOT = Path(__file__).resolve().parents[2]
PLAN = ROOT / 'scripts/b49/PLAN.json'
REVIEW = ROOT / 'scripts/b49/REVIEW.json'
SNAPSHOT = ROOT / 'docs/snapshots/b49'
BASE = '05b9614c3962e9d4ae934c4b9c7bd315cc01aed4'
GATE = 'B49_STATIC_ONCE_01'
DRAFT_ONLY = False  # Candidate only: root must finish PLAN/pins and review before enabling.
EXCLUDED = {'.work', '.build', '__pycache__', '.git'}
BINARY = {'.vvp', '.pyc', '.pyo', '.exe', '.dll', '.so', '.a', '.o', '.obj', '.lib', '.bin'}
COUNTERS = ('preparation_children', 'hdl_children', 'hdl_pass', 'hdl_fail', 'hdl_timeout', 'successful_simulations')
OBSERVED = {}
RECEIPT_SCHEMAS = {
    'anscore-b49-codebook-finite-v1': ('APPEND_ONLY_VALIDATED', 'initial_records', 'receipt'),
    'anscore-b49-fft-fir-finite-v1': ('APPEND_ONLY_VALIDATED', 'initial_records', 'receipt'),
    'b49-price-time-order-results-v1': ('AGGREGATE_VALIDATED', 'initial_child_records', 'receipt'),
    'b49-multistop-gradient-results-v1': ('AGGREGATE_VALIDATED', 'initial_child_records', 'receipt'),
    'b49-multistop-gradient-followup01-results-v1': ('AGGREGATE_VALIDATED', 'initial_child_records', 'repo'),
}
FIR_PACKAGE = 'cores/signal_processing/fft_overlap_save_fir'
RETAINED_CANDIDATES = FIR_PACKAGE + '/review_revisions'


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
        if Path(folder) == package and rel(package) == FIR_PACKAGE:
            directories[:] = [name for name in directories if name != 'review_revisions']
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
        require(rel(source) not in sources, 'Duplicate filelist source: ' + line)
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


def audit_retention(plan):
    spec = plan['retained_unexecuted_candidates']
    require(spec['directory'] == RETAINED_CANDIDATES and spec['expected_files'] == 8,
            'Exact FIR-only retained candidate scope')
    require(spec['local_exclude'] == '.git/info/exclude' and
            spec['exclude_pattern'] == '/' + RETAINED_CANDIDATES + '/', 'Exact local-only exclusion')
    bind(path(spec['receipt']), spec['receipt_sha256'])
    retained = load(path(spec['receipt']))
    require(retained['excluded_directory'] == RETAINED_CANDIDATES and len(retained['files']) == 8,
            'Retained candidate receipt scope')
    exclude = bind(path(spec['local_exclude']), spec['local_exclude_sha256'])['data']
    require(retained['exclude_after_sha256'] == spec['local_exclude_sha256'] and
            exclude.splitlines().count(spec['exclude_pattern'].encode('utf-8')) == 1,
            'Exact raw local exclude hash/pattern')
    actual = set()
    for folder, directories, filenames in os.walk(path(RETAINED_CANDIDATES), followlinks=False):
        require(all(not (Path(folder) / name).is_symlink() for name in directories), 'Retained candidate symlink directory')
        for name in filenames:
            actual.add(rel(path(Path(folder) / name)))
    require(actual == set(retained['files']), 'Exact eight retained candidate files; no missing or extra files')
    for name, item in retained['files'].items():
        require(name.startswith(RETAINED_CANDIDATES + '/'), 'Retained candidate path escaped exact scope')
        bind(path(name), item['sha256'], item['bytes'])
    return dict(directory=RETAINED_CANDIDATES, files=8, receipt=spec['receipt'],
        receipt_sha256=spec['receipt_sha256'], local_exclude_sha256=spec['local_exclude_sha256'],
        purpose='PRESERVATION_ONLY_OUTSIDE_FORMAL_SOURCE_STAGE_AND_ACCEPTANCE_EVIDENCE')


def canonical_audit(parent, inherited, plan):
    inherited_paths = inherited['canonical_source_paths']
    require(len(inherited_paths) == len(set(inherited_paths)) == 420, 'B48 canonical source count')
    require(set(inherited['canonical_source_sha256']) == set(inherited_paths), 'B48 canonical hash coverage')
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
    # B48 canonical HDL is an explicit raw-byte domain. Its four qualified JSON
    # normalizations and two root support domains do not intersect these 420 paths.
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
    tree_spec = plan['baseline_dependency_proof_source']
    tree_raw = bind(path(tree_spec['raw_tree']), tree_spec['raw_tree_sha256'])['data']
    require(tree_raw.endswith(b'\0'), 'Captured baseline tree must be NUL-delimited')
    tree_rows = tree_raw.decode('utf-8').split('\0')[:-1]
    require(len(tree_rows) == plan['baseline_tree_paths'] == 37021, 'Exact captured baseline tree count')
    tree = {}
    for row in tree_rows:
        match = re.fullmatch(r'([0-7]{6}) (blob|tree|commit) ([0-9a-f]{40})\t(.+)', row)
        require(match is not None and match[4] not in tree, 'Captured baseline tree record/duplicate')
        tree[match[4]] = dict(mode=match[1], type=match[2], oid=match[3])
    bridges = set(plan['new_dependency_bridges'])
    require(bridges == {'cores/acceleration/stream_fft/rtl/stream_fft.sv'} and not bridges.intersection(tree), 'Exact baseline-absent newly admitted support source')
    aliases = {item['alias']: item['canonical'] for item in parent['exact_byte_dependency_aliases']}
    require(len(aliases) == 2, 'Inherited alias count')
    for item in parent['exact_byte_dependency_aliases']:
        bind(path(item['alias']), item['sha256'], item['bytes'])
        bind(path(item['canonical']), item['sha256'], item['bytes'])
    new = sorted(name for spec in plan['packages'] for name in spec['canonical_sources'])
    require(len(new) == len(set(new)) == 8 and not set(new).intersection(inherited_paths), 'Eight disjoint new canonical sources')
    for name in new:
        canonical_hashes[name] = bind(path(name), plan['input_sha256'][name])['sha256']
    require(plan['canonical_source_promotions'] == [], 'No unproved baseline promotion')
    require(not bridges.intersection(inherited_paths) and not bridges.intersection(new), 'Support source must be distinct')
    bridge_proofs = plan['worktree_dependency_bridge_proofs']
    require(set(bridge_proofs) == bridges, 'Exact worktree support proof set')
    for name, item in bridge_proofs.items():
        require(item['module'] == 'stream_fft' and item['provenance'] == 'Original workspace RTL', 'Support source provenance')
        require(item['copied'] is False and item['bytes_mutated'] is False and item['baseline_present'] is False, 'Explicit unchanged worktree admission')
        require(item['root_reviewed'] is True and item['planned_git_mode'] == '100644' and item['type'] == 'blob', 'Support source review/mode')
        observed = bind(path(name), item['sha256'], item['bytes'])
        require(item['sha256'] == plan['input_sha256'][name], 'Support source SHA agreement')
        require(hashlib.sha1(b'blob ' + str(observed['bytes']).encode() + b'\0' + observed['data']).hexdigest() == item['oid'], 'Support computed blob OID')
        canonical_hashes[name] = observed['sha256']
    all_sources = set(inherited_paths) | set(new) | bridges
    dependencies = {name for spec in plan['packages'] for name in spec['baseline_dependencies']}
    require(dependencies == set(plan['baseline_dependency_proofs']) | bridges, 'Exact baseline and new support dependency proof set')
    for name, proof in plan['baseline_dependency_proofs'].items():
        require(proof['baseline_commit'] == BASE and proof['mode'] == '100644' and proof['type'] == 'blob', 'Baseline dependency mode/type')
        require(isinstance(proof['oid'], str) and re.fullmatch('[0-9a-f]{40}', proof['oid']) is not None, 'Root committed-blob OID required')
        require(proof['root_verified'] is True and proof['sha256'] == plan['input_sha256'][name], 'Root baseline dependency proof required')
        require(aliases.get(name, name) in set(inherited_paths), 'Baseline dependency is outside inherited canonical/alias domain')
        require(tree.get(name) == {key: proof[key] for key in ('mode', 'type', 'oid')}, 'Captured baseline dependency object differs')
        observed = bind(path(name), proof['sha256'])
        require(hashlib.sha1(b'blob ' + str(observed['bytes']).encode() + b'\0' + observed['data']).hexdigest() == proof['oid'], 'Baseline dependency raw blob OID differs')
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
    require(len(all_sources) == 429 and declaration_count == 431 and not collisions, 'Canonical lexical inventory differs')
    require(declarations.get('stream_fft') == sorted(bridges), 'Support source/module collision')
    closures = copy.deepcopy(inherited['source_list_closures'])
    for spec in plan['packages']:
        require(declarations.get(spec['top']) == [spec['canonical_sources'][0]], 'Top/source identity')
        for example in spec['examples']:
            require(declarations.get(example['top']) == [spec['path'] + '/' + example['file']], 'Example/source identity')
        for item in spec['source_lists']:
            raw = closure(path(item['base']), item['file'])
            require(len(item['expected_raw_sources']) == len(set(item['expected_raw_sources'])) and raw == set(item['expected_raw_sources']), 'Exact source closure set or duplicate differs')
            resolved = {aliases.get(name, name) for name in raw}
            require(resolved <= all_sources, 'Unclassified canonical closure')
            require(raw - set(spec['canonical_sources']) <= set(spec['baseline_dependencies']), 'Unproved dependency in closure')
            closures[rel(path(item['file'], path(item['base'])))] = sorted(resolved)
    return dict(canonical_source_paths=sorted(all_sources), canonical_sources=sorted(all_sources),
        canonical_source_sha256=canonical_hashes, new_canonical_sources=new, canonical_source_promotions=[], source_files=429,
        module_declarations=431, module_paths=declarations, unresolved_module_collisions=collisions,
        source_list_closures=closures, exact_byte_dependency_aliases=copy.deepcopy(parent['exact_byte_dependency_aliases']),
        retained_historical_source_list_closures=copy.deepcopy(inherited['retained_historical_source_list_closures']),
        inherited_baseline_text_normalizations=copy.deepcopy(normalizations),
        inherited_root_support_hash_domains=copy.deepcopy(support_domains),
        canonical_qualified_nonraw_hash_domain_intersections=[], existing_worktree_dependency_bridges=copy.deepcopy(bridge_proofs))


def audit_receipt(spec, plan, images):
    candidate = path(spec['receipt'])
    bind(candidate, spec['sha256'])
    receipt = load(candidate)
    folder, package = candidate.parent, path(spec['package'])
    schema = receipt['schema']
    require(schema == spec['receipt_schema'] and schema in RECEIPT_SCHEMAS, 'Explicit receipt schema binding')
    projection, initial_field, profile_mode = RECEIPT_SCHEMAS[schema]
    require((spec['record_projection'], spec['initial_records_field'], spec['profile_artifact_mode']) ==
            (projection, initial_field, profile_mode), 'Exact receipt projection/path-base binding')
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
        current = bind(path(name), digest)
        archived = bind(path(receipt['archived_sources'][name], package), digest)
        require(current['data'] == archived['data'], 'Current/archive exact bytes differ')
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
    planned_by_name = {item['name']: item for item in planned}
    require(len(planned_by_name) == len(planned), 'Duplicate archived planned child names')
    require(len(children) == spec['actual_children'] <= len(planned), 'Exact executed finite prefix')
    require(spec['status'] != 'PASS' or len(children) == len(planned), 'Incomplete successful finite command sequence')
    fields = ('name', 'kind', 'argv', 'cwd', 'marker', 'hard_seconds', 'tree_kill_seconds', 'drain_seconds', 'execution_deadline_seconds', 'profile', 'image', 'expected')
    for child, expected in zip(children, planned):
        for key, value in materialize(expected, folder.name).items():
            if key in fields:
                require(child.get(key) == value, 'Archived command/order mismatch: ' + child['name'] + '/' + key)
    validated = {}
    for name, entry in receipt['validated_records'].items():
        saved_path = path(name, artifact_base)
        bind(saved_path, entry['sha256'], entry['bytes'])
        saved = load(saved_path)
        owners = [child for child in children if child['name'] == saved['name']]
        require(len(owners) == 1 and saved['name'] not in validated, 'Validated record exact identity')
        child = owners[0]
        if projection == 'APPEND_ONLY_VALIDATED':
            additions = {'metadata_validated'}
            if '-o' in child['argv']:
                additions.add('compiled_image_sha256')
            if child['name'] in spec['simulation_children']:
                additions.update(('observed', 'expected'))
            require(not set(child).intersection(additions), 'Append-only aggregate already contains validation fields')
            require(set(saved) == set(child) | additions and
                    all(saved[key] == value for key, value in child.items()), 'Validated exact append-only projection')
        else:
            require(saved == child, 'Validated exact aggregate projection')
        require(saved['metadata_validated'] is True, 'Validated metadata flag')
        validated[saved['name']] = saved
    require(set(validated) == {child['name'] for child in children if child['status'] == 'PASS'}, 'Validated exact successful-child coverage')
    totals, compiled, raw_count, helper_raw_count = dict.fromkeys(COUNTERS, 0), {}, 0, 0
    require(len({child['name'] for child in children}) == len(children), 'Duplicate child names')
    exceptions = spec['exceptional_children']
    require(set(exceptions) == {child['name'] for child in children if child['status'] != 'PASS'}, 'Exact exceptional-child set')
    executed = []
    for index, child in enumerate(children):
        name = child['name']
        checked = validated.get(name, child)
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
            require(index == len(children) - 1 and spec['status'] == 'FAIL_STOP', 'Failure must terminate the exact executed prefix')
            require(exceptional['diagnostic_mode'] == 'RAW_TEXT' and exceptional['diagnostic_text'] and exceptional['diagnostic_text'] in raw['stdout'] + raw['stderr'], 'Retained failure diagnostic')
        if terminal_status == 'TIMEOUT':
            require(not raw['stdout'] and not raw['stderr'], 'Retain literal empty timeout child streams')
        if '-o' in child['argv'] and terminal_status == 'PASS':
            image = path(child['argv'][child['argv'].index('-o') + 1], path(child['cwd']))
            digest = checked.get('compiled_image_sha256', receipt['images'].get(image.relative_to(package).as_posix(), receipt['images'].get(str(image.relative_to(package)))))
            require(isinstance(digest, str), 'Compile image hash missing')
            require(receipt['images'].get(image.relative_to(package).as_posix()) == digest, 'Validated/receipt compile image hash differs')
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
                observed = checked['observed']
                tokens = dict(re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)', raw['stdout']))
                require(all(tokens.get(key) == str(value) for key, value in observed.items()), 'Raw simulation counters')
                expected = checked.get('expected') or {}
                require(expected == spec['simulation_expected'][name] and observed == spec['simulation_observed'][name], 'Explicit successful simulation metadata binding')
                require(all(observed.get(key) == value for key, value in expected.items()), 'Expected simulation counters')
                totals['successful_simulations'] += 1
    require(totals == spec['expected_counts'], 'Exact actual finite counts')
    require(raw_count == 2 * len(children) and helper_raw_count == spec['expected_helper_raw_streams'], 'Exact child/helper raw stream count')
    if spec.get('reused_preparations'):
        reused = spec['reused_preparations']
        original = load(path(reused['receipt']))
        bind(path(reused['receipt']), reused['receipt_sha256'])
        require(not any(child['kind'] == 'PREPARATION' for child in planned) and totals['preparation_children'] == 0, 'Followup must have zero new preparations')
        require(receipt['preparation_children'] == 0 and receipt['original_receipt'] == reused['receipt'], 'Original receipt and zero-preparation provenance')
        require(len(reused['vectors']) == reused['vector_count'] and receipt['reused_vectors'] == reused['vectors'], 'Exact original vectors reused')
        require(original['status'] == 'FAIL_STOP' and len(original['profiles']) == reused['vector_count'], 'Retained original preparation owner')
        require(receipt['prerequisites_sha256'] == archived_plan['prerequisites_sha256'], 'Followup prerequisite provenance')
        prerequisites_path = path(reused['prerequisites'])
        bind(prerequisites_path, receipt['prerequisites_sha256'])
        prerequisite_manifest = load(prerequisites_path)
        require(prerequisite_manifest['original_receipt'] == reused['receipt'], 'Prerequisite original receipt identity')
        prerequisite_files = prerequisite_manifest.get('sha256', prerequisite_manifest.get('files_sha256'))
        require(prerequisite_files == {item['path']: item['sha256'] for item in spec['additional_bindings']}, 'Exact original prerequisite bindings')
        original_preparations = [child for child in original['children'] if child['kind'] == 'PREPARATION']
        require([child['name'] for child in original_preparations] == reused['original_preparation_names'] and all(child['status'] == 'PASS' for child in original_preparations), 'Original preparation terminal linkage')
        argv_text = '\n'.join(' '.join(child['argv']) for child in children)
        for label, entry in reused['vectors'].items():
            vector = path(entry['path'])
            bind(vector, entry['sha256'])
            require(str(vector).replace('\\', '/') in argv_text.replace('\\', '/'), 'Reused vector absent from argv')
            original_files = original['profiles'][label].get('files', [])
            original_vector_map = original.get('vectors', {})
            require(any(path(item['path'], path(reused['receipt']).parent) == vector and item['sha256'] == entry['sha256'] for item in original_files) or
                any(path(name, path(reused['package'])) == vector and digest == entry['sha256'] for name, digest in original_vector_map.items()), 'Original prepared-vector ownership')
            require(any(path(binding['path']) == vector and binding['sha256'] == entry['sha256'] for binding in spec['additional_bindings']), 'Reused vector lacks explicit prerequisite binding')
        require(any(path(binding['path']) == path(reused['receipt']) and binding['sha256'] == reused['receipt_sha256'] for binding in spec['additional_bindings']), 'Original receipt lacks prerequisite binding')
    if spec.get('reused_evidence'):
        reused = spec['reused_evidence']
        original_path = path(reused['receipt'])
        bind(original_path, reused['receipt_sha256'])
        original = load(original_path)
        require(original['status'] == 'FAIL_STOP' and len(original['profiles']) == 5, 'Original gradient preparation owner')
        require(receipt['preparation_children'] == receipt['model_calls'] == receipt['runner_oracle_imports'] == 0, 'No followup numerical preparation')
        require(not any(child['kind'] == 'PREPARATION' for child in planned), 'No preparation in followup plan')
        require(receipt['original_receipt'] == reused['receipt'] and receipt['original_receipt_sha256'] == reused['receipt_sha256'], 'Original gradient receipt identity')
        require(receipt['reused_vectors'] == archived_plan['reused_vectors'] == reused['vectors'] and len(reused['vectors']) == 5, 'Exact five original vectors reused')
        evidence = receipt['original_evidence_sha256']
        require(evidence == archived_plan['original_evidence_sha256'] == reused['evidence_sha256'], 'Exact original evidence pin set')
        require(set(receipt['archived_original_evidence']) == set(evidence), 'Archived original evidence coverage')
        for name, digest in evidence.items():
            current = bind(path(name), digest)
            archived = bind(path(receipt['archived_original_evidence'][name], package), digest)
            require(current['data'] == archived['data'], 'Original/current evidence bytes differ')
        original_images = receipt['retained_original_images']
        require(original_images == archived_plan['retained_original_images'] == reused['retained_original_images'], 'Original failed-image provenance')
        require(original_images == {rel(path(name, path(reused['package']))): digest for name, digest in original['images'].items()}, 'Original image owner')
        for name, digest in original_images.items():
            bind(path(name), digest)
        preparations = [child for child in original['children'] if child['kind'] == 'PREPARATION']
        require(len(preparations) == 5 and all(child['status'] == 'PASS' for child in preparations), 'Five original successful preparations')
        argv_text = '\n'.join(' '.join(child['argv']) for child in children).replace('\\', '/')
        require(set(reused['vectors']) == set(original['profiles']), 'Original fixture profile coverage')
        for label, entry in reused['vectors'].items():
            vector = path(entry['path'])
            require(str(vector).replace('\\', '/') in argv_text, 'Reused gradient vector absent from argv')
            require(any(path(item['path'], original_path.parent) == vector and item['sha256'] == entry['sha256'] for item in original['profiles'][label]['files']), 'Original prepared-vector ownership')
            for item in original['profiles'][label]['files']:
                fixture = path(item['path'], original_path.parent)
                require(evidence.get(rel(fixture)) == item['sha256'], 'Original vector/preparation receipt lacks exact evidence pin')
                bind(fixture, item['sha256'], item['bytes'])
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
        require(len(matches) == 1, 'Terminal child identity')
        if projection == 'APPEND_ONLY_VALIDATED':
            require(saved == matches[0], 'Append-only terminal must equal untouched aggregate')
        else:
            projected = {key: value for key, value in matches[0].items() if key not in ('metadata_validated', 'observed')}
            require(saved == projected, 'Immutable terminal differs beyond exact observed/metadata additions')
        require('metadata_validated' not in saved and 'observed' not in saved, 'Terminal evidence must precede metadata parsing')
        saved_names.add(saved['name'])
    require(saved_names == {child['name'] for child in children}, 'Terminal child JSON coverage')
    require(initial_field in receipt and len(receipt[initial_field]) == len(children), 'Initial exact child coverage count')
    if receipt[initial_field]:
        sidecars = [(initial_field, 'initial')]
        for field, stage in sidecars:
            entries = receipt[field]
            expected_names = {child['name'] for child in children if stage == 'initial' or child['status'] == 'PASS'}
            require(len(entries) == len(expected_names), 'Immutable child sidecar count')
            names = set()
            for name, entry in entries.items():
                candidate = path(name, artifact_base)
                bind(candidate, entry['sha256'], entry['bytes'])
                saved = load(candidate)
                matches = [child for child in children if child['name'] == saved['name']]
                require(len(matches) == 1, 'Immutable child sidecar identity')
                child = matches[0]
                if stage == 'initial':
                    initial_expected = dict(materialize(planned_by_name[child['name']], folder.name),
                        status='STARTING', pid=None, exit_code=None, cleanup=[], process_exited=False,
                        output_capture_complete=False, process_evidence_saved=False)
                    if child['name'] in spec['simulation_children']:
                        initial_expected.update(execution_image_prechecked=True,
                            execution_image_sha256=child['execution_image_sha256'])
                    require(saved == initial_expected, 'Initial record differs from exact approved pre-spawn projection')
                    require(saved['status'] == 'STARTING' and saved['pid'] is None and saved['exit_code'] is None, 'Initial record must precede spawn')
                    require(saved['cleanup'] == [] and saved['process_evidence_saved'] is False, 'Initial record terminal state')
                    for key in fields:
                        if key in saved:require(saved[key] == child.get(key), 'Initial command binding differs')
                    if child['name'] in spec['simulation_children']:
                        require(saved['execution_image_prechecked'] is True and saved['execution_image_sha256'] == child['execution_image_sha256'], 'Durable initial simulation image pin')
                names.add(saved['name'])
            require(names == expected_names, 'Immutable sidecar coverage')

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
            for item in profile.get('files', []):
                profile_base = ROOT if profile_mode == 'repo' else folder
                bind(path(item['path'], profile_base), item['sha256'], item['bytes'])
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
    retention = audit_retention(plan)
    require(len(parent['packages']) == inherited['packages'] == closeout['packages'] == 192, 'B48 package inheritance')
    require(inherited['source_files'] == closeout['canonical_hdl_sources'] == 420 and inherited['module_declarations'] == closeout['module_declarations'] == 422, 'B48 structural inheritance')
    structural = canonical_audit(parent, inherited, plan)
    require(len(plan['packages']) == 4 and {spec['path'] for spec in plan['packages']} == {
        'cores/acceleration/signed8_codebook_search', 'cores/acceleration/price_time_order_matcher',
        'cores/signal_processing/fft_overlap_save_fir', 'cores/image_processing/multistop_linear_gradient'}, 'Exact four B49 packages')
    new_packages = []
    for spec in plan['packages']:
        files = formal_files(path(spec['path']))
        require(files == spec['formal_sha256'], 'Formal file-set/hash changed: ' + spec['path'])
        require('DELIVERY.md' in files and 'QUALIFICATION.json' in files, 'Missing final additive delivery')
        new_packages.append(dict(path=spec['path'], top=spec['top'], baseline_commit=BASE, evidence='QUALIFICATION.json',
            evidence_kind='b49_bounded_receipts_original_raw_and_images', hardware_status='HW_UNVERIFIED',
            examples=spec['examples'], sha256=files, formal_files=len(files),
            actual_source_lists=[dict(base=item['base'], file=item['file']) for item in spec['source_lists']]))
    images = {}
    receipts = [audit_receipt(spec, plan, images) for spec in plan['attempts']]
    require({spec['role'] for spec in plan['attempts']} == {'root', 'A', 'B', 'C'}, 'Four role evidence coverage')
    require(all(any(spec['role'] == role and spec['status'] == 'PASS' for spec in plan['attempts']) for role in ('root', 'A', 'B', 'C')), 'Each role needs its actual PASS receipt')
    totals = {key: sum(item[key] for item in receipts) for key in COUNTERS}
    require(totals == plan['expected_counts'] and len(images) == plan['expected_images'], 'Aggregate counts/images differ')
    scope = dict(inherited_package_objects='EXACT_JSON_METADATA_INHERITANCE_192', inherited_support_mapping='EXACT_JSON_METADATA_INHERITANCE',
        inherited_canonical_raw_sources_rehashed=420, historical_raw_evidence_rehashed=False,
        historical_raw_evidence_scope='B48 and earlier evidence/artifact metadata inherited; no historical runner/model/HDL/raw audit',
        inherited_retained_artifacts_metadata=len(closeout['all_retained_artifacts']),
        new_package_formal_text='Exact raw-byte SHA256 and complete sets; .work/.build/__pycache__ excluded; only cores/signal_processing/fft_overlap_save_fir/review_revisions excluded as eight retained unapproved/unexecuted local texts; no generic review_revisions exclusion; binary suffix/content rejected elsewhere',
        retained_unexecuted_candidates=retention,
        current_evidence='All explicitly planned B49 receipts, source/archive pairs, terminal JSON/raw, vectors and original images',
        baseline_dependency_proof='Six inherited dependencies require committed mode/type/OID proofs; one original worktree FFT source is explicitly admitted and staged',
        observation='Read-once byte cache plus final size/mtime check; not an atomic cross-file snapshot',
        git_committed_mode_type_oid_proof='DEFERRED_TO_ROOT_STAGE_AND_CLOSEOUT',
        model_imports=0, hdl_executions=0, subprocesses=0, synthesis=False, pnr=False, sta=False, board=False, ppa=False)
    source = copy.deepcopy(parent)
    source.update(date=plan['date'], baseline_commit=BASE, batch_baseline_commit=BASE,
        previous_snapshot=plan['parent_snapshot'], parent_snapshot=dict(path=plan['parent_snapshot'], sha256=plan['input_sha256'][plan['parent_snapshot']]),
        previous_batch_static_audit=copy.deepcopy(parent['batch_static_audit']),
        batch_evidence_receipts=receipts, batch_actual_counts=totals,
        batch_static_audit=dict(status='PASS', batch='B49', scope=scope), source_freeze='B49_RAW_BYTES_AND_EXACT_INHERITED_METADATA',
        baseline_canonical_source_promotions=[],
        batch_status='SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_HW_UNVERIFIED', batch_new_capabilities=copy.deepcopy(plan['capability_index']))
    source['packages'].extend(new_packages)
    require(source['packages'][:192] == parent['packages'] and source['support_files'] == parent['support_files'], 'Inherited package/support metadata changed')
    for name, item in plan['worktree_dependency_bridge_proofs'].items():
        require(name not in source['batch_canonical_base_sources'], 'Support source already classified')
        source['batch_canonical_base_sources'][name] = dict(sha256=item['sha256'], bytes=item['bytes'],
            raw_blob_oid=item['oid'], hash_kind='RAW_BYTES_NEW_WORKTREE_SUPPORT_ADMISSION', normalization='NONE',
            baseline_present=False, provenance=item['provenance'], license='Apache-2.0')
    require(all(source['batch_canonical_base_sources'][name] == value for name, value in parent['batch_canonical_base_sources'].items()), 'Inherited support-source metadata changed')
    for key in ('exact_byte_dependency_aliases', 'baseline_text_normalizations', 'batch_root_support_hash_domains'):
        require(source[key] == parent[key], 'Inherited hash-domain/bridge/alias metadata changed')
    structure = dict(schema='anscore-b49-independent-static-v1', status='PASS', packages=196,
        inherited_package_objects_exact=192, inherited_support_mapping_exact=True, actual_finite_counts=totals,
        evidence_receipts=receipts, retained_images=dict(sorted(images.items())), scope=scope,
        parent_snapshot=source['parent_snapshot'], input_sha256=plan['input_sha256'], tool_sha256=plan['tool_sha256'], **structural)
    for item in OBSERVED.values():
        current = item['path'].stat()
        require((current.st_size, current.st_mtime_ns) == (item['bytes'], item['mtime_ns']), 'Changed after observation: ' + str(item['path']))
    return source, structure


def main():
    require(not DRAFT_ONLY, 'B49 nonexecutable candidate: final package receipts, PLAN pins and root/peer gate pending')
    require(sys.argv[1:] == ['--execute-approved-plan'], 'Exact approved CLI required')
    plan, review = load(PLAN), load(REVIEW)
    require(plan['status'] == 'FROZEN' and not plan['pending_inputs'], 'Draft or incomplete plan cannot execute')
    require(plan['schema'] == 'anscore-b49-static-plan-v1' and plan['baseline_commit'] == BASE and plan['automatic_retry'] is False, 'Plan identity/retry policy')
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['root'] == review['peer'] == 'NO_BLOCKER', 'Separate root and peer gate required')
    require(review['peer_reviewer'] in ('worker_a', 'worker_b', 'worker_c') and review['execution_gate'] == GATE, 'Unique static gate required')
    require(path(plan['helper']) == Path(__file__).resolve(), 'Draft helper cannot be executed')
    bind(PLAN, review['plan_sha256'])
    bind(Path(__file__), review['helper_sha256'])
    bind(path(plan['launcher']), review['launcher_sha256'])
    require(plan['outputs'] == ['source.json', 'structure.json', 'audit_once.json', 'failure.json'], 'Exact output list')
    require(SNAPSHOT.is_dir() and all(not (SNAPSHOT / name).exists() for name in plan['outputs']), 'Prior output/guard exists')
    for name, expected in (('plan.json', review['plan_sha256']), ('audit_source.py', review['helper_sha256']),
                           ('root_review.json', observation(REVIEW)['sha256']), ('launcher.py', review['launcher_sha256'])):
        bind(SNAPSHOT / name, expected)
    save_new(SNAPSHOT / 'audit_once.json', dict(schema='anscore-b49-static-once-v1', status='ATTEMPT_STARTED',
        started_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(), automatic_retry=False,
        plan_sha256=review['plan_sha256'], helper_sha256=review['helper_sha256'], review_sha256=observation(REVIEW)['sha256']))
    try:
        source, structure = audit(plan)
        structure['control_sha256'] = dict(plan=review['plan_sha256'], helper=review['helper_sha256'],
            review=observation(REVIEW)['sha256'], launcher=review['launcher_sha256'])
        save_new(SNAPSHOT / 'source.json', source)
        save_new(SNAPSHOT / 'structure.json', structure)
        print('B49_STATIC_PASS packages=196 source_files=429 module_declarations=431')
        return 0
    except BaseException:
        save_new(SNAPSHOT / 'failure.json', dict(status='FAIL_STOP', automatic_retry=False, exception=traceback.format_exc()))
        raise


if __name__ == '__main__':
    raise SystemExit(main())
