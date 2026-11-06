"""SPDX-License-Identifier: Apache-2.0. B42 static evidence audit; no HDL/model imports.

Execution requires the independent C/root source gate. An exclusive attempt marker
prevents automatic retries, including after an assertion failure. Only the two
new snapshots are written after every source/evidence assertion has passed.
"""
from pathlib import Path
import copy, hashlib, json, re, subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = '2e7a6fb51f32e525c1026c28d1f2f45e36545ebc'
PARENT = 'docs/snapshots/source_20261106_b41.json'
OLD = 'docs/snapshots/source_20261106_b41_structure.json'
OUTPUTS = ('docs/snapshots/source_20261106_b42.json',
           'docs/snapshots/source_20261106_b42_structure.json')
GUARD = '.git/anscore-b42-audit-once.json'
PARENT_SHA = '7756d45a4944f2c56d85a0a885ee36f30a1a088d50c96a930e0672203310a970'
OLD_SHA = 'e9ca0d77d16ce9a531fd491cea414482362040c78f5424d9f2904c533661df77'
NEW = [
 ('cores/storage/position_limit_reservations', 'position_limit_reservations',
  'position_gated_ioc8', 'MEDIUM',
  '7e462153a48eecd5b2888d1c5a7ea546c5586894b032b7a332013d5c1c8842c0'),
 ('cores/signal_processing/spectral_harmonic_quality', 'spectral_harmonic_quality',
  'iq_spectral_harmonic_quality', 'MEDIUM',
  '891b2f9730a85b68f2c172253e3079e3c59c1a266575f5d1166c52b6eff49d7a'),
 ('cores/image_processing/raw_optical_black_rows', 'raw_optical_black_rows',
  'raw_ob_black_frontend', 'MEDIUM',
  '7651fe4b0749a50302e1ca17ea79e3ca3decbff5d36a7cc33e42b23599f16560'),
 ('cores/acceleration/int4_subpixel_upsample2x', 'int4_subpixel_upsample2x',
  'rgb_subpixel8', 'HIGH at maximum row; NOT_QUALIFIED_TIMEOUT',
  '7b2ac274cf99fc2a6f27719f76b3d69f0bda880d92d1f61015c894f047bda520')]
# Explicit receipt/plan bindings include every original failure and both timeouts.
RUN_HASHES = {
 '20261106T082558407905Z': (
  '557c45f25ad0f4359db17810ee392cf6d21a470131bf4527e98576005db99756',
  '22ca567b6d7a51e9c2e1b8888621b67e24f05ad9c9d73456ef1d0bafb38a98ae'),
 'repair01_20261106T085121113067Z': (
  'dfdcc691b76014b7ccb4f809f6a394f1385af5ccadddad4164d6b7f8d8db44c7',
  '02b69b285fafb08fd145d0a0cde2563783fa1dc2a87a9e06029633e4efe53c18'),
 '20261106T082939_672565Z': (
  '3ae952ad90f4e60b7d97fc0e174dfea22487edb58f122d357727bb3f70c616b1',
  'af4921ad1096a87cc2448d90265972dc0c056e24dda12fc4e121e4dc0260a6a2'),
 '20261106T082210011873Z': (
  '98b9ab49f44bd1c4c1b761f6ed4dcb20179f2ab7cb1cb0126b99df18bd0ee2e5',
  'b79137c81b68204ea74b001f2496fda4e2f28269fb445f08f4d7b0e4c76ae3b6'),
 '20261106T082646812505Z': (
  'ff6f8273e7064903d97123a7f1f82dd8e5f9b347aeb3eec7003c9d8666a9b71d',
  '4eb7aea973fdff40de962f49c1765691a21b22fc6d553d3b451ed9b34b080c61'),
 'repair01_20261106T084311136117Z': (
  '15558f37568436eede9ec4fd49405e10ff1dbefff3532c8818ea58afd0487e38',
  'c5bb5d835ed3ff4ecdccf0b2a231ab31ec0cd61f0e9e0156274b1ca22a465913')}
EXPECTED = [(12, 1, 0, 4, 3, 0), (10, 0, 0, 4, 4, 0),
            (11, 0, 0, 4, 1, 0), (10, 0, 2, 3, 3, 1)]
BASE_ADDITIONS = {
 'cores/image_processing/isp_stream/rtl/raw_black_level_stream.v': (
  'eb1db3604226a1e16a922d1f433a31fbfe5342b2',
  'd3b240cb7d36f0a9ff54c329e87791696be4e73120416e1ba5b76c0e52ddfc58'),
 'cores/signal_processing/dsp_isp_library/dsp/spectrum/rtl/peak_search.sv': (
  '8981be5b0caef121107cdc2327e0eaa382c0e13c',
  '0dfa5bf0bc39693da776742fb7fe00671bd74a6a41e055758dbcf62e0c4cd61c')}


def sha(b):
 return hashlib.sha256(b).hexdigest()


def digest(p):
 return sha(p.read_bytes())


def git(*args, inp=None):
 return subprocess.run(['git', *args], cwd=ROOT, input=inp,
  capture_output=True, check=True, timeout=20).stdout


def ref(p, name):
 return ROOT / name if name.replace('\\', '/').startswith('cores/') else p / name


def load(p):
 return json.loads(p.read_bytes())


def checked_map(p, mapping):
 for name, value in mapping.items():
  assert isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value), name
  assert digest(ref(p, name)) == value, (str(p), name)


def tools_map(mapping):
 result = {}
 for name, value in mapping.items():
  filename, h = (value['path'], value['sha256']) if isinstance(value, dict) else (name, value)
  q = Path(filename).resolve()
  assert digest(q) == h, ('tool', filename)
  assert q not in result or result[q] == h
  result[q] = h
 return result


def inventory(p):
 return {q.relative_to(p).as_posix(): digest(q) for q in sorted(p.rglob('*'))
  if q.is_file() and not set(q.relative_to(p).parts) & {'.build', '.work', '__pycache__'}}


def check_attributes(p, inv):
 assert (p / '.gitattributes').read_bytes() == b'* -text\n'
 for n in inv:
  if Path(n).name == '.gitattributes':
   assert (p / n).read_bytes() == b'* -text\n'
 names = [p.relative_to(ROOT).as_posix() + '/' + n for n in inv]
 attrs = git('check-attr', '-z', '--stdin', 'text', 'filter', 'working-tree-encoding',
             inp=('\0'.join(names) + '\0').encode()).split(b'\0')
 assert attrs.pop() == b'' and len(attrs) == len(names) * 9
 for i in range(0, len(attrs), 3):
  n, key, value = attrs[i:i + 3]
  assert value == (b'unset' if key == b'text' else b'unspecified'), (n, key, value)


def archived(p, rp, r, name):
 if name in r.get('archived_sources', {}):
  return ref(p, r['archived_sources'][name])
 assert name in r.get('exact_checked_copies', {}), ('missing checked copy', name)
 return rp.parent / r['exact_checked_copies'][name]


def approved_review_only(pp, approved, pending, expected_hash):
 b = pp.read_bytes()
 before, after = ('"source_review": "' + approved + '"').encode(), ('"source_review": "' + pending + '"').encode()
 assert b.count(before) == 1 and sha(b.replace(before, after, 1)) == expected_hash


def verify_child(rp, c, e, allowed_tools):
 assert c['name'] == e['name']
 assert c['argv'] == [a.replace('<stamp>', rp.parent.name) for a in e['argv']]
 assert c['cwd'] == e['cwd'].replace('<stamp>', rp.parent.name)
 assert Path(c['cwd']).resolve().is_relative_to(ROOT)
 assert Path(c['argv'][0]).resolve() in allowed_tools
 deadline = next(c[k] for k in ('timeout_seconds', 'execution_deadline_seconds', 'hard_seconds') if k in c)
 tree = c.get('tree_kill_seconds', c.get('tree_cleanup_seconds'))
 assert deadline == 20 and tree == 5 and c['drain_seconds'] == 2
 for key, expected in [('timeout_seconds', 20), ('execution_deadline_seconds', 20),
  ('hard_seconds', 20), ('tree_kill_seconds', 5), ('tree_cleanup_seconds', 5),
  ('drain_seconds', 2), ('cleanup_budget_seconds', 7)]:
  if key in e:
   assert e[key] == expected
  if key in c:
   assert c[key] == expected
 streams = {}
 for stream in ('stdout', 'stderr'):
  streams[stream] = (rp.parent / (c['name'] + '.' + stream + '.txt')).read_bytes()
  assert sha(streams[stream]) == c[stream + '_sha256']
 assert c['status'] in ('PASS', 'FAIL', 'TIMEOUT')
 marker = e.get('marker')
 lines = [x for x in streams['stdout'].splitlines() if marker and x.startswith(marker.encode())]
 if c['status'] == 'PASS':
  assert c['returncode'] == 0 and not c.get('cleanup')
  if marker:
   assert len(lines) == 1, ('missing/duplicate raw PASS marker', c['name'])
   observed = c.get('observed', c.get('counters'))
   if observed is not None:
    parsed = {k.decode(): int(v) for k, v in re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
    assert parsed == observed, ('raw counter mismatch', c['name'])
    for k, v in (e.get('expected_counters') or {}).items():
     assert observed[k] == v
 else:
  assert c['returncode'] != 0 and not lines
  if c['status'] == 'TIMEOUT':
   # Wall time includes cleanup. The execution limit is still exactly 20 s.
   assert 20 <= c['seconds'] <= 27
   assert c['cleanup'] and all(x['returncode'] == 0 for x in c['cleanup'])
  else:
   assert b'FATAL:' in streams['stdout'] + streams['stderr']
 return streams


def verify_receipt(p, desc):
 rp, pp = ref(p, desc['receipt']), ref(p, desc['plan'])
 assert (digest(rp), digest(pp)) == RUN_HASHES[rp.parent.name]
 assert digest(rp) == desc['receipt_sha256'] and digest(pp) == desc['plan_sha256']
 r, plan = load(rp), load(pp)
 assert r['status'] == desc['status'] and plan['fail_stop'] is True
 assert plan['automatic_retry'] is False and r['automatic_retry'] is False
 assert r['suite_complete'] is (r['status'] == 'PASS')
 assert r.get('plan_sha256', r['source_sha256'].get(pp.relative_to(p).as_posix())) == digest(pp)
 if (rp.parent / 'plan.json').exists():
  assert digest(rp.parent / 'plan.json') == digest(pp)
 for key in ('archive_complete', 'preparation_complete', 'sources_unchanged', 'archives_unchanged',
  'archive_unchanged', 'archived_sources_unchanged', 'vectors_unchanged', 'plan_unchanged',
  'tools_unchanged', 'images_unchanged', 'inputs_unchanged', 'check_sequence_matches', 'exact_plan_executed'):
  if key in r:
   assert r[key] is True, (rp.parent.name, key)
 records, prep = r.get('checks', r.get('records', [])), r.get('preparations', [])
 expected = [x for x in plan['checks'] if x.get('kind', 'HDL') == 'HDL']
 prep_expected = plan.get('preparations', []) + [x for x in plan['checks'] if x.get('kind', 'HDL') != 'HDL']
 assert records and [x['name'] for x in records] == [x['name'] for x in expected[:len(records)]]
 assert len(records) == len(expected), 'All six frozen runs ended on their last planned HDL child'
 if 'expected_checks' in plan:
  assert [x['name'] for x in records] == plan['expected_checks']
 assert [x['name'] for x in prep] == [x['name'] for x in prep_expected]
 assert all(c['status'] == 'PASS' for c in prep + records[:-1])
 assert records[-1]['status'] == r['status']
 all_tools = tools_map(r['tools'])
 all_tools.update(tools_map(r.get('preparation_tools', {})))
 assert {q.stem.lower() for q in all_tools} == ({'iverilog', 'vvp', 'python'} if prep else {'iverilog', 'vvp'})
 for c, e in zip(prep, prep_expected):
  verify_child(rp, c, e, all_tools)
 for c, e in zip(records, expected):
  assert Path(c['argv'][0]).stem.lower() in ('iverilog', 'vvp')
  verify_child(rp, c, e, all_tools)
 archive_names = set(r.get('archived_sources', {})) | set(r.get('exact_checked_copies', {}))
 assert archive_names == set(r['source_sha256'])
 differences = []
 for n, h in r['source_sha256'].items():
  assert digest(archived(p, rp, r, n)) == h, ('archive', rp.parent.name, n)
  if digest(ref(p, n)) != h:
   differences.append(n)
 assert sorted(differences) == sorted(desc.get('source_exceptions', [])), ('source exceptions', differences)
 for n, h in plan.get('source_sha256', {}).items():
  assert r['source_sha256'][n] == h
 for obj in (r, plan):
  checked_map(p, obj.get('parent_evidence', {}))
 for i, profile in enumerate(r.get('profiles', [])):
  if 'vector_sha256' in profile:
   vector = rp.parent / profile['vector']
   assert digest(vector) == profile['vector_sha256']
   if 'vector_bytes' in profile:
    assert vector.stat().st_size == profile['vector_bytes']
  if isinstance(profile.get('vectors_sha256'), dict):
   checked_map(rp.parent / profile['name'], profile['vectors_sha256'])
  for file_key, hash_key in [('preparation', 'preparation_sha256'), ('summary', 'summary_sha256')]:
   if hash_key in profile:
    assert digest(rp.parent / profile[file_key]) == profile[hash_key]
  if i < len(plan.get('profiles', [])):
   for k, v in plan['profiles'][i].items():
    if k in profile:
     assert profile[k] == v, ('profile', i, k)
 for n, h in r.get('reused_vectors', {}).items():
  assert digest(ref(p, n)) == h
 # Images are classified by each simulation execution, never by unique-image count.
 compiled, success, failed = {}, {}, {}
 for c in records:
  if '-o' in c['argv']:
   assert c['status'] == 'PASS'
   q = Path(c['argv'][c['argv'].index('-o') + 1]).resolve()
   assert q.is_relative_to(p)
   compiled[q] = digest(q)
   if 'image_sha256' in c:
    assert ref(p, c['image']).resolve() == q and c['image_sha256'] == compiled[q]
  if Path(c['argv'][0]).stem.lower() == 'vvp':
   q = Path(c['argv'][1]).resolve()
   assert q in compiled and digest(q) == compiled[q]
   for field in ('execution_image_sha256', 'input_image_sha256'):
    if field in c:
     assert c[field] == compiled[q]
   (success if c['status'] == 'PASS' else failed)[q] = compiled[q]
 return dict(receipt=rp, plan=pp, r=r, plan_data=plan, records=records, preparations=prep,
             successful_images=success, failed_images=failed)


def merge_images(target, other):
 for q, h in other.items():
  assert q not in target or target[q] == h
  target[q] = h


def bridge_images(p, mapping):
 result = {}
 for n, h in mapping.items():
  q = ref(p, n).resolve()
  assert q.is_relative_to(p) and q.suffix == '.vvp' and digest(q) == h
  result[q] = h
 return result


def verify_a_patch(p, d, runs):
 assert d['prior_evidence']['current_source_exceptions'] == ['sim/tb_position_gated_ioc8.sv']
 changed = 'sim/tb_position_gated_ioc8.sv'
 before = archived(p, runs[0]['receipt'], runs[0]['r'], changed).read_bytes()
 after = (p / changed).read_bytes()
 patch = load(p / 'REPAIR01_TB_PATCH.json')
 old = b'order(0,13,0,10,2);done(0,0,2,0,2,0,1,1,1,0,5,1,0);'
 new = b'order(0,13,0,10,1);done(0,0,2,0,1,0,1,1,1,0,5,1,0);'
 assert patch['before'].encode() == old and patch['after'].encode() == new
 assert before.count(old) == 1 and after == before.replace(old, new, 1)
 assert [i for i, (a, b) in enumerate(zip(old, new)) if a != b] == [16, 32]
 assert sha(before) == patch['failed_tb_sha256'] and sha(after) == patch['corrected_tb_sha256']
 assert (p / 'planning/tb_position_gated_ioc8.failed_order5.sv').read_bytes() == before
 for run, field, pending in [(runs[0], 'reviewed_original_plan_sha256', 'planning/FINITE_PLAN.pending_before_first_run.json'),
                            (runs[1], 'reviewed_repair_plan_sha256', 'planning/REPAIR01_PLAN.pending_before_run.json')]:
  approved_review_only(run['plan'], 'NO_BLOCKER_C_AND_ROOT', 'PENDING_C_AND_ROOT', d[field])
  assert digest(p / pending) == d[field]
 assert runs[0]['r']['oracle_completed_calls'] == 3
 assert runs[1]['r']['oracle_calls'] == runs[1]['r']['numerical_preparation_calls'] == 0
 assert runs[1]['plan_data']['original_current_source_exception'] == changed


def verify_root_patch_and_slices(p, d, runs):
 for desc, run in zip(d['evidence_runs'], runs):
  approved_review_only(run['plan'], 'NO_BLOCKER_A', 'PENDING_A', desc['reviewed_pending_plan_sha256'])
 patch = load(p / 'REPAIR01_TB_PATCH.json')
 original = (p / 'sim/tb_int4_subpixel_upsample2x.sv').read_bytes()
 changed = (p / 'sim/tb_int4_subpixel_upsample2x_repair01.sv').read_bytes()
 assert sha(original) == patch['original_sha256'] and sha(changed) == patch['instrumented_sha256']
 assert len(patch['patches']) == 6
 transformed = original
 for i, item in enumerate(patch['patches']):
  a, b = item['before'].encode(), item['after'].encode()
  assert transformed.count(a) == 1
  if i == 0:
   assert (a, b) == (b'module tb_int4_subpixel_upsample2x;', b'module tb_int4_subpixel_upsample2x_repair01;')
  else:
   assert b'$display("PROGRESS ' in b and b'$fflush();' in b
  transformed = transformed.replace(a, b, 1)
 assert transformed == changed
 rp, r = runs[1]['receipt'], runs[1]['r']
 summary_path = rp.parent / 'slice_summary.json'
 assert digest(summary_path) == r['slice_summary_sha256']
 summary = load(summary_path)
 assert summary['oracle_calls'] == r['new_oracle_calls'] == runs[1]['plan_data']['new_oracle_calls'] == 0
 source = Path(summary['source']).resolve()
 assert source == runs[0]['receipt'].parent / 'ci64_co16_w1024_h1024_t32.txt'
 raw = source.read_bytes()
 assert sha(raw) == summary['source_sha256'] == '609ebdca8ee028b4f0d0bcd395bd17f1eb500721cdad9ba9afe34f6fbb530e82'
 records = summary['records']
 assert len(records) == 26 and raw[:3] == b'26\n'
 offset, payloads = 3, []
 for i, item in enumerate(records):
  assert item['index'] == i and item['offset'] == offset and item['bytes'] > 0
  b = raw[offset:offset + item['bytes']]
  assert len(b) == item['bytes'] and sha(b) == item['sha256']
  assert list(map(int, b.splitlines()[0].split())) == item['fields'] and len(item['fields']) == 11
  payloads.append(b)
  offset += item['bytes']
 assert offset == len(raw) and b'26\n' + b''.join(payloads) == raw
 assert summary['parts'] == r['profiles']
 assert [x['indices'] for x in summary['parts']] == [[i for i in range(26) if i != 17], [17]]
 indices, reassembled = [], {}
 for part in summary['parts']:
  ii = part['indices']; indices.extend(ii)
  b = (str(len(ii)) + '\n').encode() + b''.join(payloads[i] for i in ii)
  assert (rp.parent / part['vector']).read_bytes() == b
  assert sha(b) == part['vector_sha256'] and len(b) == part['vector_bytes']
  for i in ii:
   assert i not in reassembled
   reassembled[i] = payloads[i]
  assert part['counts'] == {k: sum(records[i]['counts'][k] for i in ii) for k in summary['combined']}
 assert sorted(indices) == list(range(26)) and b'26\n' + b''.join(reassembled[i] for i in range(26)) == raw
 assert summary['combined'] == {k: sum(x['counts'][k] for x in records) for k in summary['combined']}
 assert summary['combined'] == {'frames': 26, 'inputs': 3693, 'outputs': 67678, 'configs': 3173, 'clips': 39304, 'inexact': 29230}
 assert d['maximum_row_status'] == 'NOT_QUALIFIED_TIMEOUT' and d['maximum_static_syntax'] == 'PASS'
 assert d['hdl_status_counts'] == {'PASS': 10, 'TIMEOUT': 2}
 assert len(runs[0]['preparations']) == 3 and len(runs[1]['preparations']) == 1
 assert runs[1]['preparations'][0]['kind'] == 'LITERAL_DATA_PREPARATION'


def source_list(p, name):
 sources, headers, dirs = [], [], []
 for line in (p / name).read_text().splitlines():
  line = line.split('#', 1)[0].strip()
  if not line:
   continue
  if line.startswith('+incdir+'):
   for d in line[8:].split('+'):
    q = (p / d).resolve()
    assert q.is_dir() and q.is_relative_to(ROOT)
    dirs.append(q)
   continue
  assert not line.startswith('-'), ('Unsupported nested file list', name, line)
  q = (p / line).resolve()
  assert q.is_file() and q.is_relative_to(ROOT) and q.suffix in ('.v', '.sv')
  n = q.relative_to(ROOT).as_posix()
  assert n not in sources
  sources.append(n)
  for h in re.findall(rb'`include\s+"([^"]+)"', q.read_bytes()):
   found = next((x.resolve() for x in [q.parent / h.decode(), *[d / h.decode() for d in dirs]] if x.is_file()), None)
   assert found and found.is_relative_to(ROOT)
   headers.append(found.relative_to(ROOT).as_posix())
 return sources, headers


def main():
 # Fail-stop: the guard is created before any audit work, never removed or retried.
 assert all(not (ROOT / n).exists() for n in OUTPUTS), 'B42 outputs already exist'
 with (ROOT / GUARD).open('x', encoding='utf-8', newline='\n') as f:
  f.write(json.dumps({'schema': 'anscore-b42-static-audit-once-v1', 'status': 'ATTEMPT_STARTED',
   'auditor_sha256': digest(Path(__file__)), 'baseline_commit': BASE, 'automatic_retry': False}, indent=2) + '\n')
 raw, old_raw = git('show', BASE + ':' + PARENT), git('show', BASE + ':' + OLD)
 assert sha(raw) == digest(ROOT / PARENT) == PARENT_SHA
 assert sha(old_raw) == digest(ROOT / OLD) == OLD_SHA
 parent, old = json.loads(raw), json.loads(old_raw)
 assert len(parent['packages']) == 164 and old['source_files'] == 358 and old['module_declarations'] == 360
 snap = copy.deepcopy(parent)
 inherited = set(old['canonical_source_paths'])
 assert len(inherited) == 358
 sources, summaries, new_files, canonical_base = set(inherited), [], {}, {}
 all_success, all_failed = {}, {}
 total_pass = total_fail = total_timeout = total_sims = numerical = literal = prep_children = 0
 production = set()
 for index, (path, top, example, risk, bridge_sha) in enumerate(NEW):
  p = ROOT / path
  assert digest(p / 'B42_DELIVERY.json') == bridge_sha
  d, inv = load(p / 'B42_DELIVERY.json'), inventory(p)
  check_attributes(p, inv)
  assert d.get('hardware') == 'HW_UNVERIFIED' or 'HW_UNVERIFIED' in d.get('status', [])
  for field in ('files', 'package_sha256', 'package_files', 'metadata_hashes', 'metadata_sha256',
   'delivery_metadata_sha256', 'source_archive', 'numerical_vectors', 'raw_streams',
   'formal_artifact_sha256', 'original_source_archive', 'original_numerical_vectors', 'protected_original_evidence_sha256'):
   if isinstance(d.get(field), dict):
    checked_map(p, d[field])
  for field in ('qualification', 'failure_archive', 'audit', 'seal'):
   if field in d and field + '_sha256' in d:
    assert digest(ref(p, d[field])) == d[field + '_sha256']
  checked_map(p, d.get('current_executable_sources', d.get('current_source_sha256', {})))
  tools_map(d['tools']); tools_map(d.get('preparation_tools', {}))
  for item in d['source_mapping']:
   a, b = (item['source'], item['exact_checked_copy']) if 'source' in item else (item['current'], item.get('archive', item.get('checked_archive')))
   assert digest(ref(p, a)) == item['sha256'] == digest(ref(p, b))
  if index == 3:
   descriptions = d['evidence_runs']
   assert [x['status'] for x in descriptions] == ['TIMEOUT', 'TIMEOUT']
  else:
   current = dict(receipt=d['receipt'], receipt_sha256=d['receipt_sha256'], plan=d['plan'],
                  plan_sha256=d['plan_sha256'], status='PASS', source_exceptions=[])
   if index == 0:
    prior = dict(d['prior_evidence']); prior['status'] = 'FAIL'
    prior['source_exceptions'] = prior['current_source_exceptions']
    descriptions = [prior, current]
   else:
    # C has an empty metadata object, not a prior receipt.
    assert d['prior_evidence'] == ([] if index == 1 else {'receipts': [], 'failed_images': {}, 'historical_hdl_failures': 0})
    descriptions = [current]
  runs = [verify_receipt(p, desc) for desc in descriptions]
  records = [c for run in runs for c in run['records']]
  preps = [c for run in runs for c in run['preparations']]
  counts = [sum(c['status'] == status for c in records) for status in ('PASS', 'FAIL', 'TIMEOUT')]
  sims = [c for c in records if Path(c['argv'][0]).stem.lower() == 'vvp' and c['status'] == 'PASS']
  n = 3 if index == 0 else (len(preps) if index == 1 else (1 if index == 2 else 3))
  lit = 1 if index == 3 else 0
  assert tuple(counts + [len(sims), n, lit]) == EXPECTED[index]
  success, failed = {}, {}
  for run in runs:
   merge_images(success, run['successful_images']); merge_images(failed, run['failed_images'])
  delivery_success = {}
  if index == 0:
   for field in ('verified_compiled_image_sha256', 'prior_successful_vvp_images'):
    merge_images(delivery_success, bridge_images(p, d[field]))
   verify_a_patch(p, d, runs)
  else:
   field = 'successful_vvps_for_root_cleanup' if index == 2 else 'successful_vvp_images'
   delivery_success = bridge_images(p, d[field])
  assert delivery_success == success
  assert bridge_images(p, d['failed_vvps_to_retain']) == failed
  if index == 3:
   assert bridge_images(p, d['shared_successful_failed_images']) == {q: success[q] for q in success.keys() & failed.keys()}
   assert bridge_images(p, d['verified_compiled_image_sha256']) == success | failed
   verify_root_patch_and_slices(p, d, runs)
  else:
   assert not success.keys() & failed.keys()
  if index == 1:
   r = runs[0]['r']
   assert r['preparation_attempts'] == r['preparation_completed_calls'] == 4 and r['oracle_imports'] == 0
   assert d['numerical_preparation_calls'] == d['passed_preparation_children'] == 4
   checked_map(p, load(ref(p, d['seal']))['sha256'])
  if index == 2:
   r = runs[0]['r']
   assert r['planning_python_calls'] == r['oracle_import_attempts'] == r['preparation_attempts'] == 1
   assert d['planning_python_calls'] == d['oracle_import_attempts'] == d['preparation_attempts'] == 1
   assert not preps and not d['prior_failures'] and not d['repairs']
  # Tie frozen expected counters to successful raw-marker observations.
  for run in runs:
   r = run['r']
   simulation_records = [c for c in run['records'] if Path(c['argv'][0]).stem.lower() == 'vvp']
   for i, profile in enumerate(r.get('profiles', [])):
    if i < len(simulation_records) and simulation_records[i]['status'] == 'PASS':
     observed = simulation_records[i].get('observed', simulation_records[i].get('counters'))
     for k, v in profile.get('expected_counters', {}).items():
      assert observed[k] == v
     for k, v in profile.get('counts', {}).items():
      if k in observed:
       assert observed[k] == v
  merge_images(all_success, success); merge_images(all_failed, failed)
  total_pass += counts[0]; total_fail += counts[1]; total_timeout += counts[2]
  total_sims += len(sims); numerical += n; literal += lit; prep_children += len(preps)
  lists, headers = {}, set()
  for name in ('files.f', 'example/files.f'):
   resolved, inc = source_list(p, name)
   lists[name] = resolved; sources.update(resolved); production.update(resolved); headers.update(inc)
  assert not headers
  for name in set(sum(lists.values(), [])) - inherited:
   if name.startswith(path + '/'):
    continue
   assert name in BASE_ADDITIONS
   oid, h = BASE_ADDITIONS[name]
   assert git('rev-parse', BASE + ':' + name).decode().strip() == oid
   assert git('hash-object', '--no-filters', str(ROOT / name)).decode().strip() == oid
   assert git('hash-object', '--path=' + name, str(ROOT / name)).decode().strip() == oid
   assert digest(ROOT / name) == h
   canonical_base[name] = dict(sha256=h, baseline_blob_oid=oid, baseline_commit=BASE,
    classification='TRACKED_SOURCE_FIRST_ADDED_TO_CUMULATIVE_CLOSURE')
  snap['packages'].append(dict(path=path, top=top, baseline_commit=BASE, evidence='B42_DELIVERY.json',
   evidence_kind='explicit_finite_checks_with_retained_history', hardware_status='HW_UNVERIFIED', architecture_risk=risk,
   additional_source_lists=['example/files.f'], examples=[dict(file='example/' + example + '.sv', top=example)], sha256=inv))
  summaries.append(dict(path=path, files=len(inv), effective_checks=counts[0], retained_failures=counts[1],
   retained_timeouts=counts[2], total_hdl_children=len(records), successful_simulations=len(sims),
   numerical_preparations=n, literal_preparation_children=lit, successful_unique_images=len(success),
   failed_or_timeout_unique_images=len(failed), shared_successful_failed_images=len(success.keys() & failed.keys()),
   architecture_risk=risk, source_lists=lists, include_files=[],
   maximum_row_status=d.get('maximum_row_status'), evidence_runs=[dict(path=run['receipt'].relative_to(ROOT).as_posix(),
    sha256=digest(run['receipt']), status=run['r']['status']) for run in runs]))
  new_files.update({path + '/' + name: h for name, h in inv.items()})
 assert snap['packages'][:164] == parent['packages']
 assert len(snap['packages']) == 168 and set(canonical_base) == set(BASE_ADDITIONS)
 assert len(production) == 19 and len(sources) == 368
 paths = sorted(inherited | set(canonical_base))
 packed = git('cat-file', '--batch', inp=''.join(BASE + ':' + n + '\n' for n in paths).encode())
 contents, offset = {}, 0
 for name in paths:
  end = packed.index(b'\n', offset); header = packed[offset:end].split()
  assert header[1] == b'blob'
  size = int(header[2]); contents[name] = packed[end + 1:end + 1 + size]; offset = end + size + 2
  assert digest(ROOT / name) == sha(contents[name]), ('Canonical source changed', name)
 assert offset == len(packed)
 declarations = {}
 for name in sorted(sources):
  code = re.sub(rb'/\*.*?\*/|//[^\n]*', b'', contents[name] if name in contents else (ROOT / name).read_bytes(), flags=re.S)
  for module in re.findall(rb'\bmodule\s+(?:automatic\s+)?([A-Za-z_][\w$]*)', code):
   declarations.setdefault(module.decode(), []).append(name)
 collisions = {n: pp for n, pp in declarations.items() if len(pp) > 1}
 assert not collisions and sum(map(len, declarations.values())) == 370
 assert (total_pass, total_fail, total_timeout, total_sims, numerical, literal, prep_children) == (43, 1, 2, 15, 11, 1, 8)
 assert (len(all_success), len(all_failed), len(all_success.keys() & all_failed.keys()), len(all_success | all_failed)) == (15, 3, 1, 17)
 # Recheck new inventories after all reads; no evidence file may change mid-audit.
 for path, *_ in NEW:
  assert inventory(ROOT / path) == snap['packages'][164 + [x[0] for x in NEW].index(path)]['sha256']
 freeze = ('B42 cumulative168 packages: position-limit reservations, spectral harmonic quality, raw optical-black rows and '
  'INT4 2x subpixel upsampling. Maximum INT4 row NOT_QUALIFIED_TIMEOUT; all failures/timeouts retained. '
  'Goal active; no synthesis/PnR/STA/board/PPA/inherited regression.')
 snap.update(date='2026-11-06', baseline_commit=BASE, batch_baseline_commit=BASE, previous_snapshot=PARENT, source_freeze=freeze,
  parent_snapshot=dict(path=PARENT, sha256=sha(raw), worktree_sha256=digest(ROOT / PARENT), hash_kind='committed_git_blob', commit=BASE),
  batch_canonical_base_sources=canonical_base, batch_support_file_additions={}, baseline_text_normalizations={})
 audit = dict(schema='anscore-b42-static-audit-v1', status='PASS', baseline_commit=BASE, packages=168,
  parent_snapshot_sha256=sha(raw), inherited_package_objects_exact=164, new_packages=summaries, new_package_files=len(new_files),
  effective_finite_checks=total_pass, historical_failed_children=total_fail, historical_timeout_children=total_timeout,
  total_hdl_children=total_pass + total_fail + total_timeout, successful_finite_simulations=total_sims,
  numerical_oracle_preparations=numerical, literal_preparation_children=literal, preparation_child_executions=prep_children,
  successful_unique_images=len(all_success), failed_or_timeout_unique_images=len(all_failed),
  shared_successful_failed_images=len(all_success.keys() & all_failed.keys()), total_unique_images=len(all_success | all_failed),
  maximum_subpixel_row_status='NOT_QUALIFIED_TIMEOUT', source_files=len(sources), module_declarations=sum(map(len, declarations.values())),
  canonical_source_paths=sorted(sources), new_canonical_base_sources=sorted(canonical_base), new_support_headers={},
  unresolved_module_collisions=collisions, execution_guard=GUARD,
  scope='Static source/archive/plan/vector/raw/tool/image audit, literal slice reassembly, exact repair and review-field proofs; inherited canonical bytes and package objects preserved. No qualification-code imports or HDL execution.',
  combined_compile='NOT_RUN', inherited_checker='NOT_RUN', synthesis='NOT_RUN', pnr='NOT_RUN', sta='NOT_RUN', board='NOT_RUN', ppa='NOT_RUN')
 # All assertions complete. Exclusive writes prevent overwriting prior evidence.
 payloads = [(json.dumps(value, indent=2) + '\n').encode() for value in (snap, audit)]
 for name, payload in zip(OUTPUTS, payloads):
  with (ROOT / name).open('xb') as f:
   f.write(payload)
 print(json.dumps({k: audit[k] for k in ('status', 'packages', 'new_package_files', 'effective_finite_checks',
  'historical_failed_children', 'historical_timeout_children', 'successful_finite_simulations', 'source_files', 'module_declarations')}))


if __name__ == '__main__':
 main()
