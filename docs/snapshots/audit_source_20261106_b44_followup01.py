"""Independent partitioned B44 static followup; SOURCE ONLY until root gate.

Parent raw checks run in sixteen fixed, disjoint <=1000-record processes. Final
assembly reads their durable receipts, never repeats their mass raw hashes, and
checks new packages plus the full canonical HDL declaration domain. Each part's
observation time is distinct; this makes no cross-process atomicity claim.
No old script import/execution, model/HDL execution, Git mutation or cleanup.
The original monolithic TIMEOUT and all of its bytes remain retained.
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
GUARD = None
PLAN = HERE / 'source_20261106_b44_static_followup01_plan.json'
REVIEW = HERE / 'source_20261106_b44_static_followup01_review.json'
OUTPUT = HERE / 'source_20261106_b44.json'
STRUCTURE = HERE / 'source_20261106_b44_structure.json'
FAILURE = None
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
PATH_CACHE = {}
PARENT_RAW_BINDINGS = {}
PART_COUNT = 16
PART_SIZE = 1000
TOTAL_PARENT_ROWS = 15932
PARTS_DIR = HERE / 'b44_static_followup01_parts'
ASSEMBLY_RECEIPT = PARTS_DIR / 'assembly.json'
GATE = 'B44_STATIC_PARTITIONED_FOLLOWUP01_ONCE_01'
TIMEOUT_PATH = 'docs/snapshots/source_20261106_b44_static_timeout.json'
TIMEOUT_SHA = '7863a31eb633345e66c6d3fa5ffbb1ee446073f682b227a73290310f05b60a14'
BRIDGE_PATH = 'docs/snapshots/source_20261106_b44_inherited_canonical_bridge.json'
BRIDGE_SHA = 'bd9a39ded19c38173d99c66794e076901403ab601fc097eb2cd67255967d560e'
NORMALIZED_PATHS = {
    'cores/system/stream_multicast/check_results.json',
    'cores/signal_processing/cdf53_block/verification.json',
    'cores/image_processing/stream_ssim/verification.json',
    'cores/acceleration/binary_heap_queue/reports/validation.json',
}
CSC_SUPPORT = 'cores/signal_processing/dsp_isp_library/isp/csc_coeffs.vh'
ORIGINAL_TIMEOUT_PINS = {
    TIMEOUT_PATH: TIMEOUT_SHA,
    'docs/snapshots/audit_source_20261106_b44.py': 'f9f54a223e2fc28f1c3f727e4d8c4f4a3d1bbb3b5aa2910912de4ca963a2c764',
    'docs/snapshots/source_20261106_b44_static_plan.json': '69f0315df284c1a8f4053e1141ba5d283851f5aa7f5e668a4646ce50ae3945b5',
    'docs/snapshots/source_20261106_b44_static_review.json': '2b1becdc7b907b67094e13c04698088ac807c68a5c09e54de54a067710fad74a',
    'docs/snapshots/source_20261106_b44_static_plan_source_only01.json': '6b078478721f916c2f8d7998c2cb0aae25e40afd7391842057fe2f7bab45b738',
    '.git/anscore-b44-static-launch.py': '1909932e51ef03a6ef1c556b356a0e5cb2f4c8e179bac007fed1b3c8d07a1284',
    '.git/anscore-b44-static-once.json': '890925ce590c6c78773972aba2551d218ffa1414f1cb039de21acb4082b3c55e',
    '.git/anscore-b44-static-launch-once.json': 'e60d6e3ec8abc465871318b113c4eb275b2fe8f9631ea287474ed72c9b4bb6ae',
    '.git/anscore-b44-static-launch/child.json': '5a28351c423a461b784abbd0399deea37601306ee43f60d222308ff417bf4eb2',
    '.git/anscore-b44-static-launch/results.json': '4b68c3d1afd3b5c3207e9c739ed71f708384b57a7f9859eb885ab759d59c2d6e',
    '.git/anscore-b44-static-launch/plan.json': '69f0315df284c1a8f4053e1141ba5d283851f5aa7f5e668a4646ce50ae3945b5',
    '.git/anscore-b44-static-launch/review.json': '2b1becdc7b907b67094e13c04698088ac807c68a5c09e54de54a067710fad74a',
    '.git/anscore-b44-static-launch/stdout.raw': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    '.git/anscore-b44-static-launch/stderr.raw': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    '.git/anscore-b44-static-launch/taskkill.stdout.raw': 'cbd53ad4487e8a13f022cd0e72a8669b5b59e44868440fc38fcea5c25dd6c509',
    '.git/anscore-b44-static-launch/taskkill.stderr.raw': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
}


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def path(value, base=REPO):
    candidate = Path(str(value).replace('\\', '/'))
    candidate = candidate if candidate.is_absolute() else base / candidate
    # Metadata-domain construction uses lexical_name instead, so loading all
    # descriptors never resolves or opens the parent's thousands of raw paths.
    candidate = Path(os.path.abspath(candidate))
    key = os.path.normcase(str(candidate))
    if key in PATH_CACHE:
        return PATH_CACHE[key]
    candidate = candidate.resolve()
    require(candidate.is_relative_to(REPO), 'Path escaped repository: ' + str(candidate))
    PATH_CACHE[key] = candidate
    PATH_CACHE[os.path.normcase(str(candidate))] = candidate
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
    require(name == CSC_SUPPORT, 'Only the pre-existing explicit csc support hash-kind exception is allowed')
    require(support.get('hash_kind') == 'baseline_committed_git_blob', 'Inherited byte mismatch: ' + name)
    require(support.get('sha256') == expected, name)
    require(hashlib.sha256(raw).hexdigest() == support.get('executed_worktree_sha256'), name)
    lf = raw.replace(b'\r\n', b'\n')
    require(hashlib.sha256(lf).hexdigest() == expected, name)
    oid = hashlib.sha1(b'blob ' + str(len(lf)).encode() + b'\0' + lf).hexdigest()
    require(oid == support['baseline_blob_oid'], name)
    return 'PARENT_EXPLICIT_SUPPORT_GIT_BLOB'


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
    bridge = load(REPO / BRIDGE_PATH)
    require(bridge['schema'] == 'anscore-b44-inherited-canonical-bridge-v1' and
            bridge['baseline_commit'] == BASELINE and bridge['source_count'] == 12, 'Canonical bridge identity')
    require(set(bridge['sources']) == previous - set(PARENT_RAW_BINDINGS), 'Exact twelve missing parent canonical raw bindings')
    for name, item in parent.get('batch_canonical_base_sources', {}).items():
        if name in bridge['sources']:
            require(bridge['sources'][name]['sha256'] == item['sha256'] and
                    bridge['sources'][name]['baseline_blob_oid'] == item['baseline_blob_oid'], 'Existing parent canonical pin changed')
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
        raw = path(name).read_bytes()
        raw_sha = hashlib.sha256(raw).hexdigest()
        if name in previous:
            if name in PARENT_RAW_BINDINGS:
                require(raw_sha == PARENT_RAW_BINDINGS[name],
                        'Canonical source differs from its parent-part observation: ' + name)
            else:
                item = bridge['sources'][name]
                oid = hashlib.sha1(b'blob ' + str(len(raw)).encode() + b'\0' + raw).hexdigest()
                require(raw_sha == item['sha256'] and len(raw) == item['bytes'] and
                        oid == item['raw_blob_oid'] == item['baseline_blob_oid'] and
                        item['baseline_git_mode'] == '100644' and item['baseline_git_type'] == 'blob' and
                        item['hash_kind'] == 'RAW_BYTES_EQUAL_BASELINE_COMMITTED_BLOB' and item['normalization'] == 'NONE',
                        'Canonical bridge raw baseline mismatch: ' + name)
        require(OBSERVED_BINDINGS.setdefault(name, raw_sha) == raw_sha, 'Conflicting canonical raw binding')
        text = strip_comments(raw.decode('utf-8-sig'))
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
                inherited_canonical_bridge=dict(path=BRIDGE_PATH, sha256=BRIDGE_SHA, source_count=12,
                                                raw_bytes_equal_baseline_blob=True, new_normalization_exceptions=0),
                exact_byte_dependency_aliases=copy.deepcopy(parent.get('exact_byte_dependency_aliases', [])))


def audit(root_evidence_path, inherited_result):
    parent = load(path('docs/snapshots/source_20261106_b43.json'))
    parent_structure = load(path('docs/snapshots/source_20261106_b43_structure.json'))
    parent_closeout = load(path('docs/snapshots/source_20261106_b43_closeout.json'))
    # Parent raw paths were checked only by independent fixed-domain parts.
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
    require(canonical['source_files'] == 386 and canonical['module_declarations'] == 388, 'Cumulative canonical/module counts')
    snapshot = copy.deepcopy(parent)
    snapshot.update(date='2026-11-06', baseline_commit=BASELINE, batch_baseline_commit=BASELINE,
        previous_snapshot='docs/snapshots/source_20261106_b43.json',
        parent_snapshot=dict(path='docs/snapshots/source_20261106_b43.json', sha256=PARENT_PINS['docs/snapshots/source_20261106_b43.json'], commit=BASELINE),
        source_freeze='B44 cumulative176 packages; exact inherited172 objects and support mapping; four new packages with two retained initial failures and two uniquely gated followups; no inherited execution or physical qualification.',
        parent_batch_canonical_base_sources=copy.deepcopy(parent.get('batch_canonical_base_sources', {})),
        batch_canonical_base_sources=copy.deepcopy(load(REPO / BRIDGE_PATH)['sources']),
        packages=copy.deepcopy(parent['packages']) + new_packages,
        batch_evidence_receipts=receipts,
        batch_actual_counts=totals,
        batch_static_audit=dict(script=rel(Path(__file__)), sha256=digest(Path(__file__)),
                               guard=rel(GUARD), partitioned_parent_verification=inherited_result,
                               original_static_timeout=dict(path=TIMEOUT_PATH, sha256=TIMEOUT_SHA,
                                                            status='TIMEOUT_RETAINED_NOT_QUALIFIED'),
                               inherited_canonical_bridge=dict(path=BRIDGE_PATH, sha256=BRIDGE_SHA),
                               root_evidence=rel(root_evidence_path), root_evidence_sha256=digest(root_evidence_path)))
    require(snapshot['packages'][:172] == parent['packages'] and snapshot['support_files'] == parent['support_files'],
            'Inherited objects/support mapping changed')
    # Recheck only assembly-bound evidence, never the parent mass raw mappings.
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
        original_static_timeout=dict(path=TIMEOUT_PATH, sha256=TIMEOUT_SHA, status='TIMEOUT_RETAINED_NOT_QUALIFIED'),
        static_parent_observation='Independent bounded parts; observed at each receipt time, not a cross-process atomic snapshot',
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


def json_sha(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     separators=(',', ':')).encode('utf-8')).hexdigest()


def lexical_name(value, base=REPO):
    """Normalize metadata only: no exists/stat/resolve/read on mapped raw paths."""
    candidate = Path(str(value).replace('\\', '/'))
    candidate = candidate if candidate.is_absolute() else base / candidate
    candidate = Path(os.path.abspath(candidate))
    require(candidate.is_relative_to(REPO), 'Lexical mapped path escapes repository')
    return candidate.relative_to(REPO).as_posix()


def parent_domain():
    parent = load(REPO / 'docs/snapshots/source_20261106_b43.json')
    structure = load(REPO / 'docs/snapshots/source_20261106_b43_structure.json')
    closeout = load(REPO / 'docs/snapshots/source_20261106_b43_closeout.json')
    require(len(parent['packages']) == 172 and closeout['packages'] == 172, 'Parent package count')
    require(structure['status'] == 'PASS' and
            closeout['status'] == 'SOURCE_AUDIT_PASS_BOUNDED_QUALIFICATION_CLEANUP_RETAINED', 'Parent not closed')
    normalizations = parent['baseline_text_normalizations']
    require(normalizations == structure['baseline_text_normalizations'] and
            set(normalizations) == NORMALIZED_PATHS, 'Only the exact parent four normalization paths')
    supports = parent.get('support_file_additions', {})
    require({k for k, v in supports.items() if v.get('hash_kind') == 'baseline_committed_git_blob'} == {CSC_SUPPORT},
            'Support hash-kind exception domain changed')
    rows = []
    for package_index, package in enumerate(parent['packages']):
        for key, expected in sorted(package['sha256'].items()):
            rows.append(dict(domain='package', package_index=package_index, package_path=package['path'],
                             key=key, path=lexical_name(key, REPO / package['path']), sha256=expected))
    require(len(rows) == 15815, 'Parent formal mapping count')
    for key, expected in sorted(parent['support_files'].items()):
        rows.append(dict(domain='support', key=key, path=lexical_name(key), sha256=expected))
    require(len(parent['support_files']) == 29, 'Parent support mapping count')
    artifacts = sorted(closeout['all_retained_artifacts'], key=lambda x: x['path'])
    require(len(artifacts) == 88 and len({x['path'] for x in artifacts}) == 88, 'Parent retained artifact domain')
    for index, artifact in enumerate(artifacts):
        rows.append(dict(domain='artifact', artifact_index=index, path=lexical_name(artifact['path']),
                         sha256=artifact['sha256'], artifact=copy.deepcopy(artifact)))
    require(len(rows) == TOTAL_PARENT_ROWS, 'Total parent verification domain')
    metadata = dict(parent_inputs=PARENT_PINS, package_objects_sha256=json_sha(parent['packages']),
                    support_mapping_sha256=json_sha(parent['support_files']),
                    retained_artifact_mapping_sha256=json_sha(artifacts),
                    complete_mapping_sha256=json_sha(rows), total_records=len(rows),
                    package_records=15815, support_records=29, artifact_records=88)
    return parent, rows, metadata


def part_paths(index):
    tag = f'{index:02d}'
    return (PARTS_DIR / ('part_' + tag + '.json'),
            PARTS_DIR / ('part_' + tag + '_failure.json'),
            REPO / ('.git/anscore-b44-static-followup01-part-' + tag + '-once.json'))


def expected_children(reviewed_sha):
    prefix = [r'C:\Program Files\Python312\python.exe', '-I', '-B', str(Path(__file__).resolve()),
              '--execute-reviewed-sha', reviewed_sha, '--phase']
    children = []
    for index in range(PART_COUNT):
        output, failure, guard = part_paths(index)
        children.append(dict(name=f'parent_part_{index:02d}', phase='part', part_index=index,
            argv=prefix + ['part', '--part-index', str(index)], output=rel(output),
            output_schema='anscore-b44-parent-part-v1', failure_output=rel(failure), execution_guard=rel(guard)))
    children.append(dict(name='assemble', phase='assemble', argv=prefix + ['assemble'],
        output=rel(ASSEMBLY_RECEIPT), output_schema='anscore-b44-static-assembly-v1',
        failure_output=rel(PARTS_DIR / 'assembly_failure.json'),
        execution_guard='.git/anscore-b44-static-followup01-assemble-once.json',
        final_outputs=[rel(OUTPUT), rel(STRUCTURE)]))
    return children


def timeout_binding_check(plan):
    require(plan['original_timeout_bindings'] == ORIGINAL_TIMEOUT_PINS, 'Frozen original timeout pins changed')
    for name, expected in ORIGINAL_TIMEOUT_PINS.items():
        binding(name, expected)
    old = load(REPO / TIMEOUT_PATH)
    require(old['schema'] == 'anscore-b44-static-timeout-v1' and
            old['status'] == 'TIMEOUT_RETAINED_NOT_QUALIFIED' and old['observed_seconds'] == 20.86 and
            old['process_exited'] is True and old['automatic_retry'] is False, 'Original timeout history changed')
    child = load(REPO / '.git/anscore-b44-static-launch/child.json')
    require(child['status'] == 'TIMEOUT' and child['seconds'] == 20.86 and child['process_exited'] is True and
            child['process_evidence_saved'] is True and child['output_capture_complete'] is True,
            'Original timeout process evidence incomplete')
    require(not (HERE / 'source_20261106_b44_static_failure.json').exists(), 'Unexpected original inner failure JSON')


def gate_check(reviewed_sha, phase, index):
    require(digest(Path(__file__)) == reviewed_sha, 'Exact reviewed auditor SHA required')
    plan, review = load(PLAN), load(REVIEW)
    require(plan['schema'] == 'anscore-b44-partitioned-static-plan-v1' and
            plan['baseline_commit'] == BASELINE and plan['status'] == 'SOURCE_REVIEW_PENDING_NOT_EXECUTED', 'Plan state')
    require(review['schema'] == 'anscore-b44-partitioned-static-review-v1' and
            plan['auditor_sha256'] == reviewed_sha and review['auditor_sha256'] == reviewed_sha, 'Auditor binding')
    require(review['plan_sha256'] == digest(PLAN), 'Plan binding')
    require(review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and review['explicit_unique_execution_gate'] is True
            and review['execution_gate'] == GATE, 'Missing unique partitioned gate')
    require(review['root_review']['reviewer'] == 'root' and review['root_review']['verdict'] == 'NO_BLOCKER', 'Root review')
    require(review['peer_review']['reviewer'] != 'root' and review['peer_review']['verdict'] == 'NO_BLOCKER', 'Peer review')
    require(review['launcher_review']['verdict'] == 'NO_BLOCKER', 'Launcher review')
    binding('.git/anscore-b44-static-followup01-launch.py', review['launcher_sha256'])
    require(review['root_evidence_sha256'] == ROOT_EVIDENCE_SHA and
            plan['parent_inputs'] == PARENT_PINS, 'Pinned input gate')
    require(plan['root_evidence'] == dict(path=ROOT_EVIDENCE, sha256=ROOT_EVIDENCE_SHA), 'Root index plan binding')
    binding(ROOT_EVIDENCE, ROOT_EVIDENCE_SHA)
    require(plan['canonical_dependency_bridge'] == dict(path=BRIDGE_PATH, sha256=BRIDGE_SHA), 'Canonical bridge plan pin')
    binding(BRIDGE_PATH, BRIDGE_SHA)
    for name, expected in PARENT_PINS.items():
        binding(name, expected)
    require(set(plan['receipt_inputs']) == {role + '/' + p for role, p in EXPECTED}, 'Finite receipt domain')
    RECEIPT_PINS.update(plan['receipt_inputs'])
    require(plan['partition'] == dict(part_count=16, records_per_part=1000, total_records=15932,
            package_records=15815, support_records=29, artifact_records=88,
            order='package_index then sorted key; support sorted key; artifact sorted path'), 'Partition domain')
    require(plan['hard_seconds'] == 20 and plan['tree_kill_seconds'] == 5 and plan['sole_drain_seconds'] == 2 and
            plan['automatic_retry'] is False, 'Finite child budget')
    require(plan['children'] == expected_children(reviewed_sha), 'Exact finite static child sequence')
    timeout_binding_check(plan)
    selected = plan['children'][index if phase == 'part' else PART_COUNT]
    require(selected['phase'] == phase and (phase != 'part' or selected['part_index'] == index), 'Phase mismatch')
    context = dict(baseline_commit=BASELINE, auditor_sha256=reviewed_sha, plan_sha256=digest(PLAN),
                   review_sha256=digest(REVIEW), launcher_sha256=review['launcher_sha256'],
                   execution_gate=GATE, parent_inputs=PARENT_PINS, original_timeout_sha256=TIMEOUT_SHA,
                   canonical_bridge_sha256=BRIDGE_SHA)
    return plan, selected, context


def expected_raw_observation(row, observed, parent):
    """Receipt-only consistency check; never opens the parent's mapped raw file."""
    require(set(observed) == {'mapping', 'raw_sha256', 'result'}, 'Part observation shape')
    require(observed['mapping'] == row, 'Part mapping row differs from exact parent descriptor')
    current, result = observed['raw_sha256'], observed['result']
    if result == 'BYTE_EXACT':
        require(current == row['sha256'], 'Part exact raw hash')
    elif result == 'PARENT_EXPLICIT_LF_TO_CRLF':
        require(row['domain'] != 'artifact' and row['path'] in NORMALIZED_PATHS, 'Normalization domain')
        normalization = parent['baseline_text_normalizations'][row['path']]
        require(row['sha256'] == normalization['committed_sha256'] and
                current == normalization['worktree_sha256'], 'Normalization receipt raw pin')
    elif result == 'PARENT_EXPLICIT_SUPPORT_GIT_BLOB':
        require(row['domain'] == 'support' and row['path'] == CSC_SUPPORT, 'Support exception domain')
        support = parent['support_file_additions'][CSC_SUPPORT]
        require(row['sha256'] == support['sha256'] and current == support['executed_worktree_sha256'], 'Support raw pin')
    else:
        raise AssertionError('Unknown inherited verification result: ' + str(result))


def run_part(index, context):
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    parent, rows, metadata = parent_domain()
    start, stop = index * PART_SIZE, min((index + 1) * PART_SIZE, len(rows))
    selected = rows[start:stop]
    require(len(selected) == (1000 if index < 15 else 932), 'Fixed part size')
    observations, cache = [], {}
    for row in selected:
        current = path(row['path'])
        require(rel(current) == row['path'], 'Mapped path redirected through a link')
        cache_key = (row['path'], row['sha256'], row['domain'] == 'artifact')
        if cache_key not in cache:
            if row['domain'] == 'artifact':
                binding(current, row['sha256'])
                result = 'BYTE_EXACT'
            else:
                result = normalized_inherited(current, row['sha256'], parent['baseline_text_normalizations'], parent)
            cache[cache_key] = dict(raw_sha256=OBSERVED_BINDINGS[rel(current)], result=result)
        observation = dict(mapping=row, **cache[cache_key])
        expected_raw_observation(row, observation, parent)
        observations.append(observation)
    # Only tiny pinned controls/parent JSONs are rechecked here. Each mapped raw
    # file above is observed once; no hidden second mass read is performed.
    for name, expected in {**PARENT_PINS, **ORIGINAL_TIMEOUT_PINS, BRIDGE_PATH: BRIDGE_SHA}.items():
        require(digest(REPO / name) == expected, 'Pinned data changed during part: ' + name)
    output, _, _ = part_paths(index)
    receipt = dict(schema='anscore-b44-parent-part-v1', status='PASS', phase='part', part_index=index,
        context=context, parent_mapping=metadata, record_start=start, record_stop=stop,
        record_count=len(selected), mapping_sha256=json_sha(selected), observations_sha256=json_sha(observations),
        observations=observations, unique_observed_paths=len({x['mapping']['path'] for x in observations}),
        observed_started_utc=started, observed_completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
        raw_observation_semantics='Each path at this part time; no cross-process atomicity claim',
        parent_assets_written=0, model_executions=0, hdl_executions=0, automatic_retry=False)
    write_new(output, receipt)
    return dict(status='PASS', phase='part', part_index=index, output=rel(output), receipt_sha256=digest(output))


def assemble_parent_parts(plan, context):
    parent, rows, metadata = parent_domain()
    receipts, all_rows = [], []
    exact = adjusted = 0
    for index in range(PART_COUNT):
        spec = plan['children'][index]
        receipt_path, _, guard = part_paths(index)
        raw_sha = digest(receipt_path)
        binding(receipt_path, raw_sha)
        receipt = load(receipt_path)
        require(receipt['schema'] == 'anscore-b44-parent-part-v1' and receipt['status'] == 'PASS' and
                receipt['phase'] == 'part' and receipt['part_index'] == index, 'Missing/nonpassing parent part')
        require(receipt['context'] == context and receipt['parent_mapping'] == metadata, 'Part context/parent metadata')
        start, stop = index * PART_SIZE, min((index + 1) * PART_SIZE, len(rows))
        expected = rows[start:stop]
        require((receipt['record_start'], receipt['record_stop'], receipt['record_count']) ==
                (start, stop, len(expected)), 'Part range overlap/gap')
        require(receipt['mapping_sha256'] == json_sha(expected), 'Part mapping fingerprint')
        observations = receipt['observations']
        require(len(observations) == len(expected) and receipt['observations_sha256'] == json_sha(observations),
                'Part observation count/fingerprint')
        for row, observation in zip(expected, observations):
            expected_raw_observation(row, observation, parent)
            require(PARENT_RAW_BINDINGS.setdefault(row['path'], observation['raw_sha256']) == observation['raw_sha256'],
                    'Conflicting parent raw observations across records')
            if row['domain'] == 'package':
                exact += observation['result'] == 'BYTE_EXACT'
                adjusted += observation['result'] != 'BYTE_EXACT'
        all_rows.extend(x['mapping'] for x in observations)
        guard_data = load(guard)
        require(guard_data['context'] == context and guard_data['phase'] == 'part' and
                guard_data['part_index'] == index and guard_data['automatic_retry'] is False, 'Part exclusive guard')
        external_path = REPO / '.git/anscore-b44-static-followup01-launch' / spec['name'] / 'child.json'
        external = load(external_path)
        require(external['name'] == spec['name'] and external['argv'] == spec['argv'] and
                external['status'] == 'PASS' and external['exit_code'] == 0 and external['cleanup'] == [] and
                external['process_exited'] is True and external['output_capture_complete'] is True and
                external['process_evidence_saved'] is True, 'Part external bounded process receipt')
        require(external['output'] == spec['output'] and external['receipt_sha256'] == raw_sha and
                external['plan_sha256'] == context['plan_sha256'] and
                external['review_sha256'] == context['review_sha256'] and
                external['auditor_sha256'] == context['auditor_sha256'], 'Part external receipt binding')
        receipts.append(dict(part_index=index, path=rel(receipt_path), sha256=raw_sha,
            record_start=start, record_stop=stop, record_count=len(expected),
            guard=dict(path=rel(guard), sha256=digest(guard)),
            external_child=dict(path=rel(external_path), sha256=digest(external_path)),
            observed_started_utc=receipt['observed_started_utc'], observed_completed_utc=receipt['observed_completed_utc']))
    require(all_rows == rows and len(all_rows) == TOTAL_PARENT_ROWS and
            len({json_sha(x) for x in all_rows}) == TOTAL_PARENT_ROWS, 'Exhaustive disjoint parent row union')
    require(exact + adjusted == 15815, 'Complete inherited formal mapping count')
    return dict(formal_mappings=15815, byte_exact=exact, explicit_parent_adjustments=adjusted,
        support_mappings=29, retained_artifacts=88, total_mapping_records=15932,
        parent_mapping=metadata, partition_count=16, part_receipts=receipts,
        raw_rehash_in_assembly=False,
        observation_semantics='Per-part bounded observations, not a cross-process atomic snapshot')


def main(reviewed_sha, phase, index):
    global GUARD, FAILURE
    require((phase == 'part' and index is not None and 0 <= index < PART_COUNT) or
            (phase == 'assemble' and index is None), 'Invalid phase/index')
    plan, selected, context = gate_check(reviewed_sha, phase, index)
    GUARD, FAILURE = path(selected['execution_guard']), path(selected['failure_output'])
    require(not path(selected['output']).exists() and not FAILURE.exists(), 'Prior phase output exists')
    if phase == 'assemble':
        require(not OUTPUT.exists() and not STRUCTURE.exists(), 'Refuse prior cumulative output')
    PARTS_DIR.mkdir(exist_ok=True)
    write_new(GUARD, dict(schema='anscore-b44-partitioned-static-once-v1', status='ATTEMPT_STARTED_NO_RETRY',
        phase=phase, part_index=index, context=context,
        timestamp=datetime.datetime.now(datetime.timezone.utc).isoformat(), automatic_retry=False))
    try:
        if phase == 'part':
            result = run_part(index, context)
        else:
            inherited_result = assemble_parent_parts(plan, context)
            result = audit(path(ROOT_EVIDENCE), inherited_result)
            assembly = dict(schema='anscore-b44-static-assembly-v1', status='PASS', phase='assemble',
                context=context, parent_verification=inherited_result, part_receipts=inherited_result['part_receipts'],
                snapshot=dict(path=rel(OUTPUT), sha256=result['snapshot_sha256']),
                structure=dict(path=rel(STRUCTURE), sha256=result['structure_sha256']),
                original_timeout=dict(path=TIMEOUT_PATH, sha256=TIMEOUT_SHA, status='TIMEOUT_RETAINED_NOT_QUALIFIED'),
                planned_static_children=17, completed_parent_parts=16,
                automatic_retry=False, new_model_executions=0, new_hdl_executions=0)
            write_new(ASSEMBLY_RECEIPT, assembly)
            result.update(phase='assemble', output=rel(ASSEMBLY_RECEIPT), receipt_sha256=digest(ASSEMBLY_RECEIPT))
    except Exception:
        write_new(FAILURE, dict(schema='anscore-b44-partitioned-static-failure-v1', status='FAIL_STOP',
            phase=phase, part_index=index, context=context, exception=traceback.format_exc(),
            original_artifacts_retained=True, automatic_retry=False, guard_retained=True))
        raise
    print(json.dumps(result), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute-reviewed-sha', required=True)
    parser.add_argument('--phase', required=True, choices=('part', 'assemble'))
    parser.add_argument('--part-index', type=int)
    arguments = parser.parse_args()
    main(arguments.execute_reviewed_sha, arguments.phase, arguments.part_index)


