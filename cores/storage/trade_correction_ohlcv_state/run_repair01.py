"""SPDX-License-Identifier: Apache-2.0. Explicit example-only repair01, no oracle."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';PLAN=ROOT/'REPAIR01_PLAN.json'
PRIOR='reports/20261106T073412565874Z/results.json'
PRIOR_SHA='771801a4adb43e46a2a0a3f54367c1256662bee5a0d4486c5cd8e073486e9bb6'
ORIGINAL_PLAN_SHA='f1d89ff3d4b086b1284ac455eb081d6da7f301784390177c21260a62d84c44e1'
PENDING_ORIGINAL_PLAN_SHA='a52179c1ba3d5ce497880f2773adf79b54259ed4cf5b5edf0e6cd0db1444da23'
EXCEPTION='example/itch_execution_statistics8.sv'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def prior_evidence():
 receipt=ROOT/PRIOR;assert digest(receipt)==PRIOR_SHA
 r=json.loads(receipt.read_bytes());original=ROOT/'FINITE_PLAN.json';plan=json.loads(original.read_bytes())
 assert digest(original)==r['plan_sha256']==digest(receipt.parent/'plan.json')==ORIGINAL_PLAN_SHA
 pending=original.read_bytes().replace(b'"source_review": "NO_BLOCKER_C_AND_ROOT"',b'"source_review": "PENDING_C_AND_ROOT"')
 assert hashlib.sha256(pending).hexdigest()==PENDING_ORIGINAL_PLAN_SHA
 assert r['status']=='FAIL' and not r['suite_complete'] and len(r['checks'])==11
 assert all(x['status']=='PASS' for x in r['checks'][:-1]) and r['checks'][-1]['name']=='sim_example' and r['checks'][-1]['status']=='FAIL'
 for n,h in r['source_sha256'].items():
  assert digest(ROOT/r['archived_sources'][n])==h
  if n==EXCEPTION:assert digest(ROOT/n)!=h
  else:assert digest(ROOT/n)==h
 for c,e in zip(r['checks'],plan['checks']):
  assert c['argv']==[a.replace('<stamp>',receipt.parent.name) for a in e['argv']] and c['cwd']==e['cwd']
  for stream in ['stdout','stderr']:assert digest(receipt.parent/(c['name']+'.'+stream+'.txt'))==c[stream+'_sha256']
  if 'image' in c:assert digest(ROOT/c['image'])==c['image_sha256']
 for n,v in r['tools'].items():assert digest(Path(v['path']))==v['sha256']==plan['tool_sha256'][n]
 for v in r['profiles']:assert digest(receipt.parent/v['vector'])==v['vector_sha256']
 return r,plan
def commands(stamp):
 image=ROOT/'.work'/stamp/'example_repair01.vvp'
 return [dict(name='compile_example',argv=list(map(str,[BIN/'iverilog.exe','-g2012','-Wall','-s','tb_itch_execution_statistics8','-o',image,'-f','example/files.f','sim/tb_itch_execution_statistics8.sv'])),cwd=str(ROOT),marker=None,hard_seconds=20,cleanup_seconds=7),
  dict(name='sim_example',argv=list(map(str,[BIN/'vvp.exe',image])),cwd=str(ROOT),marker='PASS itch_execution_statistics8 ',hard_seconds=20,cleanup_seconds=7)]
def write_plan():
 if PLAN.exists():raise RuntimeError('Repair plan already exists; no automatic replan')
 assert sorted(x.name for x in (ROOT/'reports').iterdir())==['20261106T073412565874Z']
 r,old=prior_evidence();names=list(r['source_sha256'])+['FINITE_PLAN.json','run_repair01.py']
 plan=dict(schema='anscore-b41-trade-correction-ohlcv-state-repair01-plan-v1',baseline_commit=old['baseline_commit'],source_review='PENDING_C_AND_ROOT',
  expected_children=2,successful_simulations_if_pass=1,fail_stop=True,automatic_retry=False,numerical_preparation_calls=0,oracle_calls=0,
  prior_receipt=PRIOR,prior_receipt_sha256=PRIOR_SHA,original_plan='FINITE_PLAN.json',original_plan_sha256=ORIGINAL_PLAN_SHA,
  reviewed_original_plan_sha256=PENDING_ORIGINAL_PLAN_SHA,current_source_exceptions=[EXCEPTION],
  repair='Only failed EVENT_TRADE response now calls capture_trade before dual INVALIDATE; core/model/TBs/originalrunner unchanged.',
  source_sha256={n:digest(ROOT/n)for n in names},tool_sha256=old['tool_sha256'],checks=commands('<stamp>'),example_expected=old['example_expected'],
  reused_vectors={str((Path(PRIOR).parent/v['vector']).as_posix()):v['vector_sha256']for v in r['profiles']},
  prior_images={c['image']:c['image_sha256']for c in r['checks']if 'image'in c},
  scope='Exactly two example compile/sim children; original 10PASS/1FAIL/3 core simulations retained; no oracle, successful core/syntax rerun, synthesis/PnR/STA/board/PPA.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print(str(PLAN))
def execute(spec,env,out):
 rec=dict(spec,cleanup=[]);start=time.monotonic();stdout=stderr=b''
 try:child=subprocess.Popen(spec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
   **({'creationflags':subprocess.CREATE_NO_WINDOW}if os.name=='nt'else{'start_new_session':True}))
 except OSError as exc:rec.update(status='NOT_RUN',returncode=None);stderr=repr(exc).encode()
 else:
  try:stdout,stderr=child.communicate(timeout=20);rec.update(status='PASS'if child.returncode==0 else'FAIL',returncode=child.returncode)
  except subprocess.TimeoutExpired as exc:
   rec.update(status='TIMEOUT',returncode=None);stdout,stderr=exc.stdout or b'',exc.stderr or b''
   try:
    if os.name=='nt':
     killed=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F'],capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
     rec['cleanup'].append(dict(returncode=killed.returncode,stdout=killed.stdout.decode(errors='replace'),stderr=killed.stderr.decode(errors='replace')))
    else:os.killpg(child.pid,signal.SIGKILL)
   except(OSError,subprocess.SubprocessError)as exc:rec['cleanup'].append(dict(error=repr(exc)))
   try:
    if child.poll()is None:child.kill()
    stdout,stderr=child.communicate(timeout=2)
   except(OSError,subprocess.SubprocessError)as exc:rec['cleanup'].append(dict(drain_error=repr(exc)))
   rec['returncode']=child.poll()
 if rec['status']=='PASS'and spec['marker']:
  lines=[line for line in stdout.splitlines()if line.startswith(spec['marker'].encode())]
  if len(lines)!=1 or b'$finish'not in stdout:rec['status']='FAIL_NO_MARKER'
  else:rec['observed']={key:int(value)for key,value in re.findall(r'(\w+)=(\d+)',lines[0].decode())}
 for stream,raw in [('stdout',stdout),('stderr',stderr)]:
  (out/(spec['name']+'.'+stream+'.txt')).write_bytes(raw);rec[stream+'_sha256']=hashlib.sha256(raw).hexdigest()
 rec['seconds']=round(time.monotonic()-start,4)
 if '-o'in spec['argv']:
  image=Path(spec['argv'][spec['argv'].index('-o')+1])
  if image.is_file():rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=digest(image))
 return rec
def main():
 if sys.argv[1:]==['--write-plan']:write_plan();return 0
 if sys.argv[1:]!=['--execute-approved-plan']:raise SystemExit('Use --write-plan or reviewed --execute-approved-plan')
 assert sorted(x.name for x in (ROOT/'reports').iterdir())==['20261106T073412565874Z'],'Existing repair evidence; no retry'
 prior,original=prior_evidence();plan=json.loads(PLAN.read_bytes())
 assert plan['source_review']=='NO_BLOCKER_C_AND_ROOT' and plan['checks']==commands('<stamp>') and plan['expected_children']==2
 assert all(digest(ROOT/n)==h for n,h in plan['source_sha256'].items())
 assert all(digest(BIN/(n+'.exe'))==h for n,h in plan['tool_sha256'].items())
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(exist_ok=False);(ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 r=dict(schema='anscore-b41-trade-correction-ohlcv-state-repair01-results-v1',status='INCOMPLETE',checks=[],source_sha256={},archived_sources={},
  tools={n:dict(path=str(BIN/(n+'.exe')),sha256=h)for n,h in plan['tool_sha256'].items()},plan_sha256=digest(PLAN),phase='SOURCE_ARCHIVE',archive_complete=False,
  active_child=None,suite_complete=False,oracle_completed_calls=0,numerical_preparation_calls=0,automatic_retry=False,prior_receipt=PRIOR,prior_receipt_sha256=PRIOR_SHA,
  reused_vectors=plan['reused_vectors'],prior_images=plan['prior_images'],synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
 def save():
  f=out/'results.json.tmp'
  with f.open('w',encoding='utf-8',newline='\n')as stream:json.dump(r,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
  f.replace(out/'results.json')
 save();stopped=False
 try:
  shutil.copyfile(PLAN,out/'plan.json')
  for n,h in plan['source_sha256'].items():
   source=(ROOT/n).resolve();target=out/'executed_inputs'/source.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
   r['source_sha256'][n]=digest(target);r['archived_sources'][n]=target.relative_to(ROOT).as_posix()
  r['archive_complete']=True;save()
  env=dict(os.environ);env['PATH']=os.pathsep.join([str(BIN),str(BIN.parent/'lib'),env.get('PATH','')])
  for spec in commands(stamp):
   prior_evidence()
   assert digest(PLAN)==r['plan_sha256']==digest(out/'plan.json')
   assert all(digest(ROOT/n)==h==digest(ROOT/r['archived_sources'][n])for n,h in r['source_sha256'].items())
   assert all(digest(BIN/(n+'.exe'))==h for n,h in plan['tool_sha256'].items())
   r.update(phase='HDL_CHILD',active_child=spec);save();rec=execute(spec,env,out)
   if rec['status']=='PASS'and spec['marker'] and rec.get('observed')!=plan['example_expected']:rec.update(status='FAIL_COVERAGE',expected=plan['example_expected'])
   r['checks'].append(rec);r['active_child']=None;save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':r['status']=rec['status'];stopped=True;break
  if not stopped:r['status']='PASS'
 except Exception:r.update(status='RUNNER_FAILED',exception=traceback.format_exc());stopped=True
 finally:
  source_ok=r['archive_complete']and all(digest(ROOT/n)==h==digest(ROOT/r['archived_sources'][n])for n,h in r['source_sha256'].items())
  plan_ok=(out/'plan.json').is_file()and digest(PLAN)==r['plan_sha256']==digest(out/'plan.json')
  tools_ok=all(digest(Path(v['path']))==v['sha256']for v in r['tools'].values())
  vector_ok=all(digest(ROOT/n)==h for n,h in r['reused_vectors'].items())
  images_ok=all(digest(ROOT/n)==h for n,h in r['prior_images'].items())
  sequence_ok=[c['name']for c in r['checks']]==[c['name']for c in plan['checks']]
  ok=not stopped and r['status']=='PASS'and source_ok and plan_ok and tools_ok and vector_ok and images_ok and sequence_ok
  if r['status']=='PASS'and not ok:r['status']='INPUT_CHANGED_OR_INCOMPLETE'
  r.update(sources_unchanged=source_ok,archived_sources_unchanged=source_ok,plan_unchanged=plan_ok,tools_unchanged=tools_ok,
   reused_vectors_unchanged=vector_ok,prior_images_unchanged=images_ok,exact_plan_executed=sequence_ok,suite_complete=ok,phase='COMPLETE'if ok else'STOPPED')
  r['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if r['suite_complete']else 1
if __name__=='__main__':sys.exit(main())
