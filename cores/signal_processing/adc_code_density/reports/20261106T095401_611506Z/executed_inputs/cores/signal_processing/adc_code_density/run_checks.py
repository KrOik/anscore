"""SPDX-License-Identifier: Apache-2.0. Fresh finite runner; no oracle imports.

Root must review all frozen source, then authorize exactly one invocation with
the reviewed seal hash. Child stdout/stderr go directly to exclusive raw files;
there are no PIPE reader threads or text re-encoding in the capture path.
"""
from pathlib import Path
import argparse, datetime, hashlib, json, os, re, subprocess, time

PKG = Path(__file__).resolve().parent
ROOT = PKG.parents[2]


def digest(path):
 return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
 return json.loads(path.read_bytes())


def save(path, value, exclusive=False):
 with path.open('xb' if exclusive else 'wb') as stream:
  stream.write((json.dumps(value, indent=2)+'\n').encode())


def tree_stop(process, prefix, killer):
 """At most5s for taskkill, then at most2s to observe target exit.

 Direct raw-file redirection has no PIPE backlog. The2s exit observation is
 the sole drain interval. Cleanup failure is retained and stops the suite.
 """
 cleanup = dict(argv=[killer, '/PID', str(process.pid), '/T', '/F'],
                tree_kill_seconds=5, drain_seconds=2)
 helper = None
 started = time.monotonic()
 with Path(str(prefix)+'.cleanup.stdout.txt').open('xb') as out, Path(str(prefix)+'.cleanup.stderr.txt').open('xb') as err:
  try:
   helper = subprocess.Popen(cleanup['argv'], cwd=PKG, stdout=out, stderr=err, stdin=subprocess.DEVNULL,
                             creationflags=subprocess.CREATE_NO_WINDOW)
   try:
    helper.wait(timeout=max(0.001, 5-(time.monotonic()-started)))
   except subprocess.TimeoutExpired:
    helper.kill()
    cleanup['helper_timeout'] = True
   cleanup['returncode'] = helper.poll()
  except Exception as exc:
   cleanup['exception'] = repr(exc)
   cleanup['returncode'] = None
  try:
   process.wait(timeout=2)
   cleanup['target_exited'] = True
  except subprocess.TimeoutExpired:
   cleanup['target_exited'] = False
 for stream in ('stdout', 'stderr'):
  q = Path(str(prefix)+'.cleanup.'+stream+'.txt')
  cleanup[stream+'_sha256'] = digest(q)
 cleanup['seconds'] = round(time.monotonic()-started, 6)
 return cleanup


def child(run, result, expected, killer):
 c = {k: expected[k] for k in ('name', 'kind', 'argv', 'cwd', 'marker')}
 c.update(status='STARTING', timeout_seconds=20, tree_kill_seconds=5, drain_seconds=2,
          cleanup=[], returncode=None)
 entries = result['preparations'] if c['kind'] == 'PREPARATION' else result['checks']
 entries.append(c)
 result['active_child'] = c['name']
 save(run/'results.json', result)
 prefix = run/c['name']
 proc = None
 started = time.monotonic()
 env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
 suite = ROOT/'tools/oss-cad-suite/oss-cad-suite'
 path_prefix = [str(suite/'bin'), str(suite/'lib')]
 env['PATH'] = os.pathsep.join(path_prefix+[env.get('PATH', '')])
 c['path_prefix'] = path_prefix
 if c['kind'] == 'PREPARATION':
  result['preparation_attempts'] += 1
 try:
  with Path(str(prefix)+'.stdout.txt').open('xb') as out, Path(str(prefix)+'.stderr.txt').open('xb') as err:
   try:
    proc = subprocess.Popen(c['argv'], cwd=c['cwd'], stdout=out, stderr=err,
     stdin=subprocess.DEVNULL, env=env, creationflags=subprocess.CREATE_NO_WINDOW)
    c['pid'] = proc.pid
    c['status'] = 'RUNNING'
    save(run/'results.json', result)
    try:
     proc.wait(timeout=20)
     c['returncode'] = proc.returncode
     c['status'] = 'PASS' if proc.returncode == 0 else 'FAIL'
    except subprocess.TimeoutExpired:
     c['status'] = 'TIMEOUT'
   except Exception as exc:
    c['status'] = 'HARNESS_FAILURE'
    c['exception'] = repr(exc)
   finally:
    # Every path after a successful launch owns its target until observed exit
    # or one recorded bounded cleanup failure. Never start a following child.
    if proc is not None and proc.poll() is None and not c['cleanup']:
     # Exactly one cleanup attempt, including capture/launch exceptions. A
     # cleanup exception is evidence of failure, never permission to retry it.
     c['cleanup'].append(dict(status='STARTED'))
     try:
      c['cleanup'][0] = tree_stop(proc, prefix, killer)
     except Exception as exc:
      c['cleanup'][0] = dict(status='CLEANUP_FAILURE', exception=repr(exc))
      c['status'] = 'HARNESS_FAILURE'
     c['returncode'] = proc.poll()
 except Exception as exc:
  c['status'] = 'HARNESS_FAILURE'
  c['capture_exception'] = repr(exc)
 c['seconds'] = round(time.monotonic()-started, 6)
 if proc is not None:
  c['returncode'] = proc.poll()
 c['process_exited'] = proc is not None and c['returncode'] is not None
 for stream in ('stdout', 'stderr'):
  q = Path(str(prefix)+'.'+stream+'.txt')
  if q.exists():
   c[stream+'_sha256'] = digest(q)
 # Persist process exit, returncode, raw streams and timing before parsing any
 # marker or image metadata. A later postcheck exception cannot erase these.
 c['process_evidence_saved'] = True
 result['active_child'] = None
 save(run/'results.json', result)
 if '-o' in c['argv']:
  image = Path(c['argv'][c['argv'].index('-o')+1])
  if image.is_file():
   c['image'] = image.relative_to(PKG).as_posix()
   c['image_sha256'] = digest(image)
   result['compiled_image_sha256'][c['image']] = c['image_sha256']
 if c['status'] == 'PASS' and c['marker']:
  lines = [line for line in Path(str(prefix)+'.stdout.txt').read_bytes().splitlines()
           if line.startswith(c['marker'].encode())]
  if len(lines) != 1:
   c['status'] = 'FAIL_MARKER'
  else:
   c['observed'] = {k.decode(): int(v) for k, v in re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
 if Path(c['argv'][0]).stem.lower() == 'vvp':
  image = Path(c['argv'][1])
  c['execution_image_sha256'] = digest(image)
  key = image.relative_to(PKG).as_posix()
  if key not in result['compiled_image_sha256'] or result['compiled_image_sha256'][key] != c['execution_image_sha256']:
   c['status'] = 'FAIL_IMAGE_CHANGED'
 result['active_child'] = None
 save(run/'results.json', result)
 print(c['name']+' '+c['status'], flush=True)
 if c['status'] != 'PASS':
  raise RuntimeError(c['name']+' '+c['status']+'; fail-stop, no retry, all artifacts retained')
 return c


def main(reviewed_seal):
 seal_path, plan_path = PKG/'SOURCE_SEAL.json', PKG/'PRECHECK_PLAN.json'
 assert digest(seal_path) == reviewed_seal, 'Explicit reviewed seal hash required'
 seal, plan = read(seal_path), read(plan_path)
 assert seal['baseline'] == plan['baseline'] == '98176a8f970354ebd6191d0370662ab35ff53664'
 assert plan['automatic_retry'] is False and plan['fail_stop'] is True
 assert plan['child_environment']['PATH_prefix'] == [str(ROOT/'tools/oss-cad-suite/oss-cad-suite/bin'),
                                                    str(ROOT/'tools/oss-cad-suite/oss-cad-suite/lib')]
 for n, h in seal['sha256'].items():
  assert digest(ROOT/n) == h, ('sealed source', n)
 for n, h in seal['tools'].items():
  assert digest(Path(n)) == h, ('tool', n)
 stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
 save(PKG/'EXECUTION_LOCK.json', dict(schema='b43-adc-density-once-v1', stamp=stamp,
  reviewed_seal_sha256=reviewed_seal, status='ATTEMPT_STARTED_NO_RETRY'), exclusive=True)
 run, build = PKG/'reports'/stamp, PKG/'.build'/stamp
 run.mkdir(parents=True, exist_ok=False); build.mkdir(parents=True, exist_ok=False)
 result = dict(schema='anscore-b43-adc-density-results-v1', status='ARCHIVING', baseline=plan['baseline'],
  plan_sha256=digest(plan_path), seal_sha256=reviewed_seal, source_sha256=seal['sha256'],
  archived_sources={}, tools=seal['hdl_tools'], preparation_tools=seal['preparation_tools'],
  cleanup_tools=seal['cleanup_tools'], profiles=[], preparations=[], checks=[], compiled_image_sha256={},
  preparation_attempts=0, preparation_completed_calls=0, oracle_imports=0, numerical_preparation_calls=0,
  automatic_retry=False, active_child=None, archive_complete=False, preparation_complete=False, suite_complete=False)
 save(run/'results.json', result)
 # Archive control files as inert data, preserving their exact raw contents.
 for name, h in seal['sha256'].items():
  destination = run/'executed_inputs'/name
  if destination.name == '.gitattributes':
   destination = destination.with_name('.gitattributes.executed.txt')
  destination.parent.mkdir(parents=True, exist_ok=True)
  with destination.open('xb') as stream:
   stream.write((ROOT/name).read_bytes())
  assert digest(destination) == h
  result['archived_sources'][name] = destination.relative_to(PKG).as_posix()
 for name, q in [('plan.json', plan_path), ('source_seal.json', seal_path)]:
  with (run/name).open('xb') as stream:
   stream.write(q.read_bytes())
 result['archive_complete'] = True; result['status'] = 'RUNNING'
 save(run/'results.json', result)
 def concretize(item):
  return {key: ([s.replace('<stamp>', stamp) for s in value] if key == 'argv' else
                value.replace('<stamp>', stamp) if isinstance(value, str) else value)
          for key, value in item.items()}
 killer = plan['tree_kill_tool']
 try:
  for index, item in enumerate(plan['preparations']):
   profile = plan['profiles'][index]
   c = child(run, result, concretize(item), killer)
   assert c['observed'] == dict(profile=index, cases=profile['cases'])
   folder = run/profile['name']
   summary = read(folder/'preparation.json')
   assert summary['profile'] == profile and summary['preparation_calls'] == 1
   assert digest(folder/'vectors.txt') == summary['vector_sha256']
   assert (folder/'vectors.txt').stat().st_size == summary['vector_bytes']
   counts = summary['expected_counters']
   assert counts['cases'] == profile['cases'] and counts['commands'] == 2*profile['cases']+profile['aborts']
   assert counts['future_commands'] == profile['cases']
   assert counts['resets'] == 1+profile['aborts'] and counts['cancelled'] == profile['aborts']
   result['profiles'].append(dict(**profile, vector=profile['name']+'/vectors.txt',
    vector_sha256=summary['vector_sha256'], vector_bytes=summary['vector_bytes'],
    preparation=profile['name']+'/preparation.json', preparation_sha256=digest(folder/'preparation.json'),
    expected_counters=counts, cases_detail=summary['cases']))
   result['preparation_completed_calls'] += 1; result['numerical_preparation_calls'] += 1
   save(run/'results.json', result)
  result['preparation_complete'] = True
  save(run/'results.json', result)
  for item in plan['checks']:
   c = child(run, result, concretize(item), killer)
   if 'profile_index' in item and c['kind'] == 'HDL_SIMULATION':
    index = item['profile_index']; profile = result['profiles'][index]
    expected = dict(profile['expected_counters'], N=profile['samples'], F=profile['frac'],
                    T=profile['tag'], EX=profile['example'])
    for key, value in expected.items():
     assert c['observed'][key] == value, ('counter', c['name'], key)
    assert c['observed']['holds'] > 0 and c['observed']['blocked'] > 0 and c['observed']['done_holds'] > 0
    assert (c['observed']['pretrigger'] > 0) == bool(profile['example'])
  assert [c['name'] for c in result['checks']] == plan['expected_checks']
  assert len(result['checks']) == 11 and len(result['preparations']) == 4
  for name, h in seal['sha256'].items():
   assert digest(ROOT/name) == h
   assert digest(PKG/result['archived_sources'][name]) == h
  for name, h in seal['tools'].items():
   assert digest(Path(name)) == h
  for profile in result['profiles']:
   assert digest(run/profile['vector']) == profile['vector_sha256']
   assert digest(run/profile['preparation']) == profile['preparation_sha256']
  for name, h in result['compiled_image_sha256'].items():
   assert digest(PKG/name) == h
  for c in result['preparations']+result['checks']:
   for stream in ('stdout', 'stderr'):
    assert digest(run/(c['name']+'.'+stream+'.txt')) == c[stream+'_sha256']
  result.update(status='PASS', suite_complete=True, inputs_unchanged=True,
   archive_unchanged=True, vectors_unchanged=True, tools_unchanged=True, images_unchanged=True,
   check_sequence_matches=True)
 except Exception as exc:
  result.update(status='FAIL_STOP', failure=repr(exc))
 save(run/'results.json', result)
 print('ADC_DENSITY_FINITE_RESULT '+str(run/'results.json')+' '+result['status'], flush=True)
 if result['status'] != 'PASS':
  raise SystemExit(1)


if __name__ == '__main__':
 parser = argparse.ArgumentParser()
 parser.add_argument('--execute-reviewed-seal', required=True)
 main(parser.parse_args().execute_reviewed_seal)
