"""B44 static evidence audit. Standard-library data reads only; never imports IP.

This is a new auditor, not a wrapper around a historical auditor. Root must bind
this file, its static plan and the root evidence index in a separate review gate.
The exclusive guard is consumed before the first audit, including failed audits.
No model, HDL, Git mutation, combined compile or cleanup is performed here.
"""
from pathlib import Path
import argparse
import copy
import datetime
import hashlib
import json
import os
import re
import traceback


REPO = Path(__file__).resolve().parents[2]
HERE = REPO / 'docs/snapshots'
BASELINE = '09de72c578b3099d4e867c739118faa7607f663d'
PARENT_PINS = {
    'docs/snapshots/source_20261106_b43.json': 'e7605009c87a1ebdcd32b64fd5a2f64d6e759bbec09c50da2b25be6076050e80',
    'docs/snapshots/source_20261106_b43_structure.json': '0a5ceddc08bb2a295bd677ef40b074c1624f453f4bc3b2b6eac153a8516082e0',
    'docs/snapshots/source_20261106_b43_closeout.json': 'a714fe71b9c6e82ae1f6f8d6c979747e7d64b9bd094a658107041963c9e3bcc3',
}
ROOT_EVIDENCE = 'cores/acceleration/int4_depthwise3x3_stream/EVIDENCE_AUDIT.json'
ROOT_EVIDENCE_SHA = '5d6226027ef183f3e9bdcd2d1e11b8512781856bf2ff343b4b4d7595f89a75c6'
GUARD = REPO / '.git/anscore-b44-static-once.json'
PLAN = HERE / 'source_20261106_b44_static_plan.json'
REVIEW = HERE / 'source_20261106_b44_static_review.json'
OUTPUT = HERE / 'source_20261106_b44.json'
STRUCTURE = HERE / 'source_20261106_b44_structure.json'
FAILURE = HERE / 'source_20261106_b44_static_failure.json'
SPECS = {
    'root': ('cores/acceleration/int4_depthwise3x3_stream', 'int4_depthwise3x3_stream',
             'rtl/int4_depthwise3x3_stream.v', 'example/rgb_depthwise_filter.v', 'rgb_depthwise_filter'),
    'A': ('cores/acceleration/call_auction_clear', 'call_auction_clear',
          'rtl/call_auction_clear.sv', 'example/call_auction_book.sv', 'call_auction_book'),
    'B': ('cores/signal_processing/spectral_kurtosis', 'spectral_kurtosis',
          'rtl/spectral_kurtosis.sv', 'example/iq_spectral_kurtosis64.sv', 'iq_spectral_kurtosis64'),
    'C': ('cores/image_processing/tetrahedral_rgb_grade', 'tetrahedral_rgb_grade',
          'rtl/tetrahedral_rgb_grade.sv', 'example/graded_luma_preview.sv', 'graded_luma_preview'),
}
SCHEMAS = {
    ('root', 'initial'): 'anscore-b44-depthwise-evidence-v1',
    ('root', 'followup01'): 'anscore-b44-depthwise-followup01-v1',
    ('A', 'initial'): 'anscore-b44-call-auction-results-v1',
    ('A', 'followup01'): 'anscore-b44-call-auction-followup-results-v1',
    ('B', 'initial'): 'anscore-b44-sk-results-v1',
    ('C', 'initial'): 'anscore-b44-c-finite-result-v1',
}
EXPECTED = {
    ('root', 'initial'): (5, 5, 4, 1, 0),
    ('root', 'followup01'): (0, 10, 10, 0, 5),
    ('A', 'initial'): (1, 11, 10, 1, 3),
    ('A', 'followup01'): (0, 4, 4, 0, 2),
    ('B', 'initial'): (4, 11, 11, 0, 4),
    ('C', 'initial'): (4, 11, 11, 0, 4),
}
EXCLUDED_PARTS = {'.work', '.build', '__pycache__', '.git'}
BINARY_SUFFIXES = {'.vvp', '.pyc', '.pyo', '.exe', '.dll', '.so', '.a', '.o', '.obj', '.lib', '.bin'}
OBSERVED_BINDINGS = {}
IMAGES = {}
TOOL_BINDINGS = {}
RECEIPT_PINS = {}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def path(value, base=REPO):
    candidate = Path(str(value).replace('\\', '/'))
    candidate = candidate if candidate.is_absolute() else base / candidate
    candidate = candidate.resolve()
    require(candidate.is_relative_to(REPO), 'Path escaped repository: ' + str(candidate))
    return candidate


def rel(value):
    return path(value).relative_to(REPO).as_posix()


def digest(value):
    return hashlib.sha256(Path(value).read_bytes()).hexdigest()


def load(value):
    return json.loads(Path(value).read_bytes())


def write_new(destination, data):
    with Path(destination).open('xb') as stream:
        stream.write((json.dumps(data, indent=2, ensure_ascii=False) + '\n').encode('utf-8'))
        stream.flush()
        os.fsync(stream.fileno())


def binding(value, expected, size=None):
    value = path(value)
    require(value.is_file(), 'Missing file: ' + str(value))
    actual = digest(value)
    require(actual == expected, 'SHA mismatch: ' + rel(value))
    if size is not None:
        require(value.stat().st_size == size, 'Size mismatch: ' + rel(value))
    previous = OBSERVED_BINDINGS.setdefault(rel(value), actual)
    require(previous == actual, 'Conflicting binding: ' + rel(value))
    return value


def tool_bindings(tools):
    items = tools.items() if isinstance(tools, dict) else ((x['path'], x['sha256']) for x in tools)
    for name, expected in items:
        tool = Path(name)
        require(tool.is_file() and digest(tool) == expected, 'Tool/runtime hash mismatch: ' + name)
        require(TOOL_BINDINGS.setdefault(str(tool), expected) == expected, 'Conflicting tool pin')
    if isinstance(tools, list):
        for item in tools:
            require(Path(item['path']).stat().st_size == item['bytes'], 'Tool size mismatch')


def normalized_inherited(value, expected, normalizations, parent):
    current = path(value)
    raw = current.read_bytes()
    OBSERVED_BINDINGS.setdefault(rel(current), hashlib.sha256(raw).hexdigest())
    if hashlib.sha256(raw).hexdigest() == expected:
        return 'BYTE_EXACT'
    name = rel(current)
    if name in normalizations:
        item = normalizations[name]
        require(item['normalization'] == 'EXACT_LF_COMMITTED_TO_CRLF_WORKTREE', name)
        require(item['committed_sha256'] == expected, 'Normalization original hash mismatch: ' + name)
        require(hashlib.sha256(raw).hexdigest() == item['worktree_sha256'], name)
        lf = raw.replace(b'\r\n', b'\n')
        require(b'\r' not in lf and b'\r\n' in raw and lf.replace(b'\n', b'\r\n') == raw, name)
        require(hashlib.sha256(lf).hexdigest() == expected, 'Not exact LF-to-CRLF: ' + name)
        require(json.loads(lf) == json.loads(raw), 'JSON changed: ' + name)
        oid = hashlib.sha1(b'blob ' + str(len(lf)).encode() + b'\0' + lf).hexdigest()
        require(oid == item['baseline_blob_oid'], 'Filtered Git blob OID mismatch: ' + name)
        return 'PARENT_EXPLICIT_LF_TO_CRLF'
    # This one pre-existing support entry explicitly stores its Git LF hash and
    # its original CRLF worktree hash. It is inherited data, not a new exception.
    support = parent.get('support_file_additions', {}).get(name, {})
    require(support.get('hash_kind') == 'baseline_committed_git_blob', 'Inherited byte mismatch: ' + name)
    require(support.get('sha256') == expected, name)
    require(hashlib.sha256(raw).hexdigest() == support.get('executed_worktree_sha256'), name)
    lf = raw.replace(b'\r\n', b'\n')
    require(hashlib.sha256(lf).hexdigest() == expected, name)
    oid = hashlib.sha1(b'blob ' + str(len(lf)).encode() + b'\0' + lf).hexdigest()
    require(oid == support['baseline_blob_oid'], name)
    return 'PARENT_EXPLICIT_SUPPORT_GIT_BLOB'


def inherited(parent, structure, closeout):
    require(len(parent['packages']) == 172 and closeout['packages'] == 172, 'Parent package count')
    require(structure['status'] == 'PASS' and
            closeout['status'] == 'SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_CLEANUP_RETAINED', 'Parent not closed')
    normalizations = parent['baseline_text_normalizations']
    require(normalizations == structure['baseline_text_normalizations'] and len(normalizations) == 4,
            'Only the parent four explicit normalizations are allowed')
    exact = adjusted = 0
    for package in parent['packages']:
        for name, expected in package['sha256'].items():
            result = normalized_inherited(path(name, path(package['path'])), expected, normalizations, parent)
            exact += result == 'BYTE_EXACT'
            adjusted += result != 'BYTE_EXACT'
    for name, expected in parent['support_files'].items():
        normalized_inherited(name, expected, normalizations, parent)
    for artifact in closeout.get('all_retained_artifacts', []):
        binding(artifact['path'], artifact['sha256'])
    return dict(formal_mappings=exact + adjusted, byte_exact=exact, explicit_parent_adjustments=adjusted,
                retained_artifacts=len(closeout.get('all_retained_artifacts', [])))


def formal_files(package):
    files = {}
    for candidate in sorted(package.rglob('*')):
        if not candidate.is_file() or any(part in EXCLUDED_PARTS for part in candidate.relative_to(package).parts):
            continue
        if candidate.suffix.lower() in BINARY_SUFFIXES:
            continue
        require(not candidate.is_symlink(), 'Formal source symlink: ' + rel(candidate))
        require(b'\0' not in candidate.read_bytes(), 'Unexpected binary formal file: ' + rel(candidate))
        files[candidate.relative_to(package).as_posix()] = digest(candidate)
    return files


def delivery_mapping(package, files):
    delivery_path = package / 'DELIVERY.json'
    require(delivery_path.is_file(), 'Missing separate final delivery metadata')
    delivery = load(delivery_path)
    for item in delivery.values():
        if isinstance(item, dict) and 'path' in item and 'sha256' in item:
            binding(path(item['path'], package), item['sha256'])
    if 'files_sha256' not in delivery:
        qualification = load(path(delivery['qualification']['path'], package))
        require(qualification['results'] == delivery['results'], 'B qualification/result bridge')
        require(qualification['frozen_inputs_unchanged'] is True and qualification['results']['status'] == 'PASS',
                'B final qualification')
        return  # B uses nested qualification/results bindings rather than a second whole-file map.
    declared = {}
    for name, expected in delivery['files_sha256'].items():
        base = REPO if name.replace('\\', '/').startswith('cores/') else package
        candidate = binding(path(name, base), expected)
        require(candidate.is_relative_to(package), 'Delivery map escaped its package')
        declared[candidate.relative_to(package).as_posix()] = expected
    require(delivery['self_excluded'] is True and delivery['file_count'] == len(declared), 'Delivery file count')
    require(declared == {name: value for name, value in files.items() if name != 'DELIVERY.json'},
            'Final delivery mapping differs from formal rglob')


def source_evidence(receipt, package, folder):
    sources = receipt.get('source_sha256', receipt.get('sources'))
    require(sources, 'Missing source bindings: ' + rel(folder))
    if isinstance(sources, list):
        for item in sources:
            binding(item['path'], item['sha256'], item.get('bytes'))
            binding(path(item['archive'], folder), item['sha256'], item.get('bytes'))
    else:
        archives = receipt['archived_sources']
        require(set(sources) == set(archives), 'Archive source domain mismatch')
        for name, expected in sources.items():
            base = REPO if name.replace('\\', '/').startswith('cores/') else package
            binding(path(name, base), expected)
            binding(path(archives[name], package), expected)
    for item in receipt.get('retained_inputs', receipt.get('retained', [])):
        binding(item['path'], item['sha256'], item.get('bytes'))
        if 'archive' in item:
            binding(path(item['archive'], folder), item['sha256'], item.get('bytes'))
    tool_bindings(receipt['tools'])


def stream_evidence(child, stream, role, phase, package, folder):
    if isinstance(child.get(stream), dict):
        item = child[stream]
        base = package if role == 'C' else folder
        return binding(path(item['path'], base), item['sha256'], item.get('bytes')).read_bytes()
    suffix = '.txt' if role == 'root' and phase == 'initial' else '.raw'
    return binding(folder / (child['name'] + '.' + stream + suffix), child[stream + '_sha256']).read_bytes()


def counters_from_raw(child, raw):
    marker = child.get('marker')
    if child['status'] != 'PASS' or not marker:
        return None
    lines = [line for line in raw.splitlines() if line.startswith(marker.encode())]
    require(len(lines) == 1, 'PASS marker multiplicity: ' + child['name'])
    values = {k.decode(): int(v) for k, v in re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
    if 'observed' in child:
        require(child['observed'] == values, 'Raw/record counters differ: ' + child['name'])
    for key, expected in child.get('expected_runtime', {}).items():
        require(values.get(key) == expected, 'Runtime-domain mismatch: ' + child['name'] + '/' + key)
    return values


def child_evidence(child, role, phase, package, folder):
    require(child.get('process_evidence_saved') is True, 'Missing record-first evidence')
    require(not child.get('cleanup') and child.get('pid'), 'Unexpected cleanup/missing PID')
    require(child.get('output_capture_complete', child.get('raw_finalized')) is True, 'Incomplete output')
    code = child.get('exit_code', child.get('returncode'))
    require(code is not None and child['status'] in ('PASS', 'FAIL'), 'Unobserved child exit')
    require((code == 0) == (child['status'] == 'PASS'), 'Return/status mismatch')
    raw = stream_evidence(child, 'stdout', role, phase, package, folder)
    err = stream_evidence(child, 'stderr', role, phase, package, folder)
    observed = counters_from_raw(child, raw)
    single = folder / (child['name'] + '.json')
    if single.is_file():
        require(load(single) == child, 'Per-child receipt mismatch: ' + rel(single))
    argv = child['argv']
    simulation = Path(argv[0]).stem.lower() == 'vvp'
    image = None
    if '-o' in argv:
        image = path(argv[argv.index('-o') + 1])
        expected = child.get('image_sha256', child.get('compiled_image_sha256'))
        require(expected is not None, 'Compiled image unbound: ' + child['name'])
        binding(image, expected)
    elif simulation:
        image = path(argv[1])
        expected = child.get('execution_image_sha256', child.get('executed_image_sha256'))
        require(expected is not None, 'Executed image unbound: ' + child['name'])
        binding(image, expected)
        require(any(image == path(x) for x in IMAGES), 'Simulation image has no audited compile')
        if child['status'] == 'PASS':
            require(not err, 'Successful simulation stderr: ' + child['name'])
    if image is not None:
        entry = IMAGES.setdefault(rel(image), dict(sha256=digest(image), successful_simulation=False,
                                                   failed_simulation=False))
        if simulation:
            entry['successful_simulation'] |= child['status'] == 'PASS'
            entry['failed_simulation'] |= child['status'] == 'FAIL'
    return dict(simulation=simulation, observed=observed, failure_output=(raw + err).decode('utf-8', errors='replace') if child['status'] != 'PASS' else None,
                status=child['status'], name=child['name'], image=rel(image) if image else None)


def a_expected(profile):
    n, p, q, t = profile['parameters']
    counts = profile['counts']
    if profile['kind'] == 'core':
        require(counts['cases'] == counts['snapshots'] == 48, 'A core file-domain counts')
        require(counts['maintenance'] == counts['vector_resets'] == 0, 'A core file domain')
        return dict(N=n, P=p, Q=q, T=t, cases=48, rows=counts['rows'], checks=48, holds=192,
                    future_accepts=47, resets=4, cancelled=3, recoveries=3)
    cases = 102 + 4 * n
    require(counts['cases'] == cases and counts['snapshots'] == 33, 'A book file-domain counts')
    require(counts['maintenance'] == 68 + 4 * n and counts['vector_resets'] == 1, 'A book file domain')
    return dict(L=n, P=p, Q=q, T=t, cases=cases, checks=cases - 1, maintenance=68 + 4 * n,
                snapshots=33, holds=4 * (cases - 1), future_accepts=cases - 3,
                vector_resets=1, resets=7, cancelled=5, recoveries=5, priority=1)


def profile_evidence(role, receipt, package, folder, audited, initial):
    if role == 'root':
        for profile in receipt.get('profiles', []):
            binding(folder / profile['vector'], profile['vector_sha256'])
            binding(folder / profile['summary'], profile['summary_sha256'])
        return
    if role == 'A':
        profiles = initial['profiles']
        for profile in profiles:
            vector_folder = initial['_folder'] / 'vectors'
            binding(vector_folder / profile['path'], profile['sha256'], profile['bytes'])
        if 'vector_receipt' in initial:
            item = initial['vector_receipt']
            binding(initial['_folder'] / item['path'], item['sha256'])
        for item in audited:
            if item['simulation'] and item['status'] == 'PASS':
                profile = next(p for p in profiles if item['name'] == 'sim_' + p['label'])
                require(item['observed'] == a_expected(profile), 'A runtime-domain counters')
        return
    if role == 'B':
        for profile in receipt['profiles']:
            binding(folder / profile['vector'], profile['vector_sha256'], profile['vector_bytes'])
            binding(folder / profile['preparation'], profile['preparation_sha256'])
        for item in audited:
            if item['simulation']:
                index = int(item['name'][3:])
                profile = receipt['profiles'][index]
                expected = dict(profile['expected_counters'], B=profile['bins'], M=profile['frames'],
                                P=profile['power'], F=profile['frac'], T=profile['tag'], EX=profile['example'])
                require(all(item['observed'].get(k) == v for k, v in expected.items()), 'B runtime-domain counters')
                require(all(item['observed'][k] > 0 for k in ('holds', 'blocked', 'input_holds')), 'B protocol coverage')
        return
    for name, expected in receipt['vectors'].items():
        binding(path(name, package), expected)
    for name, expected in receipt['images'].items():
        binding(path(name, package), expected)
    for profile in receipt['profiles']:
        binding(folder / profile['preparation'], profile['preparation_sha256'])
    for item in audited:
        if item['simulation']:
            profile = next(p for p in receipt['profiles'] if item['name'] == 'sim_' + p['name'])
            require(all(item['observed'].get(k) == v for k, v in profile['expected_counters'].items()),
                    'C runtime-domain counters')


def control_bindings(role, phase, receipt, package, folder):
    if role == 'root':
        plan_path = package / ('FINITE_PLAN.json' if phase == 'initial' else 'followup01/PLAN.json')
        binding(plan_path, receipt['plan_sha256'])
        binding(folder / 'plan.json', receipt['plan_sha256'])
        binding(folder / 'gate.json', receipt['gate_sha256'])
        binding(package / ('SOURCE_REVIEW.json' if phase == 'initial' else 'followup01/SOURCE_REVIEW.json'), receipt['gate_sha256'])
    elif role == 'A':
        for filename, field in [('plan.json', 'plan_sha256'), ('source_seal.json', 'source_seal_sha256'),
                                ('source_review.json', 'approval_sha256')]:
            if field in receipt:
                binding(folder / filename, receipt[field])
        plan_path = package / ('FINITE_PLAN.json' if phase == 'initial' else 'followup01/PLAN.json')
        binding(plan_path, receipt['plan_sha256'])
        binding(package / ('SOURCE_REVIEW.json' if phase == 'initial' else 'followup01/SOURCE_REVIEW.json'), receipt['approval_sha256'])
        if phase == 'initial':
            binding(package / 'SOURCE_SEAL.json', receipt['source_seal_sha256'])
    elif role == 'B':
        for filename, field in [('plan.json', 'plan_sha256'), ('source_seal.json', 'seal_sha256'),
                                ('source_review.json', 'approval_sha256')]:
            binding(folder / filename, receipt[field])
        plan_path = package / 'PRECHECK_PLAN.json'
        for filename, field in [('PRECHECK_PLAN.json', 'plan_sha256'), ('SOURCE_SEAL.json', 'seal_sha256'),
                                ('SOURCE_REVIEW.json', 'approval_sha256')]:
            binding(package / filename, receipt[field])
    else:
        for filename, field in [('PRECHECK_PLAN.json', 'plan_sha256'), ('SOURCE_SEAL.json', 'source_seal_sha256'),
                                ('REVIEW_CURRENT.json', 'review_sha256')]:
            binding(folder / filename, receipt[field])
            binding(package / filename, receipt[field])
        plan_path = package / 'PRECHECK_PLAN.json'
    if 'guard' in receipt:
        binding(receipt['guard'], receipt['guard_sha256'])
    return load(plan_path)


def concrete(value, stamp):
    if isinstance(value, str):
        return value.replace('<stamp>', stamp)
    if isinstance(value, list):
        return [concrete(item, stamp) for item in value]
    if isinstance(value, dict):
        return {key: concrete(item, stamp) for key, item in value.items()}
    return value


def receipt_audit(role, phase, receipt_path, initial=None):
    package = path(SPECS[role][0])
    folder = receipt_path.parent
    pin = RECEIPT_PINS[role + '/' + phase]
    require(path(pin['path']) == receipt_path, 'Unexpected unique receipt path')
    binding(receipt_path, pin['sha256'])
    receipt = load(receipt_path)
    require(receipt['schema'] == SCHEMAS[(role, phase)], 'Unknown receipt schema: ' + rel(receipt_path))
    require(receipt.get('baseline', receipt.get('baseline_commit', BASELINE)) == BASELINE, 'Receipt baseline')
    require(receipt.get('automatic_retry') is False and receipt.get('active_child') is None, 'Retry/live child')
    source_evidence(receipt, package, folder)
    plan = control_bindings(role, phase, receipt, package, folder)
    children = receipt.get('children')
    if children is None:
        preparations, checks = receipt.get('preparations', []), receipt['checks']
    else:
        preparations = [c for c in children if c['kind'] == 'PREPARATION']
        checks = [c for c in children if c['kind'] != 'PREPARATION']
        require(children == preparations + checks, 'Preparation must precede HDL')
    planned = plan.get('children', plan.get('preparations', []) + plan.get('checks', []))
    planned = concrete(planned, folder.name)
    actual = preparations + checks
    require(len(planned) >= len(actual), 'More actual children than finite plan')
    for child, specification in zip(actual, planned):
        for key, expected in specification.items():
            if key == 'profile_index':
                continue  # B binds this index independently to frozen profile metadata.
            require(child.get(key) == expected, 'Plan/argv mismatch: ' + child['name'] + '/' + key)
    audited = [child_evidence(c, role, phase, package, folder) for c in preparations + checks]
    require(len({c['name'] for c in preparations + checks}) == len(audited), 'Duplicate child name')
    check_results = audited[len(preparations):]
    observed_counts = (len(preparations), len(checks), sum(c['status'] == 'PASS' for c in check_results),
                       sum(c['status'] == 'FAIL' for c in check_results),
                       sum(c['simulation'] and c['status'] == 'PASS' for c in check_results))
    require(observed_counts == EXPECTED[(role, phase)], 'Finite actual child counts: ' + role + '/' + phase)
    require(all(c['status'] == 'PASS' for c in audited[:len(preparations)]), 'Preparation failed')
    if EXPECTED[(role, phase)][3]:
        require(check_results[-1]['status'] == 'FAIL' and not receipt['suite_complete'], 'Historical fail-stop lost')
        require(all(c['status'] == 'PASS' for c in check_results[:-1]), 'Unexpected earlier failure')
        failed = check_results[-1]
        expected_name = 'sim_c1_w3_h3_t1' if role == 'root' else 'sim_book_l1_p1_q1_t1'
        expected_text = 'trailing vector records' if role == 'root' else '$fscanf argument 3 (a vpiConstant) is not assignable'
        require(failed['name'] == expected_name and expected_text in failed['failure_output'], 'Historical failure identity changed')
    else:
        require(receipt['status'] == 'PASS' and receipt['suite_complete'], 'Incomplete successful receipt')
        require(len(planned) == len(actual), 'Successful run skipped planned children')
    if phase == 'followup01':
        require(not preparations and receipt.get('numerical_preparations', 0) == 0, 'Followup performed preparation')
        require(not any(c['name'].startswith('syntax') for c in checks), 'Followup performed syntax rerun')
    receipt['_folder'] = folder
    profile_evidence(role, receipt, package, folder, check_results, initial or receipt)
    result = dict(path=rel(receipt_path), sha256=digest(receipt_path), schema=receipt['schema'],
                  role=role, phase=phase, preparation_children=observed_counts[0],
                  hdl_children=observed_counts[1], hdl_pass=observed_counts[2], hdl_fail=observed_counts[3],
                  successful_simulations=observed_counts[4])
    return receipt, result


def strip_comments(text):
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def closure(package, filename, stack=()):
    filelist = path(filename, package)
    require(filelist not in stack, 'Recursive files.f')
    sources = set()
    for raw in filelist.read_text(encoding='utf-8-sig').splitlines():
        line = raw.split('//', 1)[0].split('#', 1)[0].strip()
        if not line:
            continue
        if line.startswith('-f '):
            sources.update(closure(package, line[3:].strip(), stack + (filelist,)))
            continue
        require(not line.startswith(('-', '+')) and len(line.split()) == 1, 'Unsupported filelist directive: ' + line)
        source = path(line, package)
        require(source.is_file() and source.suffix.lower() in ('.v', '.sv'), 'Missing HDL closure: ' + line)
        sources.add(rel(source))
    return sources


def canonical_audit(parent, parent_structure):
    aliases = {item['alias']: item['canonical'] for item in parent.get('exact_byte_dependency_aliases', [])}
    for item in parent.get('exact_byte_dependency_aliases', []):
        binding(item['alias'], item['sha256'], item.get('bytes'))
        binding(item['canonical'], item['sha256'], item.get('bytes'))
    def canonical(name):
        seen = set()
        while name in aliases:
            require(name not in seen, 'Alias cycle')
            seen.add(name)
            name = aliases[name]
        return name
    previous = {canonical(name) for name in parent_structure['canonical_source_paths']}
    new = {SPECS[role][0] + '/' + filename for role in SPECS for filename in SPECS[role][2:4]}
    require(len(new) == 8 and not new.intersection(previous), 'New canonical RTL count')
    all_sources = previous | new
    closures = {}
    for role, spec in SPECS.items():
        package = path(spec[0])
        require({rel(p) for p in (package / 'rtl').rglob('*') if p.suffix.lower() in ('.v', '.sv')} == {spec[0] + '/' + spec[2]},
                'Unexpected additional production RTL: ' + role)
        for filename in ('files.f', 'example/files.f'):
            resolved = {canonical(name) for name in closure(package, filename)}
            require(resolved.issubset(all_sources), 'Unclassified production source: ' + role + '/' + filename)
            closures[spec[0] + '/' + filename] = sorted(resolved)
    owners = {}
    declarations = 0
    for name in sorted(all_sources):
        text = strip_comments(path(name).read_text(encoding='utf-8-sig'))
        found = re.findall(r'(?m)^\s*module\s+(?:automatic\s+)?([A-Za-z_$][A-Za-z0-9_$]*)\b', text)
        require(found, 'Canonical source has no module: ' + name)
        declarations += len(found)
        for module in found:
            owners.setdefault(module, []).append(name)
    collisions = {name: paths for name, paths in owners.items() if len(paths) != 1}
    require(not collisions, 'Unresolved module declaration collisions: ' + repr(collisions))
    for spec in SPECS.values():
        require(owners[spec[1]] == [spec[0] + '/' + spec[2]], 'Core module ownership')
        require(owners[spec[4]] == [spec[0] + '/' + spec[3]], 'Example module ownership')
    return dict(canonical_source_paths=sorted(all_sources), new_canonical_sources=sorted(new),
                source_files=len(all_sources), module_declarations=declarations,
                unresolved_module_collisions=collisions, source_list_closures=closures,
                exact_byte_dependency_aliases=copy.deepcopy(parent.get('exact_byte_dependency_aliases', [])))


def audit(root_evidence_path):
    parent = load(path('docs/snapshots/source_20261106_b43.json'))
    parent_structure = load(path('docs/snapshots/source_20261106_b43_structure.json'))
    parent_closeout = load(path('docs/snapshots/source_20261106_b43_closeout.json'))
    inherited_result = inherited(parent, parent_structure, parent_closeout)
    root_evidence = load(root_evidence_path)
    require(root_evidence['schema'] == 'anscore-b44-depthwise-evidence-audit-v1', 'Root evidence schema')
    require(root_evidence['baseline_commit'] == BASELINE, 'Root evidence baseline')
    receipts = []
    new_packages = []
    for role, spec in SPECS.items():
        package = path(spec[0])
        originals = sorted((package / 'reports').glob('*/results.json'))
        followups = sorted(package.glob('followup*/reports/*/results.json'))
        require(len(originals) == 1, 'Exactly one initial receipt required: ' + role)
        require(len(followups) == (1 if role in ('root', 'A') else 0), 'Extra/missing bounded followup: ' + role)
        if followups:
            require(followups[0].is_relative_to(package / 'followup01'), 'Only followup01 is authorized')
        original, result = receipt_audit(role, 'initial', originals[0])
        receipts.append(result)
        if followups:
            _, result = receipt_audit(role, 'followup01', followups[0], original)
            receipts.append(result)
        if role == 'root':
            for phase, candidate in [('initial', originals[0]), ('followup01', followups[0])]:
                index = root_evidence['receipts'][phase]
                require(path(index['path']) == candidate, 'Root index receipt path')
                binding(candidate, index['sha256'])
        files = formal_files(package)
        delivery_mapping(package, files)
        evidence = next((name for name in ('B44_DELIVERY.json', 'DELIVERY.json', 'EVIDENCE_AUDIT.json', 'QUALIFICATION.json') if name in files), None)
        require(evidence is not None, 'Missing final delivery evidence: ' + role)
        new_packages.append(dict(path=spec[0], top=spec[1], baseline_commit=BASELINE,
            evidence=evidence, evidence_kind='b44_finite_evidence_with_retained_initial_failures',
            hardware_status='HW_UNVERIFIED', additional_source_lists=['example/files.f'],
            examples=[dict(file=spec[3], top=spec[4])], sha256=files))
    root_actual = {key: sum(r[key] for r in receipts if r['role'] == 'root') for key in
                   ('preparation_children', 'hdl_children', 'hdl_pass', 'hdl_fail', 'successful_simulations')}
    require(root_evidence['qualified_counts'] == root_actual, 'Root actual counters/index mismatch')
    totals = {key: sum(r[key] for r in receipts) for key in root_actual}
    require(totals == dict(preparation_children=14, hdl_children=52, hdl_pass=50, hdl_fail=2, successful_simulations=18),
            'B44 actual execution totals')
    require(len(IMAGES) == 20 and sum(x['successful_simulation'] for x in IMAGES.values()) == 18
            and sum(x['failed_simulation'] for x in IMAGES.values()) == 2, 'Original/qualified image counts')
    canonical = canonical_audit(parent, parent_structure)
    snapshot = copy.deepcopy(parent)
    snapshot.update(date='2026-11-06', baseline_commit=BASELINE, batch_baseline_commit=BASELINE,
        previous_snapshot='docs/snapshots/source_20261106_b43.json',
        parent_snapshot=dict(path='docs/snapshots/source_20261106_b43.json', sha256=PARENT_PINS['docs/snapshots/source_20261106_b43.json'], commit=BASELINE),
        source_freeze='B44 cumulative176 packages; exact inherited172 objects and support mapping; four new packages with two retained initial failures and two uniquely gated followups; no inherited execution or physical qualification.',
        parent_batch_canonical_base_sources=copy.deepcopy(parent.get('batch_canonical_base_sources', {})),
        batch_canonical_base_sources={},
        packages=copy.deepcopy(parent['packages']) + new_packages,
        batch_evidence_receipts=receipts,
        batch_actual_counts=totals,
        batch_static_audit=dict(script=rel(Path(__file__)), sha256=digest(Path(__file__)),
                               guard=rel(GUARD), root_evidence=rel(root_evidence_path), root_evidence_sha256=digest(root_evidence_path)))
    require(snapshot['packages'][:172] == parent['packages'] and snapshot['support_files'] == parent['support_files'],
            'Inherited objects/support mapping changed')
    # Recheck every bound original/archive/raw/vector/image after all reads.
    for name, expected in OBSERVED_BINDINGS.items():
        require(digest(path(name)) == expected, 'Evidence changed during audit: ' + name)
    tool_bindings(TOOL_BINDINGS)
    for name, expected in PARENT_PINS.items():
        binding(name, expected)
    structure = dict(schema='anscore-b44-static-audit-v1', status='PASS', baseline_commit=BASELINE,
        packages=176, inherited_package_objects_exact=172, inherited_support_mapping_exact=True,
        parent_inputs=PARENT_PINS, parent_formal_verification=inherited_result,
        baseline_text_normalizations=copy.deepcopy(parent['baseline_text_normalizations']),
        batch_new_packages=[p['path'] for p in new_packages],
        new_package_files={p['path']: len(p['sha256']) for p in new_packages},
        receipt_bindings=receipts, actual_finite_counts=totals, retained_images=IMAGES,
        successful_unique_images=sum(x['successful_simulation'] for x in IMAGES.values()),
        failed_unique_images=sum(x['failed_simulation'] for x in IMAGES.values()),
        total_unique_images=len(IMAGES), execution_guard=rel(GUARD),
        inherited_baseline_git_paths=34169,
        inherited_mode_type_oid='DEFERRED_TO_ROOT_STAGE_AND_CLOSEOUT; this auditor makes no Git-tree validation claim',
        combined_compile='NOT_RUN', inherited_checker='NOT_RUN', inherited_regression='NOT_RUN',
        model_imports=0, model_executions=0, hdl_executions=0, synthesis='NOT_RUN', pnr='NOT_RUN',
        sta='NOT_RUN', board='NOT_RUN', ppa='NOT_RUN', **canonical)
    require(not OUTPUT.exists() and not STRUCTURE.exists(), 'Refuse overwrite cumulative outputs')
    write_new(OUTPUT, snapshot)
    write_new(STRUCTURE, structure)
    return dict(status='PASS', snapshot_sha256=digest(OUTPUT), structure_sha256=digest(STRUCTURE),
                packages=176, actual_finite_counts=totals)


def main(reviewed_sha, root_evidence):
    require(digest(Path(__file__)) == reviewed_sha, 'Exact reviewed auditor SHA required')
    require(not OUTPUT.exists() and not STRUCTURE.exists() and not FAILURE.exists(), 'Prior audit output exists')
    plan, review = load(PLAN), load(REVIEW)
    require(plan['baseline_commit'] == BASELINE and plan['status'] == 'SOURCE_REVIEW_PENDING_NOT_EXECUTED', 'Static plan state')
    require(plan['auditor_sha256'] == reviewed_sha and review['auditor_sha256'] == reviewed_sha, 'Auditor binding')
    require(review['plan_sha256'] == digest(PLAN), 'Static plan binding')
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['explicit_unique_execution_gate'] is True, 'Missing unique gate')
    require(review['root_review']['reviewer'] == 'root' and review['root_review']['verdict'] == 'NO_BLOCKER', 'Root review')
    require(review['peer_review']['reviewer'] != 'root' and review['peer_review']['verdict'] == 'NO_BLOCKER', 'Peer review')
    root_evidence_path = path(root_evidence)
    require(rel(root_evidence_path) == ROOT_EVIDENCE, 'Unexpected root evidence index')
    binding(root_evidence_path, ROOT_EVIDENCE_SHA)
    require(review['root_evidence_sha256'] == ROOT_EVIDENCE_SHA and plan['parent_inputs'] == PARENT_PINS, 'Pinned input gate')
    require(set(plan['receipt_inputs']) == {role + '/' + phase for role, phase in EXPECTED}, 'Finite receipt domain')
    RECEIPT_PINS.update(plan['receipt_inputs'])
    for name, expected in PARENT_PINS.items():
        binding(name, expected)
    write_new(GUARD, dict(schema='anscore-b44-static-once-v1', status='ATTEMPT_STARTED_NO_RETRY',
        timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(), baseline_commit=BASELINE,
        auditor_sha256=reviewed_sha, plan_sha256=digest(PLAN), review_sha256=digest(REVIEW),
        root_evidence_sha256=ROOT_EVIDENCE_SHA, automatic_retry=False))
    try:
        result = audit(root_evidence_path)
    except Exception:
        write_new(FAILURE, dict(schema='anscore-b44-static-failure-v1', status='FAIL_STOP',
            baseline_commit=BASELINE, auditor_sha256=reviewed_sha, exception=traceback.format_exc(),
            original_artifacts_retained=True, automatic_retry=False, guard_retained=True))
        raise
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute-reviewed-sha', required=True)
    parser.add_argument('--root-evidence', default=ROOT_EVIDENCE)
    arguments = parser.parse_args()
    main(arguments.execute_reviewed_sha, arguments.root_evidence)
