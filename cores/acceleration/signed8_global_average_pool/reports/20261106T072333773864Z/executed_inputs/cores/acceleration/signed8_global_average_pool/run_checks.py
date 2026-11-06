"""SPDX-License-Identifier: Apache-2.0. B41 finite fail-stop qualification."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
from vector_plan import PROFILES,label,vectors
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
SOURCES=['rtl/signed8_global_average_pool.sv','example/pooled_int4_classifier.sv',
 'sim/tb_signed8_global_average_pool.sv','reference_model.py','vector_plan.py','run_checks.py',
 'files.f','example/files.f','README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes',
 '../integer_divider/rtl/integer_divider.v','../int4_weight_matvec/rtl/int4_weight_matvec.sv',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v']
PLAN=ROOT/'FINITE_PLAN.json'
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def commands(stamp):
 iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe');checks=[]
 def add(name,argv,marker=None):
  checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),marker=marker,timeout_seconds=20,cleanup_budget_seconds=7))
 add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','signed8_global_average_pool','-f','files.f'])
 add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','signed8_global_average_pool',
  '-Psigned8_global_average_pool.MAX_CHANNELS=64','-Psigned8_global_average_pool.MAX_PIXELS=65536',
  '-Psigned8_global_average_pool.TAG_W=32','-f','files.f'])
 add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','pooled_int4_classifier','-f','example/files.f'])
 for p in PROFILES:
  n=label(p);image=ROOT/'.work'/stamp/(n+'.vvp');vector=ROOT/'reports'/stamp/(n+'.txt')
  add('compile_'+n,[iv,'-g2012','-Wall','-s','tb_signed8_global_average_pool',
   *['-Ptb_signed8_global_average_pool.%s=%d'%(k,v) for k,v in zip(['C','P','T','EX'],p)],
   '-o',image,'-f','example/files.f','sim/tb_signed8_global_average_pool.sv'])
  add('sim_'+n,[vvp,image,'+vectors='+vector.as_posix()],
   'PASS signed8_global_average_pool C=%d P=%d T=%d EX=%d '%tuple(p))
 return checks
def prepare_plan():
 if PLAN.exists():raise RuntimeError('Existing finite plan; explicit review change required')
 if (ROOT/'reports').exists() and any((ROOT/'reports').iterdir()):raise RuntimeError('Existing execution; no automatic replanning')
 profiles=[]
 for p in PROFILES:
  data,counts=vectors(*p)
  profiles.append(dict(label=label(p),parameters=list(p),vector_sha256=hashlib.sha256(data.encode()).hexdigest(),vector_bytes=len(data.encode()),counts=counts))
 plan=dict(schema='anscore-b41-gap-finite-plan-v1',baseline_commit='31a83135a22f845d85840524986895217567625c',
  source_review='PENDING_A',expected_children=11,successful_simulations_if_pass=4,
  automatic_retry=False,fail_stop=True,numerical_planning_calls=4,archived_vector_generation_calls=4,
  executable_sources={n:digest(ROOT/n) for n in SOURCES},
  tools={str(BIN/n):digest(BIN/n) for n in ['iverilog.exe','vvp.exe']},profiles=profiles,
  checks=commands('<stamp>'),expected_checks=[x['name'] for x in commands('<stamp>')],
  scope='3 syntax + 4 compile/sim pairs; no inherited checks/synthesis/PnR/STA/board/PPA.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode())
 print(json.dumps(dict(plan=str(PLAN),sha256=digest(PLAN),profiles=profiles),indent=2))
def execute(spec,env,out):
 start=time.monotonic();stdout=stderr=b'';rec=dict(spec,cleanup=[])
 try:
  child=subprocess.Popen(spec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
   **({'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}))
 except OSError as exc:rec.update(status='NOT_RUN',returncode=None,error=repr(exc))
 else:
  try:
   stdout,stderr=child.communicate(timeout=20)
   rec.update(status='PASS' if child.returncode==0 else 'FAIL',returncode=child.returncode)
  except subprocess.TimeoutExpired as exc:
   rec.update(status='TIMEOUT');stdout,stderr=exc.stdout or b'',exc.stderr or b''
   try:
    if os.name=='nt':
     k=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F'],
      capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
     rec['cleanup'].append(dict(returncode=k.returncode,stdout=k.stdout.decode(errors='replace'),stderr=k.stderr.decode(errors='replace')))
    else:os.killpg(child.pid,signal.SIGKILL)
   except(OSError,subprocess.SubprocessError) as exc:rec['cleanup'].append(dict(error=repr(exc)))
   try:
    if child.poll() is None:child.kill()
    stdout,stderr=child.communicate(timeout=2)
   except(OSError,subprocess.SubprocessError) as exc:rec['cleanup'].append(dict(drain_error=repr(exc)))
   rec['returncode']=child.poll()
 if rec['status']=='PASS' and spec['marker']:
  if sum(s.startswith(spec['marker'].encode()) for s in stdout.splitlines())!=1 or b'$finish' not in stdout:
   rec['status']='FAIL_NO_MARKER'
 for stream,raw in [('stdout',stdout),('stderr',stderr)]:
  (out/(spec['name']+'.'+stream+'.txt')).write_bytes(raw);rec[stream+'_sha256']=hashlib.sha256(raw).hexdigest()
 rec['seconds']=round(time.monotonic()-start,4)
 if '-o' in spec['argv']:
  image=Path(spec['argv'][spec['argv'].index('-o')+1])
  if image.is_file():rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=digest(image))
 return rec
def main():
 if sys.argv[1:]==['--prepare-plan']:prepare_plan();return 0
 if sys.argv[1:]!=['--execute-approved-plan']:raise SystemExit('Use --prepare-plan or reviewed --execute-approved-plan')
 if (ROOT/'reports').exists() and any((ROOT/'reports').iterdir()):raise SystemExit('Existing execution; no automatic retry')
 plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_A'
 assert plan['checks']==commands('<stamp>') and plan['expected_checks']==[x['name'] for x in commands('<stamp>')]
 assert set(plan['executable_sources'])==set(SOURCES)
 assert all(digest(ROOT/n)==h for n,h in plan['executable_sources'].items())
 assert all(digest(Path(n))==h for n,h in plan['tools'].items())
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
 (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b41-gap-finite-v1',status='INCOMPLETE',source_sha256={},archived_sources={},profiles=[],checks=[],
  baseline_commit=plan['baseline_commit'],plan_sha256=digest(PLAN),tools=plan['tools'],automatic_retry=False,
  active_child=None,phase='SOURCE_ARCHIVE',archive_complete=False,preparation_completed_calls=0,suite_complete=False,
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
 def save():
  temporary=out/'results.json.tmp'
  with temporary.open('w',encoding='utf-8',newline='\n') as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
  temporary.replace(out/'results.json')
 save();stopped=False
 try:
  shutil.copyfile(PLAN,out/'plan.json')
  for n in SOURCES:
   source=(ROOT/n).resolve();target=out/'executed_inputs'/source.relative_to(REPO)
   target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
   report['source_sha256'][n]=digest(target);report['archived_sources'][n]=target.relative_to(ROOT).as_posix()
  report['archive_complete']=True;report['phase']='VECTOR_PREPARATION';save()
  for p,expected in zip(PROFILES,plan['profiles']):
   data,counts=vectors(*p);vector=out/(label(p)+'.txt');vector.write_bytes(data.encode());report['preparation_completed_calls']+=1
   assert digest(vector)==expected['vector_sha256'] and counts==expected['counts']
   report['profiles'].append(dict(expected,vector=vector.name));save()
  env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''))
  for spec in commands(stamp):
   assert all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n]) for n,h in report['source_sha256'].items())
   assert all(digest(out/p['vector'])==p['vector_sha256'] for p in report['profiles'])
   assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
   assert all(digest(Path(n))==h for n,h in report['tools'].items())
   report.update(active_child=spec['name'],phase='HDL_CHILD');save()
   rec=execute(spec,env,out)
   if rec['status']=='PASS' and spec['marker']:
    line=next(x for x in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if x.startswith(spec['marker']))
    rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
    profile=next(x for x in report['profiles'] if spec['name']=='sim_'+x['label']);counts=profile['counts']
    expected={k:counts[k] for k in ['frames','inputs','outputs','inexact','clips']};expected['iis']=counts['ii_checks'];expected['resets']=6
    if not all(rec['observed'].get(k)==v for k,v in expected.items()) or rec['observed'].get('holds',0)<1 or rec['observed'].get('rsp_holds',0)<1:
     rec.update(status='FAIL_COVERAGE',expected_coverage=expected)
   report['checks'].append(rec);report['active_child']=None;save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];stopped=True;break
  if not stopped:report['status']='PASS'
 except Exception:
  report.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
 finally:
  unchanged=report['archive_complete'] and all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n]) for n,h in report['source_sha256'].items())
  stable_vectors=all(digest(out/p['vector'])==p['vector_sha256'] for p in report['profiles'])
  stable_plan=digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  stable_tools=all(digest(Path(n))==h for n,h in report['tools'].items())
  sequence=[x['name'] for x in report['checks']]==plan['expected_checks']
  ok=report['status']=='PASS' and unchanged and stable_vectors and stable_plan and stable_tools and sequence
  if report['status']=='PASS' and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(sources_unchanged=unchanged,archive_unchanged=unchanged,vectors_unchanged=stable_vectors,
   plan_unchanged=stable_plan,tools_unchanged=stable_tools,check_sequence_matches=sequence,suite_complete=ok,
   phase='COMPLETE' if ok else 'STOPPED')
  report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED']
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete'] else 1
if __name__=='__main__':raise SystemExit(main())
