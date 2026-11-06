"""SPDX-License-Identifier: Apache-2.0. B39 exact finite plan, no retry/repair."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite';BIN=SUITE/'bin';PLAN=ROOT/'FINITE_PLAN.json'
PROFILES=[(1,1,1),(5,7,8),(32,65534,32)]
INPUTS=['rtl/moldudp64_recovery_manager.sv','example/recovering_itch_rx.sv',
 'sim/tb_moldudp64_recovery_manager.sv','sim/tb_recovering_itch_rx.sv',
 'reference_model.py','run_checks.py','files.f','example/files.f',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv']
TOOLS={name:BIN/(name+'.exe')for name in ['iverilog','vvp']}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def label(p):return 'n%d_k%d_t%d'%p
def commands(stamp):
 checks=[];iv=TOOLS['iverilog'];vvp=TOOLS['vvp']
 def add(name,args,marker=None):checks.append(dict(name=name,argv=list(map(str,args)),cwd=str(ROOT),marker=marker,hard_seconds=20,cleanup_seconds=7))
 add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','moldudp64_recovery_manager','-f','files.f'])
 add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','moldudp64_recovery_manager','-Pmoldudp64_recovery_manager.CONTEXTS=32','-Pmoldudp64_recovery_manager.REQUEST_MAX=65534','-Pmoldudp64_recovery_manager.TAG_W=32','-f','files.f'])
 add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','recovering_itch_rx','-f','example/files.f'])
 for p in PROFILES:
  name=label(p);image=ROOT/'.work'/stamp/(name+'.vvp');vector=ROOT/'reports'/stamp/(name+'.txt')
  add('compile_'+name,[iv,'-g2012','-Wall','-s','tb_moldudp64_recovery_manager',
   *['-Ptb_moldudp64_recovery_manager.%s=%d'%(n,v)for n,v in zip(['N','K','T'],p)],'-o',image,'-f','files.f','sim/tb_moldudp64_recovery_manager.sv'])
  add('sim_'+name,[vvp,image,'+vectors='+vector.as_posix()],'PASS moldudp64_recovery_manager N=%d K=%d T=%d '%p)
 image=ROOT/'.work'/stamp/'example.vvp'
 add('compile_example',[iv,'-g2012','-Wall','-s','tb_recovering_itch_rx','-o',image,'-f','example/files.f','sim/tb_recovering_itch_rx.sv'])
 add('sim_example',[vvp,image],'PASS recovering_itch_rx ')
 return checks
def write_plan():
 if (ROOT/'reports').exists()and any((ROOT/'reports').iterdir()):raise RuntimeError('Existing evidence; no replan')
 plan=dict(schema='anscore-b39-moldudp64-recovery-finite-plan-v1',baseline_commit='1e9e9130cef71127d2c8d2762affe815b067b9f5',
  source_review='PENDING_C_AND_ROOT',expected_children=11,successful_simulations_if_pass=4,fail_stop=True,automatic_retry=False,
  oracle_calls_before_archive=0,oracle_calls_after_archive=3,
  profiles=[dict(label=label(p),parameters=list(p))for p in PROFILES],
  source_sha256={name:digest(ROOT/name)for name in INPUTS},tool_sha256={name:digest(path)for name,path in TOOLS.items()},checks=commands('<stamp>'),
  example_expected=dict(configs=8,packets=15,retries=5,requests=6,request_bytes=139,events=1,completions=24,holds=131,blocked=131,resets=6),
  scope='Exactly three syntax and four compile/sim pairs; no synthesis/PnR/STA/board/legacy regressions')
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
 if (ROOT/'reports').exists()and any((ROOT/'reports').iterdir()):raise SystemExit('Existing started evidence; no automatic retry')
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False);(ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b39-moldudp64-recovery-checks-v1',status='INCOMPLETE',checks=[],profiles=[],
  source_sha256={},archived_sources={},tools={},plan_sha256=digest(PLAN),phase='PLAN_VALIDATION',active_child=None,
  archive_complete=False,oracle_completed_calls=0,suite_complete=False,automatic_retry=False,
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
 def save():
  temp=out/'results.json.tmp'
  with temp.open('w',encoding='utf-8',newline='\n')as file:json.dump(report,file,indent=2);file.write('\n');file.flush();os.fsync(file.fileno())
  temp.replace(out/'results.json')
 save();stopped=False;plan=None
 try:
  plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_C_AND_ROOT'
  assert plan['expected_children']==11 and plan['checks']==commands('<stamp>')
  assert set(plan['source_sha256'])==set(INPUTS)and set(plan['tool_sha256'])==set(TOOLS)
  assert all(digest(ROOT/n)==h for n,h in plan['source_sha256'].items())
  assert all(digest(TOOLS[n])==h for n,h in plan['tool_sha256'].items())
  assert plan['profiles']==[dict(label=label(p),parameters=list(p))for p in PROFILES]
  shutil.copyfile(PLAN,out/'plan.json');report['phase']='SOURCE_ARCHIVE';save()
  for name in INPUTS:
   source=(ROOT/name).resolve();target=out/'executed_inputs'/source.relative_to(REPO)
   target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
   report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
  report['tools']={n:dict(path=str(path),sha256=digest(path))for n,path in TOOLS.items()}
  report.update(archive_complete=True,phase='ORACLE_PREPARATION');save()
  spec=importlib.util.spec_from_file_location('b39_recovery_oracle',ROOT/'reference_model.py')
  oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
  for p in PROFILES:
   data,counts=oracle.vectors(*p);file=out/(label(p)+'.txt');file.write_bytes(data.encode('ascii'));report['oracle_completed_calls']+=1
   report['profiles'].append(dict(label=label(p),parameters=list(p),counts=counts,vector=file.name,vector_sha256=digest(file)));save()
  report['phase']='VECTORS_FROZEN';save()
  env=dict(os.environ);env['PATH']=os.pathsep.join([str(BIN),str(SUITE/'lib'),env.get('PATH','')])
  for child_spec in commands(stamp):
   assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
   assert all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n])for n,h in report['source_sha256'].items())
   assert all(digest(TOOLS[n])==h for n,h in plan['tool_sha256'].items())
   assert all(digest(out/p['vector'])==p['vector_sha256']for p in report['profiles'])
   report.update(phase='HDL_CHILD',active_child=child_spec);save();rec=execute(child_spec,env,out)
   if rec['status']=='PASS'and 'observed'in rec:
    if child_spec['name']=='sim_example':expected=plan['example_expected'];covered=True
    else:
     profile=next(p for p in report['profiles']if child_spec['name']=='sim_'+p['label']);counts=profile['counts']
     expected=dict(zip(['N','K','T'],profile['parameters']));expected.update(commands=2*(counts['commands']+3),
       holds=12*(counts['commands']+3),futures=counts['commands']+3,resets=counts['live_resets']+4,emits=counts['emits'])
     covered=rec['observed'].get('preoffers',0)>=6*expected['futures']
    if not covered or not all(rec['observed'].get(n)==v for n,v in expected.items()):rec.update(status='FAIL_COVERAGE',expected=expected)
   report['checks'].append(rec);report['active_child']=None;save();print(child_spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];stopped=True;break
  if not stopped:report['status']='PASS'
 except Exception:report.update(status='RUNNER_FAILED',exception=traceback.format_exc());stopped=True
 finally:
  source_ok=report['archive_complete']and all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n])for n,h in report['source_sha256'].items())
  vector_ok=report['oracle_completed_calls']==3 and all(digest(out/p['vector'])==p['vector_sha256']for p in report['profiles'])
  plan_ok=(out/'plan.json').is_file()and digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  tool_ok=len(report['tools'])==2 and all(digest(TOOLS[n])==rec['sha256']for n,rec in report['tools'].items())
  sequence_ok=plan is not None and [r['name']for r in report['checks']]==[c['name']for c in plan['checks']]
  ok=not stopped and report['status']=='PASS'and source_ok and vector_ok and plan_ok and tool_ok and sequence_ok
  if report['status']=='PASS'and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(sources_unchanged=source_ok,archived_sources_unchanged=source_ok,vectors_unchanged=vector_ok,
   plan_unchanged=plan_ok,tools_unchanged=tool_ok,exact_plan_executed=sequence_ok,suite_complete=ok,phase='COMPLETE'if ok else'STOPPED')
  report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete']else 1
if __name__=='__main__':sys.exit(main())
