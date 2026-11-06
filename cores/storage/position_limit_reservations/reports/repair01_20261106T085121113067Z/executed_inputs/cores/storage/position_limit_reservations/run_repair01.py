"""SPDX-License-Identifier: Apache-2.0. Independent B42 example-only repair01."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite';BIN=SUITE/'bin'
PLAN=ROOT/'REPAIR01_PLAN.json';PARENT=ROOT/'reports/20261106T082558407905Z'
PARENT_SHA='557c45f25ad0f4359db17810ee392cf6d21a470131bf4527e98576005db99756'
INPUTS=['rtl/position_limit_reservations.sv','example/position_gated_ioc8.sv',
 'sim/tb_position_limit_reservations.sv','sim/tb_position_gated_ioc8.sv',
 'reference_model.py','run_checks.py','files.f','example/files.f',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../ram_ordered_dictionary/rtl/ram_ordered_dictionary.sv','../price_level_order_book/rtl/price_level_order_book.sv',
 '../../acceleration/price_level_ioc_matcher/rtl/price_level_ioc_matcher.sv',
 'README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes',
 'run_repair01.py','REPAIR01_TB_PATCH.json','REPAIR01.md']
TOOLS={name:BIN/(name+'.exe')for name in ['iverilog','vvp']}
EXPECTED=dict(admins=17,maintenance=8,orders=21,done_results=19,fills=8,holds=183,resets=4,cancelled=2,isolated=2)

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def commands(stamp):
 image=ROOT/'.work'/stamp/'example_repair01.vvp'
 def spec(name,argv,marker=None):return dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),marker=marker,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2)
 return [spec('compile_example_repair01',[TOOLS['iverilog'],'-g2012','-Wall','-s','tb_position_gated_ioc8',
  '-o',image,'-f','example/files.f','sim/tb_position_gated_ioc8.sv']),
  spec('sim_example_repair01',[TOOLS['vvp'],image],'PASS position_gated_ioc8 ')]

def parent_evidence():
 assert digest(PARENT/'results.json')==PARENT_SHA
 receipt=json.loads((PARENT/'results.json').read_bytes())
 assert receipt['status']=='FAIL' and len(receipt['checks'])==11 and receipt['checks'][-1]['name']=='sim_example'
 assert receipt['oracle_completed_calls']==3
 evidence={str((PARENT/'results.json').relative_to(ROOT)).replace('\\','/'):PARENT_SHA,
  str((PARENT/'plan.json').relative_to(ROOT)).replace('\\','/'):receipt['plan_sha256'],'FINITE_PLAN.json':receipt['plan_sha256']}
 for name,path in receipt['archived_sources'].items():evidence[path]=receipt['source_sha256'][name]
 for row in receipt['checks']:
  for stream in ['stdout','stderr']:evidence[(PARENT/(row['name']+'.'+stream+'.txt')).relative_to(ROOT).as_posix()]=row[stream+'_sha256']
  if 'image'in row:evidence[row['image']]=row['image_sha256']
 for profile in receipt['profiles']:evidence[(PARENT/profile['vector']).relative_to(ROOT).as_posix()]=profile['vector_sha256']
 for file in (ROOT/'planning').iterdir():
  if file.is_file():evidence[file.relative_to(ROOT).as_posix()]=digest(file)
 for name,sha in evidence.items():assert digest(ROOT/name)==sha,name
 return evidence

def verify_patch():
 patch=json.loads((ROOT/'REPAIR01_TB_PATCH.json').read_bytes());old=(ROOT/'planning/tb_position_gated_ioc8.failed_order5.sv').read_bytes()
 before=patch['before'].encode();after=patch['after'].encode()
 assert hashlib.sha256(old).hexdigest()==patch['failed_tb_sha256'] and old.count(before)==1
 assert old.replace(before,after)==(ROOT/'sim/tb_position_gated_ioc8.sv').read_bytes()
 assert digest(ROOT/'sim/tb_position_gated_ioc8.sv')==patch['corrected_tb_sha256']

def write_plan():
 assert not PLAN.exists() and not any((ROOT/'reports').glob('repair01_*'))
 verify_patch();evidence=parent_evidence()
 plan=dict(schema='anscore-b42-position-reservations-repair01-plan-v1',baseline_commit='2e7a6fb51f32e525c1026c28d1f2f45e36545ebc',
  source_review='PENDING_C_AND_ROOT',parent_receipt_sha256=PARENT_SHA,parent_evidence=evidence,
  source_sha256={n:digest(ROOT/n)for n in INPUTS},tool_sha256={n:digest(p)for n,p in TOOLS.items()},
  checks=commands('<stamp>'),expected_children=2,successful_simulations_if_pass=1,
  oracle_calls=0,numerical_preparation_calls=0,automatic_retry=False,fail_stop=True,
  example_expected=EXPECTED,minimum_blocked=8,
  original_current_source_exception='sim/tb_position_gated_ioc8.sv',
  scope='Only two example compile/simulation children after exact two-literal TB order5 quantity/remainder correction. Zero oracle/preparation, no successful core/syntax rerun, no RTL or other expectation changes. Preserve every original failure artifact; no retry/cleanup.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('PENDING_REPAIR01_PLAN_SHA256',digest(PLAN))

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
     rec['cleanup'].append(dict(argv=[str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F'],hard_seconds=5,returncode=killed.returncode,stdout=killed.stdout.decode(errors='replace'),stderr=killed.stderr.decode(errors='replace'),stdout_sha256=hashlib.sha256(killed.stdout).hexdigest(),stderr_sha256=hashlib.sha256(killed.stderr).hexdigest()))
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
 if sys.argv[1:]!=['--execute-approved-plan']:raise SystemExit('Use explicit reviewed REPAIR01 plan')
 assert not any((ROOT/'reports').glob('repair01_*')),'Existing started repair; no automatic retry'
 stamp='repair01_'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False);(ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b42-position-reservations-repair01-v1',status='INCOMPLETE',checks=[],plan_sha256=digest(PLAN),
  source_sha256={},archived_sources={},tools={},parent_evidence={},parent_receipt_sha256=PARENT_SHA,
  archive_complete=False,oracle_calls=0,numerical_preparation_calls=0,automatic_retry=False,suite_complete=False,
  phase='PLAN_VALIDATION',active_child=None,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
 def save():
  temporary=out/'results.json.tmp'
  with temporary.open('w',encoding='utf-8',newline='\n')as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
  temporary.replace(out/'results.json')
 def invariant():
  assert report['archive_complete']
  assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  assert all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n])for n,h in report['source_sha256'].items())
  assert all(digest(ROOT/n)==h for n,h in report['parent_evidence'].items())
  assert all(digest(TOOLS[n])==data['sha256']for n,data in report['tools'].items())
  assert all(digest(ROOT/c['image'])==c['image_sha256']for c in report['checks']if 'image'in c)
 save();plan=None;stopped=False
 try:
  plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_C_AND_ROOT'
  assert plan['checks']==commands('<stamp>') and plan['expected_children']==2 and plan['oracle_calls']==plan['numerical_preparation_calls']==0
  assert set(plan['source_sha256'])==set(INPUTS) and set(plan['tool_sha256'])==set(TOOLS)
  assert all(digest(ROOT/n)==h for n,h in plan['source_sha256'].items())
  assert all(digest(TOOLS[n])==h for n,h in plan['tool_sha256'].items())
  assert all(digest(ROOT/n)==h for n,h in plan['parent_evidence'].items());verify_patch()
  report['parent_evidence']=plan['parent_evidence'];shutil.copyfile(PLAN,out/'plan.json');report['phase']='SOURCE_ARCHIVE';save()
  for name in INPUTS:
   source=(ROOT/name).resolve();target=out/'executed_inputs'/source.relative_to(REPO)
   if source.name=='.gitattributes':target=target.with_name('.gitattributes.executed.txt')
   target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
   report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
  report['tools']={n:dict(path=str(p),sha256=digest(p))for n,p in TOOLS.items()}
  report.update(archive_complete=True,phase='INPUTS_FROZEN');save()
  env=dict(os.environ);env['PATH']=os.pathsep.join([str(BIN),str(SUITE/'lib'),env.get('PATH','')])
  for spec in commands(stamp):
   invariant();report.update(phase='HDL_CHILD',active_child=spec);save();rec=execute(spec,env,out)
   report['checks'].append(rec);report['active_child']=None;save()
   if spec['argv'][0]==str(TOOLS['vvp']):rec['execution_image_sha256']=digest(Path(spec['argv'][1]))
   if rec['status']=='PASS'and 'observed'in rec:
    if rec['observed'].get('blocked',0)<plan['minimum_blocked'] or not all(rec['observed'].get(n)==v for n,v in plan['example_expected'].items()):rec.update(status='FAIL_COVERAGE',expected=plan['example_expected'])
   save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];stopped=True;break
  if not stopped:report['status']='PASS'
 except Exception:report.update(status='RUNNER_FAILED',exception=traceback.format_exc());stopped=True
 finally:
  try:invariant();unchanged=True
  except Exception:unchanged=False
  sequence=plan is not None and [c['name']for c in report['checks']]==[c['name']for c in plan['checks']]
  ok=not stopped and report['status']=='PASS'and unchanged and sequence
  if report['status']=='PASS'and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(inputs_unchanged=unchanged,exact_plan_executed=sequence,suite_complete=ok,phase='COMPLETE'if ok else'STOPPED')
  report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete']else 1
if __name__=='__main__':sys.exit(main())
