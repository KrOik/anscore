"""SPDX-License-Identifier: Apache-2.0. New B44 finite sealed runner.
Never imports the oracle or another runner. All preparation is in four archived
isolated children, before the first HDL child. No retry or scope expansion.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, re, subprocess, time

PACKAGE = Path(__file__).resolve().parent
REPOSITORY = PACKAGE.parents[2]


def sha(path):
 return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
 return json.loads(path.read_bytes())


def record(path, data, exclusive=False):
 with path.open('xb' if exclusive else 'wb') as stream:
  stream.write((json.dumps(data, indent=2)+'\n').encode())
  stream.flush()
  os.fsync(stream.fileno())


def sync_raw(stream):
 stream.flush()
 os.fsync(stream.fileno())


def stop_tree(target, prefix, executable, receipt, results_path, cleanup):
 cleanup.update(argv=[executable, '/PID', str(target.pid), '/T', '/F'],
  tree_kill_seconds=5, sole_exit_observation_seconds=2, target_pid=target.pid)
 began = time.monotonic()
 helper = None
 with Path(str(prefix)+'.cleanup.stdout.raw').open('xb') as output, Path(str(prefix)+'.cleanup.stderr.raw').open('xb') as error:
  try:
   helper = subprocess.Popen(cleanup['argv'], cwd=PACKAGE, stdout=output, stderr=error,
    stdin=subprocess.DEVNULL, creationflags=subprocess.CREATE_NO_WINDOW)
   cleanup.update(helper_pid=helper.pid, helper_status='RUNNING')
   receipt['active_helper'] = dict(name=prefix.name, pid=helper.pid, status='RUNNING')
   record(results_path, receipt)
   try:
    remaining = 5-(time.monotonic()-began)
    if remaining <= 0:
     raise subprocess.TimeoutExpired(cleanup['argv'], 5)
    helper.wait(timeout=remaining)
   except subprocess.TimeoutExpired:
    cleanup['helper_timeout'] = True
    helper.kill()  # Nonwaiting: never add another helper drain interval.
  except Exception as exc:
   cleanup['helper_exception'] = repr(exc)
  finally:
   cleanup['helper_returncode'] = None if helper is None else helper.poll()
   cleanup['helper_status'] = 'NOT_SPAWNED' if helper is None else (
    'EXITED' if cleanup['helper_returncode'] is not None else 'SURVIVED_CLEANUP')
   receipt['active_helper'] = None if helper is None or cleanup['helper_returncode'] is not None else dict(
    name=prefix.name, pid=helper.pid, status='SURVIVED_CLEANUP')
   record(results_path, receipt)
  try:
   target.wait(timeout=2)  # The one and only drain/exit observation interval.
   cleanup['target_exited'] = True
  except subprocess.TimeoutExpired:
   cleanup['target_exited'] = False
  finally:
   sync_raw(output)
   sync_raw(error)
 if helper is not None:
  cleanup['helper_returncode'] = helper.poll()
  cleanup['helper_status'] = 'EXITED' if cleanup['helper_returncode'] is not None else 'SURVIVED_CLEANUP'
  receipt['active_helper'] = None if cleanup['helper_returncode'] is not None else dict(
   name=prefix.name, pid=helper.pid, status='SURVIVED_CLEANUP')
 cleanup['seconds'] = round(time.monotonic()-began, 6)
 for name in ('stdout', 'stderr'):
  cleanup[name+'_sha256'] = sha(Path(str(prefix)+'.cleanup.'+name+'.raw'))
 cleanup['raw_finalized'] = cleanup['helper_status'] == 'EXITED'
 return cleanup


def run_child(folder, receipt, step, killer):
 item = dict(name=step['name'], kind=step['kind'], argv=step['argv'], cwd=step['cwd'],
  marker=step['marker'], status='STARTING', returncode=None, cleanup=[],
  execution_seconds=20, tree_kill_seconds=5, sole_exit_observation_seconds=2)
 receipt['children'].append(item)
 receipt['active_child'] = item['name']
 if item['kind'] == 'PREPARATION':
  receipt['preparation_attempts'] += 1
 suite = REPOSITORY/'tools/oss-cad-suite/oss-cad-suite'
 item['path_prefix'] = [str(suite/'bin'), str(suite/'lib')]
 environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
 environment['PATH'] = os.pathsep.join(item['path_prefix']+[environment.get('PATH', '')])
 record(folder/'results.json', receipt)
 prefix, process = folder/item['name'], None
 began = time.monotonic()
 try:
  with Path(str(prefix)+'.stdout.raw').open('xb') as output, Path(str(prefix)+'.stderr.raw').open('xb') as error:
   try:
    child_began = time.monotonic()
    process = subprocess.Popen(item['argv'], cwd=item['cwd'], env=environment,
     stdin=subprocess.DEVNULL, stdout=output, stderr=error, creationflags=subprocess.CREATE_NO_WINDOW)
    item.update(pid=process.pid, status='RUNNING')
    record(folder/'results.json', receipt)
    try:
     remaining = 20-(time.monotonic()-child_began)
     if remaining <= 0:
      raise subprocess.TimeoutExpired(item['argv'], 20)
     process.wait(timeout=remaining)
     item['status'] = 'PASS' if process.returncode == 0 else 'FAIL'
    except subprocess.TimeoutExpired:
     item['status'] = 'TIMEOUT'
   except Exception as exc:
    item.update(status='HARNESS_FAILURE', exception=repr(exc))
   finally:
    if process is not None and process.poll() is None and not item['cleanup']:
     item['cleanup'].append(dict(status='STARTED'))
     try:
      record(folder/'results.json', receipt)
     finally:
      try:
       stop_tree(process, prefix, killer, receipt, folder/'results.json', item['cleanup'][0])
      except Exception as exc:
       item['cleanup'][0].update(status='CLEANUP_FAILURE', exception=repr(exc))
       item['status'] = 'HARNESS_FAILURE'
    sync_raw(output)
    sync_raw(error)
 except Exception as exc:
  item.update(status='HARNESS_FAILURE', capture_exception=repr(exc))
 item['seconds'] = round(time.monotonic()-began, 6)
 item['returncode'] = None if process is None else process.poll()
 item['process_exited'] = process is not None and item['returncode'] is not None
 item['raw_finalized'] = process is None or item['process_exited']
 for name in ('stdout', 'stderr'):
  raw = Path(str(prefix)+'.'+name+'.raw')
  if raw.exists():
   item[name+'_sha256'] = sha(raw)
   item[name+'_bytes'] = raw.stat().st_size
 # Durable process/raw evidence precedes all marker, image and summary parsing.
 receipt['active_child'] = None if process is None or item['process_exited'] else dict(
  name=item['name'], pid=process.pid, status='SURVIVED_CLEANUP')
 item['process_evidence_saved'] = True
 record(folder/'results.json', receipt)
 if item['status'] == 'PASS' and '-o' in item['argv']:
  image = Path(item['argv'][item['argv'].index('-o')+1])
  if image.is_file():
   item['image'] = image.relative_to(PACKAGE).as_posix()
   item['image_sha256'] = sha(image)
   receipt['compiled_images'][item['image']] = item['image_sha256']
 if item['status'] == 'PASS' and Path(item['argv'][0]).stem.lower() == 'vvp':
  image = Path(item['argv'][1])
  item['executed_image'] = image.relative_to(PACKAGE).as_posix()
  item['executed_image_sha256'] = sha(image)
  if receipt['compiled_images'].get(item['executed_image']) != item['executed_image_sha256']:
   item['status'] = 'FAIL_IMAGE_CHANGED'
 if item['status'] == 'PASS' and item['marker']:
  lines = [line for line in Path(str(prefix)+'.stdout.raw').read_bytes().splitlines()
           if line.startswith(item['marker'].encode())]
  if len(lines) != 1:
   item['status'] = 'FAIL_MARKER'
  else:
   item['observed'] = {key.decode(): int(value) for key, value in re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
 record(folder/'results.json', receipt)
 print(item['name']+' '+item['status'], flush=True)
 if item['status'] != 'PASS':
  raise RuntimeError(item['name']+' '+item['status']+'; fail-stop; preserve every artifact; no retry')
 return item


def main(reviewed_sha):
 plan_path, seal_path, approval_path = PACKAGE/'PRECHECK_PLAN.json', PACKAGE/'SOURCE_SEAL.json', PACKAGE/'SOURCE_REVIEW.json'
 assert sha(seal_path) == reviewed_sha, 'Exact explicitly reviewed source seal required'
 plan, seal, approval = read(plan_path), read(seal_path), read(approval_path)
 assert plan['source_review'] == 'PENDING_ROOT'
 assert approval['baseline'] == plan['baseline']
 assert approval['source_seal_sha256'] == reviewed_sha and approval['plan_sha256'] == sha(plan_path)
 assert approval['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER' and approval['explicit_unique_execution_gate'] is True
 assert approval['root_review']['reviewer'] == 'root' and approval['root_review']['verdict'] == 'NO_BLOCKER'
 assert approval['peer_review']['reviewer'] != 'root' and approval['peer_review']['verdict'] == 'NO_BLOCKER'
 assert seal['baseline'] == plan['baseline'] == '09de72c578b3099d4e867c739118faa7607f663d'
 assert plan['automatic_retry'] is False and plan['planning_oracle_calls'] == 0
 assert plan['child_environment']['PATH_prefix'] == [str(REPOSITORY/'tools/oss-cad-suite/oss-cad-suite/bin'),
  str(REPOSITORY/'tools/oss-cad-suite/oss-cad-suite/lib')]
 for name, value in seal['sources'].items():
  assert sha(REPOSITORY/name) == value, ('source', name)
 for name, value in seal['tools'].items():
  assert sha(Path(name)) == value, ('tool', name)
 stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
 record(PACKAGE/'EXECUTION_LOCK.json', dict(schema='anscore-b44-sk-once-v1',
  stamp=stamp, reviewed_seal_sha256=reviewed_sha, approval_sha256=sha(approval_path), status='ATTEMPT_STARTED_NO_RETRY'), exclusive=True)
 folder = PACKAGE/'reports'/stamp
 build = PACKAGE/'.build'/stamp
 folder.mkdir(parents=True, exist_ok=False)
 build.mkdir(parents=True, exist_ok=False)
 receipt = dict(schema='anscore-b44-sk-results-v1', status='ARCHIVING', baseline=plan['baseline'],
  plan_sha256=sha(plan_path), seal_sha256=reviewed_sha, approval_sha256=sha(approval_path), source_sha256=seal['sources'], tools=seal['tools'],
  archived_sources={}, profiles=[], children=[], compiled_images={}, active_child=None, active_helper=None,
  preparation_attempts=0, numerical_preparation_calls=0, oracle_imports=0,
  automatic_retry=False, archive_complete=False, preparation_complete=False, suite_complete=False)
 record(folder/'results.json', receipt)
 for name, value in seal['sources'].items():
  archive = folder/'executed_inputs'/name
  if archive.name == '.gitattributes':
   archive = archive.with_name('.gitattributes.executed.txt')
  archive.parent.mkdir(parents=True, exist_ok=True)
  with archive.open('xb') as stream:
   stream.write((REPOSITORY/name).read_bytes())
   sync_raw(stream)
  assert sha(archive) == value
  receipt['archived_sources'][name] = archive.relative_to(PACKAGE).as_posix()
 for name, path in [('plan.json', plan_path), ('source_seal.json', seal_path), ('source_review.json', approval_path)]:
  with (folder/name).open('xb') as stream:
   stream.write(path.read_bytes())
   sync_raw(stream)
 receipt.update(status='RUNNING', archive_complete=True)
 record(folder/'results.json', receipt)
 def concrete(step):
  return {key: [value.replace('<stamp>', stamp) for value in data] if key == 'argv' else
          data.replace('<stamp>', stamp) if isinstance(data, str) else data for key, data in step.items()}
 try:
  for index, source_step in enumerate(plan['preparations']):
   profile = plan['profiles'][index]
   child = run_child(folder, receipt, concrete(source_step), plan['tree_kill_tool'])
   assert child['observed'] == dict(profile=index, cases=profile['cases'])
   destination = folder/profile['name']
   summary = read(destination/'preparation.json')
   assert summary['profile'] == profile and summary['preparation_calls'] == 1
   assert sha(destination/'vectors.txt') == summary['vector_sha256']
   assert (destination/'vectors.txt').stat().st_size == summary['vector_bytes']
   counts = summary['expected_counters']
   assert counts['cases'] == profile['cases'] and counts['commands'] == 2*profile['cases']+profile['aborts']
   assert counts['future_commands'] == counts['future_results'] == profile['cases']
   assert counts['resets'] == profile['aborts']+1 and counts['cancelled'] == profile['aborts']
   receipt['profiles'].append(dict(**profile, expected_counters=counts, cases_detail=summary['cases'],
    vector=profile['name']+'/vectors.txt', vector_sha256=summary['vector_sha256'], vector_bytes=summary['vector_bytes'],
    preparation=profile['name']+'/preparation.json', preparation_sha256=sha(destination/'preparation.json')))
   receipt['numerical_preparation_calls'] += 1
   record(folder/'results.json', receipt)
  receipt['preparation_complete'] = True
  record(folder/'results.json', receipt)
  for source_step in plan['checks']:
   child = run_child(folder, receipt, concrete(source_step), plan['tree_kill_tool'])
   if source_step['kind'] == 'HDL_SIMULATION':
    profile = receipt['profiles'][source_step['profile_index']]
    expected = dict(profile['expected_counters'], B=profile['bins'], M=profile['frames'], P=profile['power'],
     F=profile['frac'], T=profile['tag'], EX=profile['example'])
    for key, value in expected.items():
     assert child['observed'][key] == value, ('counter', child['name'], key)
    assert all(child['observed'][key] > 0 for key in ('holds', 'blocked', 'input_holds'))
  assert [child['name'] for child in receipt['children']] == plan['expected_children']
  assert len(receipt['children']) == 15 and receipt['numerical_preparation_calls'] == 4
  for name, value in seal['sources'].items():
   assert sha(REPOSITORY/name) == value
   assert sha(PACKAGE/receipt['archived_sources'][name]) == value
  for name, value in seal['tools'].items():
   assert sha(Path(name)) == value
  assert sha(folder/'plan.json') == receipt['plan_sha256'] and sha(plan_path) == receipt['plan_sha256']
  assert sha(folder/'source_seal.json') == reviewed_sha and sha(seal_path) == reviewed_sha
  assert sha(folder/'source_review.json') == receipt['approval_sha256'] and sha(approval_path) == receipt['approval_sha256']
  for profile in receipt['profiles']:
   assert sha(folder/profile['vector']) == profile['vector_sha256']
   assert sha(folder/profile['preparation']) == profile['preparation_sha256']
  for name, value in receipt['compiled_images'].items():
   assert sha(PACKAGE/name) == value
  for child in receipt['children']:
   assert child['process_exited'] and child['returncode'] == 0 and not child['cleanup']
   for name in ('stdout', 'stderr'):
    assert sha(folder/(child['name']+'.'+name+'.raw')) == child[name+'_sha256']
  receipt.update(status='PASS', suite_complete=True, current_and_archived_sources_unchanged=True,
   tools_vectors_raw_and_images_unchanged=True, sequence_exact=True)
 except Exception as exc:
  receipt.update(status='FAIL_STOP', failure=repr(exc))
 record(folder/'results.json', receipt)
 print('SK_FINITE_RESULT '+str(folder/'results.json')+' '+receipt['status'], flush=True)
 if receipt['status'] != 'PASS':
  raise SystemExit(1)


if __name__ == '__main__':
 parser = argparse.ArgumentParser()
 parser.add_argument('--execute-reviewed-seal', required=True)
 main(parser.parse_args().execute_reviewed_seal)
