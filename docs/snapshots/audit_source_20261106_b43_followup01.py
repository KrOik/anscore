"""SPDX-License-Identifier: Apache-2.0. Fresh B43 static evidence audit.

No project module, model, runner or historical auditor is imported/executed.
Only stdlib and read-only Git are used. A/root must review this complete source
before the sole execution. All assertions precede both exclusive snapshot writes.
"""
from pathlib import Path
import copy
import hashlib
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = '98176a8f970354ebd6191d0370662ab35ff53664'
PARENT = 'docs/snapshots/source_20261106_b42.json'
STRUCTURE = 'docs/snapshots/source_20261106_b42_structure.json'
PARENT_SHA = '54b7c5719cf50d92f1a2c47b35f78bc1607c9db39ea1bcf6f850f6ff6aa0c8e7'
STRUCTURE_SHA = '773ea15b738a81a02ab0d11d08504d9fb7856a8e33852370b8674d473e89eb44'
OUTPUTS = ('docs/snapshots/source_20261106_b43.json',
           'docs/snapshots/source_20261106_b43_structure.json')
GUARD = '.git/anscore-b43-static-followup01-once.json'
PLAN = 'docs/snapshots/source_20261106_b43_static_followup01_plan.json'
FOLLOWUP_SOURCE = 'docs/snapshots/audit_source_20261106_b43_followup01.py'
ORIGINAL_SOURCE = 'docs/snapshots/audit_source_20261106_b43.py'
ORIGINAL_SOURCE_SHA = 'e8e6fbf06e536ab4385e6a913f52501b26cfdb30bb3547ba2693f5d35fae11e0'
ORIGINAL_GUARD = '.git/anscore-b43-audit-once.json'
ORIGINAL_GUARD_SHA = '31b7163adb098f1cfb772a36918afc066e4d6fc24b02401a6cda065ba88dd724'
ORIGINAL_FAILURE = 'docs/snapshots/source_20261106_b43_static_failure.json'
ORIGINAL_FAILURE_SHA = '18f778614beb48bc4df161834899b9cadb6ae66fcda1c95db51730eca7609800'
# These bindings come from B's final retained sole-run evidence.
B_BRIDGE_SHA = 'e8bdebb94641fa507094ce2e70ede493c348b4082c414ba3a1faef0235cf45b0'
B_RECEIPT = 'reports/20261106T095401_611506Z/results.json'
B_RECEIPT_SHA = '0f3eafde5fcba192297a4509906b6dfec0790227c20f19307173417395dcfcec'
B_PLAN_SHA = 'f872ba9b2402de7788eb1be33270d3bd461e29b87ada7085006821c6dc4aedf0'
B_SEAL_SHA = '9321275e56e61c3ddf1a4055179cfbbf93d21b7e098e2818b6f7b1ee49e1d858'
PACKAGES = [
    ('cores/communication/ipv4_lpm_forward', 'ipv4_lpm_forward',
     'ipv4_two_route_forwarder', 'LOW default / MEDIUM maximum',
     'aaa5eb290b0303f4b00400c3b230164872544e2a5f7ccac8bd6c2c2738744e80'),
    ('cores/storage/watermark_event_merge', 'watermark_event_merge',
     'dual_itch_time_merge', 'MEDIUM',
     '1e4847e0410fe177f44d17fa9fcc99524625477060b3350167ec74e1e862265e'),
    ('cores/signal_processing/adc_code_density', 'adc_code_density',
     'trigger_adc_density256', 'MEDIUM', B_BRIDGE_SHA),
    ('cores/image_processing/causal_palette_diffusion', 'causal_palette_diffusion',
     'rgb_palette_diffusion', 'LOW default / MEDIUM maximum',
     '2074b5ba06f4594eea9d8ef1698ca9cf09dd1c9f4089dcb123584ecebbe2795e')]
RUN_PINS = {
    'cores/communication/ipv4_lpm_forward':
      ('reports/20261106T093803674909Z/results.json',
       '3169d24b52bcdfa99b5247ebf1c25e3c7f07cb9385faaea0edb6ef4726148e40',
       'fffbdb7fe1b27b58843598a1915ae58b4569b04e35b857c43d70dcf67a2c49a4'),
    'cores/storage/watermark_event_merge':
      ('reports/20261106T094526734115Z/results.json',
       'd1914d7309d7709ab6553387ff6800ce3e36033f832297a336b92575417ac1cc',
       '81beec0a64374e3ae4cbcc53236c8c081a48ac58ce536f725954ad5f70a14aa1'),
    'cores/signal_processing/adc_code_density':
      (B_RECEIPT, B_RECEIPT_SHA, B_PLAN_SHA)}
BASE_ADDITIONS = {
    'cores/system/common_scaffold/image/histogram/rtl/img_hist_accumulator.v':
      ('fd988974225e4ec2b8fac92a13a8872ba4384b7f',
       '9eed1a9a5e8b899f7c36d14f7be83fa669408a11be7f90905eac4242b2fd9a6f'),
    'cores/system/extended_library/src/isp_rgb2gray.v':
      ('c0efdebceeee95982b73d6f75c7e302d1f39bb83',
       'd0138236731c6649b8c4769989ee05fe8c4e00a6a9b8a26e2af81dc953331591')}
# Four inherited JSON records have Git LF bytes and existing CRLF worktree
# bytes. The independent root source review fixed these exact bindings; the
# audit rederives every relation itself and never imports its review helper.
INHERITED_NORMALIZATIONS = {
    'cores/system/stream_multicast/check_results.json':
      ('bf29b65a89421f6d467e112d03a7f390cd6088e8',
       'e26c920392650e96fcd211d6ccfac2aa0d9c178f45f86d0b2aff7f294619c9a5',
       'c75a4b37a7daeff36384c24acf9e4cf444b46d9cdd8ef7c863edd5edc62246a1'),
    'cores/signal_processing/cdf53_block/verification.json':
      ('18189649879fa7fe98aa6ec95eec6584b858b047',
       '943ca417b5ccf13dd10541e67fbdbd7eb17599f517df7cddbb2c5249c942138a',
       '375685dfd9efb85ef586709d062235fdb182411d32231b8a8795a180d72c87a3'),
    'cores/image_processing/stream_ssim/verification.json':
      ('b1d221f114ab6e71a0eacd0b5da03aba80db5bac',
       'a368591429afdccb4ebb104b2859a566e8b42366f2716ec7ab7318886e439603',
       'b6b170ee25baf830b265c63b9c0fe8b955a599bbff9298c1a96cb8341d3882a7'),
    'cores/acceleration/binary_heap_queue/reports/validation.json':
      ('9ece5bba41dcc096c30bb6cffb07b351e50327ac',
       'e02194d91536ae8b1d3f0c6069056819cce1e84c603fb6febf150c61ebf8be77',
       '9f3c55b99865fd46a064d242807c4b0789884b0be8b8fe8e333f751c322fef3d')}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def digest(path):
    return sha(path.read_bytes())


def load(path):
    return json.loads(path.read_bytes())


def git(*argv, data=None):
    return subprocess.run(['git', *argv], cwd=ROOT, input=data,
                          capture_output=True, check=True, timeout=20).stdout


def ref(package, name):
    path = Path(name)
    path = (path if path.is_absolute() else
            ROOT / name if name.replace('\\', '/').startswith('cores/') else package / name).resolve()
    assert path.is_relative_to(ROOT), ('evidence outside repository', name)
    return path


def checked_map(package, mapping):
    assert isinstance(mapping, dict)
    for name, value in mapping.items():
        assert isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), name
        assert digest(ref(package, name)) == value, ('byte map', name)


def inherited_files(packages):
    normalizations, count = {}, 0
    for package in packages:
        for name, value in package['sha256'].items():
            assert isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), name
            path = ref(ROOT / package['path'], name)
            relative = path.relative_to(ROOT).as_posix()
            count += 1
            if relative not in INHERITED_NORMALIZATIONS:
                assert digest(path) == value, ('inherited formal bytes', relative)
                continue
            oid, committed_sha, worktree_sha = INHERITED_NORMALIZATIONS[relative]
            assert relative not in normalizations and value == committed_sha
            raw, current = git('show', BASE + ':' + relative), path.read_bytes()
            assert sha(raw) == committed_sha and sha(current) == worktree_sha
            assert b'\r' not in raw and b'\n' in raw
            assert current == raw.replace(b'\n', b'\r\n')
            assert json.loads(current) == json.loads(raw)
            assert git('rev-parse', BASE + ':' + relative).decode().strip() == oid
            assert git('hash-object', '--path=' + relative, str(path)).decode().strip() == oid
            normalizations[relative] = dict(baseline_commit=BASE, baseline_blob_oid=oid,
                committed_sha256=committed_sha, worktree_sha256=worktree_sha,
                normalization='EXACT_LF_COMMITTED_TO_CRLF_WORKTREE', semantic_json_equal=True,
                filtered_oid_exact=True, source_or_metadata_content_changed=False)
    assert count == 15374 and set(normalizations) == set(INHERITED_NORMALIZATIONS)
    return normalizations, count


def tool_map(value):
    rows = value if isinstance(value, list) else [
        item if isinstance(item, dict) else dict(path=name, sha256=item)
        for name, item in value.items()]
    result = {}
    for row in rows:
        path = Path(row['path']).resolve()
        assert digest(path) == row['sha256'], ('tool/runtime', str(path))
        assert path not in result or result[path] == row['sha256']
        result[path] = row['sha256']
    return result


def image_map(package, mapping):
    result = {}
    for name, value in mapping.items():
        path = ref(package, name)
        assert path.is_relative_to(package) and path.suffix == '.vvp'
        assert digest(path) == value
        result[path] = value
    return result


def merge(target, values):
    for path, value in values.items():
        assert path not in target or target[path] == value
        target[path] = value


def inventory(package):
    result = {}
    for path in sorted(package.rglob('*')):
        relative = path.relative_to(package)
        if path.is_file() and not set(relative.parts) & {'.build', '.work', '__pycache__'}:
            assert path.suffix not in ('.vvp', '.pyc'), ('binary in formal files', str(path))
            result[relative.as_posix()] = digest(path)
    return result


def attributes(package, files, is_a):
    # A's executed bytes are explicitly CRLF; all other B43 packages are LF.
    expected = b'* -text\r\n' if is_a else b'* -text\n'
    assert (package / '.gitattributes').read_bytes() == expected
    for name in files:
        if Path(name).name == '.gitattributes':
            assert (package / name).read_bytes() == expected
    names = [str((package / name).relative_to(ROOT)).replace('\\', '/') for name in files]
    raw = git('check-attr', '-z', '--stdin', 'text', 'filter',
              'working-tree-encoding', data=('\0'.join(names) + '\0').encode()).split(b'\0')
    assert raw.pop() == b'' and len(raw) == len(names) * 9
    for index in range(0, len(raw), 3):
        name, key, value = raw[index:index + 3]
        assert value == (b'unset' if key == b'text' else b'unspecified'), (name, key, value)


def bridge(package, expected):
    path = package / 'B43_DELIVERY.json'
    assert digest(path) == expected
    value = load(path)
    states = value.get('status', value.get('maturity', []))
    assert 'HW_UNVERIFIED' in states or value.get('hardware') == 'HW_UNVERIFIED'
    assert value.get('baseline', value.get('baseline_commit')) == BASE
    for field in ('package_sha256', 'formal_files_sha256', 'formal_payload_sha256', 'current_executable_sources',
                  'current_source_sha256', 'source_archive', 'numerical_vectors',
                  'vector_summaries', 'vectors', 'raw_streams', 'raw_logs'):
        if isinstance(value.get(field), dict):
            checked_map(package, value[field])
    for field in ('qualification', 'audit', 'seal', 'status_document'):
        if field in value and field + '_sha256' in value:
            assert digest(ref(package, value[field])) == value[field + '_sha256']
    # B's bridge binds SOURCE_SEAL rather than duplicating its four-tool map.
    tools = tool_map(value['tools'] if 'tools' in value else load(ref(package, value['seal']))['tools'])
    for item in value['source_mapping']:
        source = item.get('current', item.get('source'))
        archive = item.get('checked_archive', item.get('archive', item.get('exact_checked_copy')))
        assert source and archive
        assert digest(ref(package, source)) == item['sha256'] == digest(ref(package, archive))
    return value, tools


def limits(record):
    execution = next(record[key] for key in ('timeout_seconds', 'execution_deadline_seconds',
                                            'hard_seconds', 'deadline_seconds') if key in record)
    assert execution == 20 and record['tree_kill_seconds'] == 5 and record['drain_seconds'] == 2


def verify_child(package, receipt_path, record, expected, tools, compiled, allow_loader=False):
    assert record['name'] == expected['name']
    assert record['argv'] == expected['argv'] and record['cwd'] == expected['cwd'], record['name']
    assert Path(record['cwd']).resolve().is_relative_to(ROOT)
    executable = Path(record['argv'][0]).resolve()
    assert executable in tools and executable.stem.lower() in ('python', 'iverilog', 'vvp')
    limits(record)
    for key in ('timeout_seconds', 'execution_deadline_seconds', 'hard_seconds', 'deadline_seconds'):
        if key in expected:
            assert expected[key] == 20
    if 'tree_kill_seconds' in expected:
        limits(expected)
    streams = {}
    for stream in ('stdout', 'stderr'):
        if isinstance(record.get(stream), dict):
            item = record[stream]
            raw = ref(package, item['path']).read_bytes()
            assert sha(raw) == item['sha256'] and len(raw) == item['bytes']
        else:
            raw = (receipt_path.parent / (record['name'] + '.' + stream + '.txt')).read_bytes()
            assert sha(raw) == record[stream + '_sha256']
        streams[stream] = raw
    assert record['status'] in ('PASS', 'FAIL')
    code = record.get('returncode', record.get('exit_code'))
    assert not record.get('timed_out', False) and record.get('drained', True)
    assert not record.get('cleanup') and not record.get('tree_kill')
    assert record.get('active_child') is None
    for flag in ('process_exited', 'process_evidence_saved', 'output_capture_complete'):
        if flag in record:
            assert record[flag] is True
    assert record.get('capture_error') is None
    if record['status'] == 'PASS':
        assert code == 0
    else:
        assert allow_loader and record['name'] == 'sim_core_1x1_d8'
        assert code == -1073741515 and streams == dict(stdout=b'', stderr=b'')
    marker = expected.get('marker')
    if marker and record['status'] == 'PASS':
        lines = [line for line in streams['stdout'].splitlines() if line.startswith(marker.encode())]
        assert len(lines) == 1, ('raw pass marker', record['name'])
        observed = record.get('observed', record.get('counters'))
        if observed is not None:
            parsed = {key.decode(): int(value) for key, value in
                      re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
            assert observed == parsed, ('raw counter agreement', record['name'])
    success, failure = {}, {}
    if '-o' in record['argv']:
        assert record['status'] == 'PASS'
        path = Path(record['argv'][record['argv'].index('-o') + 1]).resolve()
        assert path.is_relative_to(package) and path.suffix == '.vvp'
        value = digest(path)
        compiled[path] = value
        if 'image_sha256' in record:
            assert ref(package, record['image']) == path and record['image_sha256'] == value
        if 'artifact' in record:
            assert ref(package, record['artifact']['path']) == path
            assert record['artifact']['sha256'] == value
    if executable.stem.lower() == 'vvp':
        if record['status'] == 'PASS':
            assert streams['stderr'] == b''
        path = Path(record['argv'][1]).resolve()
        assert path in compiled and digest(path) == compiled[path]
        if 'execution_image_sha256' in record:
            assert record['execution_image_sha256'] == compiled[path]
        if 'execution_image' in record:
            assert ref(package, record['execution_image']['path']) == path
            assert record['execution_image']['sha256'] == compiled[path]
        (success if record['status'] == 'PASS' else failure)[path] = compiled[path]
    return success, failure


def concretize(item, stamp):
    return {key: [text.replace('<stamp>', stamp) for text in value] if key == 'argv'
            else value.replace('<stamp>', stamp) if isinstance(value, str) else value
            for key, value in item.items()}


def root_vector_counts(path, profile, summary):
    # A vector file describes one literal input pass. The actual composition
    # executes the same file in two boot epochs, then cancels and recovers one
    # further packet. Parse only retained records; no oracle is imported/run.
    lines = path.read_bytes().splitlines()
    assert lines and int(lines[0]) == len(lines) - 1
    kinds = []
    for line in lines[1:]:
        fields = line.split()
        assert len(fields) == 16
        kind = int(fields[0])
        assert kind in (0, 1, 2, 3)
        kinds.append(kind)
    counts = dict(vectors=len(kinds), vector_cfg=kinds.count(0),
        vector_packets=kinds.count(1) + kinds.count(3),
        vector_resets=kinds.count(2), faults=kinds.count(3))
    assert counts == profile['counts'] == summary['counts']
    for field in ('parameters', 'expected_runtime', 'vector_sha256', 'vector_bytes'):
        assert summary[field] == profile[field]
    runtime = profile['expected_runtime']
    if profile['parameters']['example']:
        assert counts == dict(vectors=50, vector_cfg=0, vector_packets=50, vector_resets=0, faults=0)
        assert {key: runtime[key] for key in counts} == {key: value * 2 for key, value in counts.items()}
        assert {key: runtime[key] for key in ('epochs', 'resets', 'cancelled', 'recovery', 'accepted', 'outputs')} == dict(
            epochs=2, resets=3, cancelled=1, recovery=1,
            accepted=2 * counts['vector_packets'] + 2, outputs=2 * counts['vector_packets'] + 1)
    else:
        assert {key: runtime[key] for key in counts} == counts


def vectors(receipt_path, receipt, simulations):
    for index, profile in enumerate(receipt.get('profiles', [])):
        if 'vector_sha256' in profile:
            path = receipt_path.parent / profile['vector']
            assert digest(path) == profile['vector_sha256']
            assert path.stat().st_size == profile['vector_bytes']
        for field in ('summary', 'preparation'):
            if field + '_sha256' in profile:
                path = receipt_path.parent / profile[field]
                assert digest(path) == profile[field + '_sha256']
                summary = load(path)
                if 'vector_sha256' in summary:
                    assert summary['vector_sha256'] == profile['vector_sha256']
        if index < len(simulations):
            observed = simulations[index].get('observed', {})
            # Explicit runtime contracts take precedence over file counts.
            # A has only counts and retains its original overlap comparison;
            # its dedicated holds/preoffers/reset transformations stay below.
            if 'expected_runtime' in profile:
                root_vector_counts(receipt_path.parent / profile['vector'], profile, summary)
                fields = ('expected_runtime',)
            elif 'expected_counters' in profile:
                fields = ('expected_counters',)
            else:
                fields = ('counts',)
            for field in fields:
                for key, value in profile.get(field, {}).items():
                    if field != 'counts' or key in observed:
                        assert observed[key] == value, ('profile counter', index, key)
        if 'preparation_sha256' in profile:
            assert summary['expected_counters'] == profile['expected_counters']
            assert summary['cases'] == profile['cases_detail']
            assert summary['preparation_calls'] == 1


def approval_field(path, pending_path, approved, pending, expected_hash):
    before, after = path.read_bytes(), pending_path.read_bytes()
    assert sha(after) == expected_hash
    a = ('"source_review": "' + approved + '"').encode()
    b = ('"source_review": "' + pending + '"').encode()
    assert before.count(a) == 1 and before.replace(a, b, 1) == after


def regular_run(package, delivery, tools, index):
    name = package.relative_to(ROOT).as_posix()
    relative, receipt_hash, plan_hash = RUN_PINS[name]
    rp = package / relative
    pp = ref(package, delivery['plan'])
    assert digest(rp) == receipt_hash == delivery['receipt_sha256']
    assert digest(pp) == plan_hash == delivery['plan_sha256']
    receipt, plan = load(rp), load(pp)
    assert receipt['status'] == 'PASS' and receipt['suite_complete'] is True
    assert receipt['automatic_retry'] is False and plan['automatic_retry'] is False and plan['fail_stop'] is True
    assert receipt['plan_sha256'] == digest(pp) and receipt['active_child'] is None
    assert ref(package, delivery['receipt']) == rp
    assert receipt.get('baseline', receipt.get('baseline_commit')) == BASE
    assert plan.get('baseline', plan.get('baseline_commit')) == BASE
    assert digest(rp.parent / 'plan.json') == digest(pp)
    for key in ('archive_complete', 'inputs_unchanged', 'archive_unchanged', 'vectors_unchanged',
                'tools_unchanged', 'images_unchanged', 'check_sequence_matches', 'exact_plan_executed'):
        if key in receipt:
            assert receipt[key] is True, (name, key)
    assert len(receipt['checks']) == 11 and len(receipt['preparations']) == (3 if index == 1 else 4)
    expected = plan.get('preparations', []) + plan['checks']
    actual = receipt['preparations'] + receipt['checks']
    assert len(actual) == len(expected)
    assert [item['name'] for item in actual] == [item['name'] for item in expected]
    assert set(receipt['source_sha256']) == set(receipt['archived_sources'])
    for source, value in receipt['source_sha256'].items():
        assert digest(ref(package, source)) == value == digest(ref(package, receipt['archived_sources'][source]))
    expected_sources = plan.get('source_sha256', plan.get('executable_sources'))
    if expected_sources is not None:
        assert expected_sources == receipt['source_sha256']
    all_tools = dict(tools)
    for field in ('tools', 'preparation_tools', 'cleanup_tools'):
        merge(all_tools, tool_map(receipt.get(field, {})))
    assert all_tools == tools
    if index == 0:
        assert tool_map(plan['tools']) == tools
    elif index == 1:
        assert plan['tool_sha256'] == {key: value['sha256'] for key, value in delivery['tools'].items()}
    compiled, success, failure = {}, {}, {}
    for record, item in zip(actual, expected):
        a, b = verify_child(package, rp, record, concretize(item, rp.parent.name), all_tools, compiled)
        merge(success, a); merge(failure, b)
        if Path(record['argv'][0]).stem.lower() == 'python':
            script = next(Path(arg).resolve() for arg in record['argv'][1:] if arg.endswith('.py'))
            assert script in {ref(package, path) for path in receipt['archived_sources'].values()}
    simulations = [item for item in receipt['checks'] if Path(item['argv'][0]).stem.lower() == 'vvp']
    assert len(simulations) == 4 and len(success) == 4 and not failure
    vectors(rp, receipt, simulations)
    if index == 0:
        approval_field(pp, package / 'planning/FINITE_PLAN.pending_before_run.json',
                       'NO_BLOCKER_A', 'PENDING_A', delivery['reviewed_pending_plan_sha256'])
        assert receipt['numerical_preparation_calls'] == receipt['numerical_preparation_attempts'] == 4
        assert receipt['planning_oracle_calls'] == 0
        assert image_map(package, delivery['successful_vvp_images']) == success
    elif index == 1:
        approval_field(pp, package / 'planning/FINITE_PLAN.reviewed_pending_before_execution.json',
                       'NO_BLOCKER_C_AND_ROOT', 'PENDING_C_AND_ROOT', delivery['reviewed_pending_plan_sha256'])
        assert receipt['oracle_completed_children'] == 3 and receipt['numerical_planning_calls'] == 0
        assert image_map(package, delivery['retained_compiled_image_sha256']) == success
        for simulation, profile in zip(simulations[:3], receipt['profiles']):
            counts, observed = profile['counts'], simulation['observed']
            assert observed['holds'] == 6 * counts['commands']
            assert observed['preoffers'] == counts['expected_preoffers']
            assert observed['future_gets'] == counts['future_gets'] >= 180
            assert observed['resets'] == counts['live_resets'] + 1 == 6
        for key, value in plan['example_expected'].items():
            assert simulations[3]['observed'][key] == value
        assert simulations[3]['observed']['holds'] >= plan['example_minimum_holds']
    else:
        verify_b_approval(package, receipt, plan, pp, rp)
        assert receipt['preparation_attempts'] == receipt['preparation_completed_calls'] == receipt['numerical_preparation_calls'] == 4
        assert receipt['oracle_imports'] == plan['runner_oracle_imports'] == plan['planning_oracle_calls'] == 0
        assert image_map(package, receipt['compiled_image_sha256']) == success
        assert image_map(package, {row['path']: row['sha256'] for row in delivery['compiled_executed_images']}) == success
        for profile, simulation in zip(receipt['profiles'], simulations):
            observed = simulation['observed']
            expected_counts = dict(profile['expected_counters'], N=profile['samples'], F=profile['frac'], T=profile['tag'], EX=profile['example'])
            assert all(observed[key] == value for key, value in expected_counts.items())
            assert observed['holds'] > 0 and observed['blocked'] > 0 and observed['done_holds'] > 0
            assert bool(observed['pretrigger']) == bool(profile['example'])
    return dict(records=receipt['checks'], preparations=receipt['preparations'], success=success,
                failure=failure, receipt_paths=[rp], prep_count=len(receipt['preparations']))


def verify_b_approval(package, receipt, plan, pp, rp):
    seal_path = package / 'SOURCE_SEAL.json'
    assert digest(seal_path) == B_SEAL_SHA == receipt['seal_sha256']
    assert digest(rp.parent / 'source_seal.json') == B_SEAL_SHA
    seal = load(seal_path)
    checked_map(package, seal['sha256'])
    sealed_tools = tool_map(seal['tools'])
    subtools = {}
    for field in ('hdl_tools', 'preparation_tools', 'cleanup_tools'):
        merge(subtools, tool_map(seal[field]))
    assert subtools == sealed_tools and len(sealed_tools) == 4
    assert receipt['source_sha256'] == seal['sha256']
    assert plan['source_review'] == 'NO_BLOCKER_ROOT'
    transition_path = package / 'review_history/ROOT_REVIEW_TRANSITION.json'
    assert digest(transition_path) == '483513d9c2eed486d6deb680a9288dc13023fc991cfe3791199f2c365021f88c'
    # The saved transition is additionally pinned as formal bytes; an exact
    # byte reversal permits only the single approved source_review field.
    transition = load(transition_path)
    pending_path = package / 'review_history/PRECHECK_PLAN.json.before_root_approval.txt'
    assert digest(pending_path) == transition['before_plan_sha256']
    assert transition['after_plan_sha256'] == digest(pp) and transition['after_seal_sha256'] == B_SEAL_SHA
    approval_field(pp, pending_path, 'NO_BLOCKER_ROOT', 'PENDING_ROOT', transition['before_plan_sha256'])
    review_path = package / 'qualification/ROOT_SOURCE_REVIEW.json'
    assert digest(review_path) == transition['review_record_sha256'] == 'ce15e692499ff040011f19ed805a219730ad94dc650c8104435e246834c22870'
    review = load(review_path)
    assert review['status'] == 'NO_BLOCKER_ROOT_SOURCE_ONLY' and review['complete_source_review'] is True
    assert review['pending_plan_sha256'] == digest(pending_path)
    assert review['pending_seal_sha256'] == transition['before_seal_sha256']
    assert load(package / 'EXECUTION_LOCK.json')['reviewed_seal_sha256'] == B_SEAL_SHA


def c_expected(package, plan, old_run):
    suite = ROOT / 'tools/oss-cad-suite/oss-cad-suite/bin'
    archive = old_run / 'source/cores/image_processing/causal_palette_diffusion'
    tool = str(suite / 'iverilog.exe')
    result = [dict(name='prepare_vectors', argv=['C:/Program Files/Python312/python.exe',
        '-I', '-B', str(archive / 'prepare_vectors.py'), str(old_run / 'vectors')], cwd=str(archive),
        marker='B43_C_PREP_PASS profiles=4 oracle_imports=1 oracle_preparations=1')]
    result += [dict(name=name, argv=[tool, '-g2012', '-Wall', '-tnull', '-s', top, *params, '-f', filelist], cwd=str(archive))
        for name, top, params, filelist in [
            ('lint_core', 'causal_palette_diffusion', [], 'files.f'),
            ('lint_core_max', 'causal_palette_diffusion', ['-Pcausal_palette_diffusion.WIDTH=4096', '-Pcausal_palette_diffusion.HEIGHT=4096', '-Pcausal_palette_diffusion.BITS=12', '-Pcausal_palette_diffusion.TAG_W=32'], 'files.f'),
            ('lint_actual_max', 'rgb_palette_diffusion', ['-Prgb_palette_diffusion.WIDTH=4096', '-Prgb_palette_diffusion.HEIGHT=4096', '-Prgb_palette_diffusion.TAG_W=32'], 'example/files.f')]]
    for profile in plan['profiles']:
        image = package / '.build' / old_run.name / (profile['name'] + '.vvp')
        arguments = [tool, '-g2012', '-Wall', '-s', 'tb_causal_palette',
            *[f'-Ptb_causal_palette.{key}={profile[field]}' for key, field in [('W','w'),('H','h'),('B','b'),('T','t'),('WRAP','wrap')]],
            '-o', str(image), '-f', 'example/files.f' if profile['wrap'] else 'files.f', 'sim/tb_causal_palette.sv']
        result.append(dict(name='compile_' + profile['name'], argv=arguments, cwd=str(archive)))
        result.append(dict(name='sim_' + profile['name'], argv=[str(suite / 'vvp.exe'), str(image)],
            cwd=str(old_run / 'vectors' / profile['name']), marker='B43_C_PASS'))
    assert [item['name'] for item in result[1:]] == plan['expected_hdl_children']
    return result


def causal_run(package, delivery, tools):
    old_path = package / 'reports/20261106T0933574171958Z/results.json'
    new_path = ref(package, delivery['receipt'])
    assert digest(old_path) == '9ae774ad19e3a6f3471f83824d2c0d4c865559a88ce1321e95ab5d725c537a0f'
    assert digest(new_path) == delivery['receipt_sha256'] == 'ebfd1104aa132b575215e0847e48532b2be546fad5217aa041b2a4dc76c7a2d6'
    old, new = load(old_path), load(new_path)
    qualification = load(ref(package, delivery['qualification']))
    for field in ('source_archive', 'current_inputs', 'vectors', 'raw_logs'):
        checked_map(package, qualification[field])
    assert qualification['counters'] == delivery['counters']
    assert digest(package / 'closeout.ps1') == delivery['closeout_source_sha256']
    current_status = package / 'STATUS.json'
    assert digest(current_status) == 'b69a956219c6dd060188a9d48c27247dac212b0f393cea3878f162d9c79f450a'
    state = load(current_status)
    assert state['delivery_sha256'] == digest(package / 'B43_DELIVERY.json')
    assert state['qualification_sha256'] == delivery['qualification_sha256']
    extras = {
        'manifest.json': 'eda1090df298b7bda695263e5ecc9997d31b2347eb0f9245975b728e42b8f1f1',
        'STATUS.md': '88014a17ad72b50af9e63852203ff7faf5b2c232e2902646cecaaa1bb6842662',
        # This is an earlier runner candidate, retained independently; it is
        # deliberately not treated as a byte reversal of the final repair plan.
        'repair01/REPAIR01_PLAN.pending_before_review_proof_gate.json':
          '72d53d38d6adf86eaa327f05e5913f16b31f00f98f8eeb5af18f247010ff3769'}
    checked_map(package, extras)
    pp = package / 'PRECHECK_PLAN.json'
    assert digest(pp) == delivery['original_plan_sha256'] == '2f61e8f4af552c58eeb9896fc9859f99eaef7bd279b47d269722cd50c8061f20'
    original_plan = load(pp)
    limits(original_plan)
    assert original_plan['fail_stop'] is True and original_plan['automatic_retry'] is False
    assert original_plan['planning_oracle_imports'] == 0
    assert digest(old_path.parent / 'source' / package.relative_to(ROOT) / 'PRECHECK_PLAN.json') == digest(pp)
    seal_path = package / 'SOURCE_SEAL.json'
    assert digest(seal_path) == old['source_seal_sha256'] == '8fb36daa5c6e55355e4166cde1cb77fe96d0a9ce15082b19809f695a27c6b607'
    seal = load(seal_path)
    assert len(seal['files']) == 16
    for item in seal['files']:
        assert digest(ROOT / item['path']) == item['sha256']
        assert digest(old_path.parent / 'source' / item['path']) == item['sha256']
    pp = ref(package, delivery['plan'])
    assert digest(pp) == delivery['plan_sha256'] == '2f6b1c495c3ca0a99f3b6caff8184a4f5556da5c4e8cd25bdbd1e7dcaecc5d7e'
    repair_plan = load(pp)
    assert (len(repair_plan['frozen_inputs']), len(repair_plan['tools'])) == (77, 10)
    assert repair_plan['original_result_sha256'] == digest(old_path)
    assert repair_plan['oracle_imports'] == repair_plan['oracle_preparations'] == repair_plan['preparation_children'] == 0
    for item in repair_plan['frozen_inputs']:
        assert digest(ROOT / item['path']) == item['sha256']
    assert len(new['archived_inputs']) == 76
    for item in new['archived_inputs']:
        assert digest(ROOT / item['path']) == item['sha256'] == digest(new_path.parent / item['archive'])
    assert len(tools) == 10 and tool_map(repair_plan['tools']) == tools
    proof_path = package / 'repair01/REVIEW_CURRENT.json'
    assert digest(proof_path) == new['review_sha256'] == delivery['review_proof_sha256'] == '19bd4ef776d04297d917014b0e163c6c82137b165884a97aeb6d4193b1b5b255'
    proof = load(proof_path)
    assert proof['status'] == 'NO_BLOCKER_B_AND_ROOT' and proof['plan_sha256'] == digest(pp)
    assert load(package / 'repair01/REVIEW_PENDING.json')['status'] == 'SOURCE_REVIEW_PENDING_NOT_EXECUTED'
    assert digest(new_path.parent / 'REVIEW_CURRENT.json') == digest(proof_path)
    assert digest(new_path.parent / 'REPAIR01_PLAN.json') == digest(pp)
    initial = load(package / 'repair01/INITIAL_REVIEW.json')
    assert initial['verdict'] == 'NO_BLOCKER_B' and initial['source_seal_sha256'] == digest(seal_path)
    assert initial['plan_sha256'] == digest(package / 'PRECHECK_PLAN.json')
    assert initial['original_result_sha256'] == digest(old_path)
    assert new['status'] == 'PASS' and old['status'] == 'FAIL_STOP'
    assert new['active_child'] is None and old.get('active_child') is None
    assert new['failure'] is None and new['original_failure_preserved'] is True
    assert new['original_result_sha256'] == digest(old_path) and new['hdl_children'] == 7
    assert old['oracle_imports'] == old['oracle_preparations'] == old['preparation_children'] == 1
    assert new['oracle_imports'] == new['oracle_preparations'] == new['preparation_children'] == 0
    assert not old['automatic_retry'] and not new['automatic_retry'] and not repair_plan['automatic_retry']
    assert repair_plan['fail_stop'] is True
    compiled, success, failure = {}, {}, {}
    expected = c_expected(package, original_plan, old_path.parent)
    assert len(old['children']) == 6 and len(new['children']) == 7
    for record, item in zip(old['children'], expected):
        a, b = verify_child(package, old_path, record, item, tools, compiled, allow_loader=True)
        merge(success, a); merge(failure, b)
    assert [item['name'] for item in old['children']] == [item['name'] for item in expected[:6]]
    assert [item['status'] for item in old['children']] == ['PASS'] * 5 + ['FAIL']
    assert [item['name'] for item in new['children']] == [item['name'] for item in repair_plan['checks']]
    assert [item['name'] for item in new['children']] == ['sim_core_1x1_d8', 'compile_core_7x5_d10', 'sim_core_7x5_d10', 'compile_core_17x9_d12', 'sim_core_17x9_d12', 'compile_actual_16x7_d8', 'sim_actual_16x7_d8']
    assert all(item['status'] == 'PASS' for item in new['children'])
    for record, item in zip(new['children'], repair_plan['checks']):
        item = dict(item, marker='B43_C_PASS' if item['kind'] == 'simulation' else None)
        a, b = verify_child(package, new_path, record, item, tools, compiled)
        merge(success, a); merge(failure, b)
        if item['kind'] == 'simulation':
            observed = record['counters']
            assert observed['outputs'] == item['expected_outputs'] and observed['early'] == item['expected_early']
            assert observed['holds'] > 0
    assert len(success) == 4 and len(failure) == 1 and len(success.keys() & failure.keys()) == 1
    assert image_map(package, delivery['verified_compiled_image_sha256']) == success
    assert image_map(package, delivery['failed_vvps_to_retain']) == failure
    assert ref(package, delivery['shared_failure_success_image']) in success.keys() & failure.keys()
    for stream_record in old['children'] + new['children']:
        child_path = (old_path.parent if stream_record in old['children'] else new_path.parent) / (stream_record['name'] + '.json')
        assert load(child_path) == stream_record
    preparation = load(old_path.parent / 'vectors/receipt.json')
    assert preparation['oracle_imports'] == preparation['oracle_preparations'] == 1
    assert len(preparation['files']) == len(old['vectors']) == 12
    for item in preparation['files']:
        path = old_path.parent / 'vectors' / item['path']
        assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
    assert len(delivery['raw_logs']) == 26 and len(delivery['vectors']) == 12
    counters = {key: sum(record['counters'][key] for record in new['children'] if record['kind'] == 'simulation') for key in delivery['counters']}
    assert counters == delivery['counters'] == dict(frames=76, faults=12, invalids=8, resets=36, outputs=6166, early=66, holds=2869, gaps=4306)
    assert load(package / 'EXECUTION_LOCK.json')['run_id'] == old_path.parent.name
    assert load(package / 'repair01/EXECUTION_LOCK.json')['plan_sha256'] == digest(pp)
    covered = {ref(package, name) for field in ('source_archive', 'raw_logs', 'vectors', 'current_source_sha256') for name in delivery[field]}
    covered.update(ROOT / item['path'] for item in repair_plan['frozen_inputs'])
    covered.update(package / name for name in extras)
    covered.update([package / 'B43_DELIVERY.json', package / 'QUALIFICATION.json', current_status,
        package / 'closeout.ps1', pp, proof_path, package / 'repair01/EXECUTION_LOCK.json', new_path,
        new_path.parent / 'REPAIR01_PLAN.json', new_path.parent / 'REVIEW_CURRENT.json'])
    covered.update(new_path.parent / (record['name'] + '.json') for record in new['children'])
    return dict(records=old['children'][1:] + new['children'], preparations=old['children'][:1],
                success=success, failure=failure, receipt_paths=[old_path, new_path], prep_count=1,
                covered={path.resolve() for path in covered if path.resolve().is_relative_to(package)
                    and not set(path.resolve().relative_to(package).parts) & {'.build', '.work', '__pycache__'}})


def source_list(package, name):
    sources, headers, include_dirs = [], [], []
    for line in (package / name).read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if not line:
            continue
        if line.startswith('+incdir+'):
            for item in line[8:].split('+'):
                path = (package / item).resolve()
                assert path.is_dir() and path.is_relative_to(ROOT)
                include_dirs.append(path)
            continue
        assert not line.startswith('-'), ('nested source list', name, line)
        path = (package / line).resolve()
        assert path.is_file() and path.is_relative_to(ROOT) and path.suffix in ('.v', '.sv')
        relative = path.relative_to(ROOT).as_posix()
        assert relative not in sources
        sources.append(relative)
        for match in re.findall(rb'`include\s+"([^"]+)"', path.read_bytes()):
            found = next((candidate.resolve() for candidate in
                [path.parent / match.decode(), *[directory / match.decode() for directory in include_dirs]] if candidate.is_file()), None)
            assert found and found.is_relative_to(ROOT)
            headers.append(found.relative_to(ROOT).as_posix())
    return sources, headers


def baseline_bytes(paths):
    raw = git('cat-file', '--batch', data=''.join(BASE + ':' + name + '\n' for name in paths).encode())
    result, offset = {}, 0
    for name in paths:
        end = raw.index(b'\n', offset)
        fields = raw[offset:end].split()
        assert len(fields) == 3 and fields[1] == b'blob'
        count = int(fields[2])
        result[name] = raw[end + 1:end + 1 + count]
        offset = end + count + 2
        assert digest(ROOT / name) == sha(result[name]), ('inherited canonical bytes', name)
    assert offset == len(raw)
    return result


def followup_inputs():
    assert digest(ROOT / ORIGINAL_SOURCE) == ORIGINAL_SOURCE_SHA
    assert digest(ROOT / ORIGINAL_GUARD) == ORIGINAL_GUARD_SHA
    assert digest(ROOT / ORIGINAL_FAILURE) == ORIGINAL_FAILURE_SHA
    original_guard, failure = load(ROOT / ORIGINAL_GUARD), load(ROOT / ORIGINAL_FAILURE)
    assert original_guard['auditor_sha256'] == ORIGINAL_SOURCE_SHA and original_guard['automatic_retry'] is False
    assert failure['status'] == 'FAIL_STOP' and failure['exit_code'] == 1 and failure['execution_attempts'] == 1
    assert failure['auditor_sha256'] == ORIGINAL_SOURCE_SHA and failure['original_guard_sha256'] == ORIGINAL_GUARD_SHA
    assert failure['raw_stdio_files_captured'] is False and failure['snapshot_outputs_written'] is False
    assert failure['new_model_or_hdl_runs'] == 0 and failure['automatic_retry'] is False
    plan = load(ROOT / PLAN)
    assert plan['schema'] == 'anscore-b43-independent-static-followup01-plan-v1'
    assert plan['status'] == 'SOURCE_REVIEW_REQUIRED_NOT_EXECUTED'
    assert plan['bindings'] == dict(baseline_commit=BASE,
        original_auditor=dict(path=ORIGINAL_SOURCE, sha256=ORIGINAL_SOURCE_SHA),
        original_guard=dict(path=ORIGINAL_GUARD, sha256=ORIGINAL_GUARD_SHA),
        original_failure=dict(path=ORIGINAL_FAILURE, sha256=ORIGINAL_FAILURE_SHA),
        followup_auditor=dict(path=FOLLOWUP_SOURCE, sha256=digest(Path(__file__))),
        bridges={path + '/B43_DELIVERY.json': value for path, _, _, _, value in PACKAGES})
    assert plan['execution'] == dict(argv=[str(Path('C:/Program Files/Python312/python.exe')),
        '-I', '-B', str(ROOT / FOLLOWUP_SOURCE)], cwd=str(ROOT), attempts=1, guard=GUARD,
        automatic_retry=False, fail_stop=True, git_subprocess_timeout_seconds=20)
    assert plan['scope'] == dict(project_imports=0, historical_auditor_imports_or_executions=0,
        model_imports_or_executions=0, numerical_preparations=0, hdl_children=0,
        synthesis=0, pnr=0, sta=0, board=0, ppa=0, inherited_regressions=0,
        cleanup=0, staging=0, commits=0, original_files_changed=0)
    assert plan['outputs'] == list(OUTPUTS)
    assert plan['expected_ip_statistics'] == dict(formal_files=441, packages=172,
        source_files=378, module_declarations=380, unresolved_module_collisions=0,
        total_hdl_children=45, passed_hdl_children=44, failed_hdl_children=1,
        timeout_hdl_children=0, successful_simulations=16, numerical_preparations=12,
        unique_physical_images=16, shared_successful_failed_images=1)
    patch = plan['reversible_patch']
    assert patch['format'] == 'ORDERED_UNIQUE_TEXT_REPLACEMENTS_UTF8_LF_V1'
    assert patch['original_sha256'] == ORIGINAL_SOURCE_SHA and patch['followup_sha256'] == digest(Path(__file__))
    original_raw, followup_raw = (ROOT / ORIGINAL_SOURCE).read_bytes(), Path(__file__).read_bytes()
    reconstructed = original_raw.decode('utf-8')
    assert len(patch['replacements']) == 4
    for replacement in patch['replacements']:
        assert reconstructed.count(replacement['before']) == 1
        reconstructed = reconstructed.replace(replacement['before'], replacement['after'], 1)
    assert reconstructed.encode('utf-8') == followup_raw
    for replacement in reversed(patch['replacements']):
        assert reconstructed.count(replacement['after']) == 1
        reconstructed = reconstructed.replace(replacement['after'], replacement['before'], 1)
    assert reconstructed.encode('utf-8') == original_raw
    assert plan['review_gate'] == 'Separate complete NO_BLOCKER_A and NO_BLOCKER_ROOT source reviews plus an explicit new root unique execution gate are required; this plan alone authorizes no execution.'
    return plan


def main():
    assert all('PENDING' not in item for item in (B_BRIDGE_SHA, B_RECEIPT, B_RECEIPT_SHA)), 'B final evidence not bound'
    assert all(not (ROOT / path).exists() for path in OUTPUTS), 'B43 output already exists'
    plan_sha256 = digest(ROOT / PLAN)
    with (ROOT / GUARD).open('x', encoding='utf-8', newline='\n') as stream:
        stream.write(json.dumps(dict(schema='anscore-b43-independent-static-followup01-once-v1', status='ATTEMPT_STARTED',
            baseline_commit=BASE, auditor_sha256=digest(Path(__file__)), plan=PLAN, plan_sha256=plan_sha256,
            original_failure_sha256=ORIGINAL_FAILURE_SHA, automatic_retry=False), indent=2) + '\n')
    plan = followup_inputs()
    assert git('rev-parse', 'HEAD').decode().strip() == BASE
    parent_raw, structure_raw = git('show', BASE + ':' + PARENT), git('show', BASE + ':' + STRUCTURE)
    assert sha(parent_raw) == digest(ROOT / PARENT) == PARENT_SHA
    assert sha(structure_raw) == digest(ROOT / STRUCTURE) == STRUCTURE_SHA
    parent, previous = json.loads(parent_raw), json.loads(structure_raw)
    assert len(parent['packages']) == 168 and previous['source_files'] == 368 and previous['module_declarations'] == 370
    # Preserve all parent objects unchanged; verify 15370 exact worktree maps
    # plus only the four explicitly fixed LF/CRLF JSON relations above.
    normalizations, inherited_mapping_count = inherited_files(parent['packages'])
    snapshot = copy.deepcopy(parent)
    inherited = set(previous['canonical_source_paths'])
    assert len(inherited) == 368
    sources, production, additions = set(inherited), set(), {}
    summaries, package_inventories = [], {}
    all_success, all_failed = {}, {}
    total_pass = total_fail = total_preparations = total_simulations = 0
    for index, (relative, top, example, risk, bridge_hash) in enumerate(PACKAGES):
        package = ROOT / relative
        delivery, tools = bridge(package, bridge_hash)
        files = inventory(package)
        assert len(files) == (80, 77, 99, 185)[index]
        assert len(delivery['source_mapping']) == (17, 17, 21, 20)[index]
        attributes(package, files, index == 1)
        checked = causal_run(package, delivery, tools) if index == 3 else regular_run(package, delivery, tools, index)
        if index < 3:
            field = ('package_sha256', 'formal_files_sha256', 'formal_payload_sha256')[index]
            formal_paths = {ref(package, name) for name in delivery[field]}
            assert formal_paths | {package / 'B43_DELIVERY.json'} == {package / name for name in files}
        else:
            assert checked['covered'] == {package / name for name in files}
        records = checked['records']
        passes = sum(record['status'] == 'PASS' for record in records)
        failures = sum(record['status'] != 'PASS' for record in records)
        successful_simulations = sum(Path(record['argv'][0]).stem.lower() == 'vvp' and record['status'] == 'PASS' for record in records)
        assert (passes, failures, successful_simulations, checked['prep_count']) == (11, int(index == 3), 4, (4, 3, 4, 1)[index])
        lists, headers = {}, set()
        for name in ('files.f', 'example/files.f'):
            resolved, includes = source_list(package, name)
            lists[name] = resolved
            sources.update(resolved); production.update(resolved); headers.update(includes)
        assert not headers
        for name in set(sum(lists.values(), [])) - inherited:
            if name.startswith(relative + '/'):
                continue
            assert name in BASE_ADDITIONS, ('unbound new canonical base', name)
            oid, value = BASE_ADDITIONS[name]
            entry = git('ls-tree', BASE, '--', name).decode().strip()
            assert entry == '100644 blob ' + oid + '\t' + name
            assert git('rev-parse', BASE + ':' + name).decode().strip() == oid
            assert git('hash-object', '--no-filters', str(ROOT / name)).decode().strip() == oid
            assert git('hash-object', '--path=' + name, str(ROOT / name)).decode().strip() == oid
            assert digest(ROOT / name) == value
            additions[name] = dict(sha256=value, baseline_blob_oid=oid, baseline_git_mode='100644', baseline_commit=BASE,
                classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')
        merge(all_success, checked['success']); merge(all_failed, checked['failure'])
        total_pass += passes; total_fail += failures
        total_preparations += checked['prep_count']; total_simulations += successful_simulations
        snapshot['packages'].append(dict(path=relative, top=top, baseline_commit=BASE,
            evidence='B43_DELIVERY.json', evidence_kind='explicit_finite_checks_with_retained_history',
            hardware_status='HW_UNVERIFIED', architecture_risk=risk,
            additional_source_lists=['example/files.f'], examples=[dict(file='example/' + example + '.sv', top=example)], sha256=files))
        summaries.append(dict(path=relative, files=len(files), effective_checks=passes,
            retained_failures=failures, retained_timeouts=0, total_hdl_children=len(records),
            successful_simulations=successful_simulations, numerical_preparations=checked['prep_count'],
            literal_preparation_children=0, successful_unique_images=len(checked['success']),
            failed_or_timeout_unique_images=len(checked['failure']),
            shared_successful_failed_images=len(checked['success'].keys() & checked['failure'].keys()),
            architecture_risk=risk, source_lists=lists, include_files=[],
            evidence_runs=[dict(path=path.relative_to(ROOT).as_posix(), sha256=digest(path), status=load(path)['status']) for path in checked['receipt_paths']]))
        package_inventories[relative] = files
    assert snapshot['packages'][:168] == parent['packages'] and len(snapshot['packages']) == 172
    assert set(additions) == set(BASE_ADDITIONS) and len(sources) == 378
    contents = baseline_bytes(sorted(inherited | set(additions)))
    modules = {}
    for name in sorted(sources):
        raw = contents[name] if name in contents else (ROOT / name).read_bytes()
        code = re.sub(rb'/\*.*?\*/|//[^\n]*', b'', raw, flags=re.S)
        for module in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)', code):
            modules.setdefault(module.decode(), []).append(name)
    collisions = {name: paths for name, paths in modules.items() if len(paths) > 1}
    assert not collisions and sum(map(len, modules.values())) == 380
    assert (total_pass, total_fail, total_simulations, total_preparations) == (44, 1, 16, 12)
    assert sum(map(len, package_inventories.values())) == 441
    assert (len(all_success), len(all_failed), len(all_success.keys() & all_failed.keys()), len(all_success | all_failed)) == (16, 1, 1, 16)
    for relative, expected in package_inventories.items():
        assert inventory(ROOT / relative) == expected, ('package changed mid-audit', relative)
    assert digest(ROOT / ORIGINAL_SOURCE) == ORIGINAL_SOURCE_SHA
    assert digest(ROOT / ORIGINAL_GUARD) == ORIGINAL_GUARD_SHA
    assert digest(ROOT / ORIGINAL_FAILURE) == ORIGINAL_FAILURE_SHA
    assert digest(ROOT / PLAN) == plan_sha256 and digest(Path(__file__)) == plan['bindings']['followup_auditor']['sha256']
    current_guard = load(ROOT / GUARD)
    assert current_guard['auditor_sha256'] == digest(Path(__file__)) and current_guard['plan_sha256'] == plan_sha256
    static_audit_history = [
        dict(path=ORIGINAL_FAILURE, sha256=ORIGINAL_FAILURE_SHA, status='FAIL_STOP',
            auditor=ORIGINAL_SOURCE, auditor_sha256=ORIGINAL_SOURCE_SHA,
            guard=ORIGINAL_GUARD, guard_sha256=ORIGINAL_GUARD_SHA,
            raw_stdio_files_captured=False,
            reason='Original static assertion mixed one-file counts=50 with two-epoch runtime counts=100; exit1 retained, no snapshot written and no IP evidence rerun.'),
        dict(path=FOLLOWUP_SOURCE, sha256=digest(Path(__file__)), status='PASS',
            guard=GUARD, guard_sha256=digest(ROOT / GUARD), plan=PLAN, plan_sha256=plan_sha256,
            reason='Independent complete static audit binds literal file counts separately from explicit runtime contracts and preserves the original fail-stop evidence.')]
    snapshot.update(date='2026-11-06', baseline_commit=BASE, batch_baseline_commit=BASE,
        previous_snapshot=PARENT, source_freeze='B43 cumulative172 packages: IPv4 LPM/TTL header forwarding, inclusive-watermark event merge, ADC code-density DNL/INL and causal runtime-palette diffusion. C loader failure retained with identical shared image after environment-only recovery. No synthesis/PnR/STA/board/PPA/inherited execution.',
        parent_snapshot=dict(path=PARENT, sha256=sha(parent_raw), worktree_sha256=digest(ROOT / PARENT), hash_kind='committed_git_blob', commit=BASE),
        batch_canonical_base_sources=additions, batch_support_file_additions={}, baseline_text_normalizations=normalizations,
        static_audit_history=static_audit_history)
    audit = dict(schema='anscore-b43-static-audit-followup01-v1', status='PASS', baseline_commit=BASE, packages=172,
        parent_snapshot_sha256=sha(parent_raw), inherited_package_objects_exact=168, new_packages=summaries,
        inherited_formal_mappings=inherited_mapping_count, inherited_formal_byte_exact_mappings=inherited_mapping_count - len(normalizations),
        baseline_text_normalizations=normalizations, static_audit_history=static_audit_history,
        static_audit_executions=2, static_audit_failed_executions=1, static_audit_passed_executions=1,
        new_package_files=sum(map(len, package_inventories.values())), effective_finite_checks=total_pass,
        historical_failed_children=total_fail, historical_timeout_children=0, total_hdl_children=total_pass + total_fail,
        successful_finite_simulations=total_simulations, numerical_oracle_preparations=total_preparations,
        literal_preparation_children=0, preparation_child_executions=total_preparations,
        successful_unique_images=len(all_success), failed_or_timeout_unique_images=len(all_failed),
        maximum_subpixel_row_status=previous['maximum_subpixel_row_status'],
        shared_successful_failed_images=len(all_success.keys() & all_failed.keys()), total_unique_images=len(all_success | all_failed),
        source_files=len(sources), module_declarations=sum(map(len, modules.values())), canonical_source_paths=sorted(sources),
        new_canonical_base_sources=sorted(additions), new_support_headers={}, unresolved_module_collisions=collisions,
        execution_guard=GUARD, scope='Fresh static byte/source/archive/plan/argv/raw/vector/tool/runtime/image/review audit; inherited package objects and canonical bytes retained. No model/runner/historical-auditor import or HDL execution.',
        combined_compile='NOT_RUN', inherited_checker='NOT_RUN', synthesis='NOT_RUN', pnr='NOT_RUN', sta='NOT_RUN', board='NOT_RUN', ppa='NOT_RUN')
    # No new snapshot output exists until every assertion above has completed.
    payloads = [(json.dumps(value, indent=2) + '\n').encode() for value in (snapshot, audit)]
    for name, payload in zip(OUTPUTS, payloads):
        with (ROOT / name).open('xb') as stream:
            stream.write(payload)
    print(json.dumps({key: audit[key] for key in ('status', 'packages', 'new_package_files',
        'effective_finite_checks', 'historical_failed_children', 'successful_finite_simulations', 'source_files', 'module_declarations')}))


if __name__ == '__main__':
    main()
