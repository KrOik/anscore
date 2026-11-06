"""SPDX-License-Identifier: Apache-2.0. B41 frozen fail-stop finite plan."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
SUITE=REPO/'tools/oss-cad-suite/oss-cad-suite';BIN=SUITE/'bin';PLAN=ROOT/'FINITE_PLAN.json'
PROFILES=[(1,1),(7,8),(64,32)]
INPUTS=['rtl/trade_correction_ohlcv_state.sv','example/itch_execution_statistics8.sv',
 'sim/tb_trade_correction_ohlcv_state.sv','sim/tb_itch_execution_statistics8.sv',
 'reference_model.py','run_checks.py','files.f','example/files.f',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../itch_order_state/rtl/itch_order_state.sv','../ram_hash_table/rtl/ram_hash_table.sv',
 'README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes']
TOOLS={name:BIN/(name+'.exe')for name in ['iverilog','vvp']}
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def label(p):return 'n%d_t%d'%p
def commands(stamp):
 checks=[];iv=TOOLS['iverilog'];vvp=TOOLS['vvp']
 def add(name,args,marker=None):checks.append(dict(name=name,argv=list(map(str,args)),cwd=str(ROOT),marker=marker,hard_seconds=20,cleanup_seconds=7))
 add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','trade_correction_ohlcv_state','-f','files.f'])
 add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','trade_correction_ohlcv_state','-Ptrade_correction_ohlcv_state.ENTRIES=64','-Ptrade_correction_ohlcv_state.TAG_W=32','-f','files.f'])
 add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','itch_execution_statistics8','-f','example/files.f'])
 for p in PROFILES:
  name=label(p);image=ROOT/'.work'/stamp/(name+'.vvp');vector=ROOT/'reports'/stamp/(name+'.txt')
  add('compile_'+name,[iv,'-g2012','-Wall','-s','tb_trade_correction_ohlcv_state',
   *['-Ptb_trade_correction_ohlcv_state.%s=%d'%(n,v)for n,v in zip(['N','T'],p)],'-o',image,'-f','files.f','sim/tb_trade_correction_ohlcv_state.sv'])
  add('sim_'+name,[vvp,image,'+vectors='+vector.as_posix()],'PASS trade_correction_ohlcv_state N=%d T=%d '%p)
 image=ROOT/'.work'/stamp/'example.vvp'
 add('compile_example',[iv,'-g2012','-Wall','-s','tb_itch_execution_statistics8','-o',image,'-f','example/files.f','sim/tb_itch_execution_statistics8.sv'])
 add('sim_example',[vvp,image],'PASS itch_execution_statistics8 ')
 return checks
def write_plan():
 if (ROOT/'reports').exists()and any((ROOT/'reports').iterdir()):raise RuntimeError('Existing evidence; no replan')
 plan=dict(schema='anscore-b41-trade-correction-ohlcv-state-finite-plan-v1',baseline_commit='31a83135a22f845d85840524986895217567625c',
  source_review='PENDING_C_AND_ROOT',expected_children=11,successful_simulations_if_pass=4,fail_stop=True,automatic_retry=False,
  numerical_planning_calls=0,oracle_calls_before_archive=0,oracle_calls_after_archive=3,
  profiles=[dict(label=label(p),parameters=list(p))for p in PROFILES],
  source_sha256={name:digest(ROOT/name)for name in INPUTS},tool_sha256={name:digest(path)for name,path in TOOLS.items()},checks=commands('<stamp>'),
  example_expected=dict(accepted=89,checked=84,futures=42,holds=507,blocked=252,resets=6,cancelled=5,event_results=21,trade_adds=12,isolated_results=3),
  scope='Exactly three syntax and four compile/sim pairs; no synthesis/PnR/STA/board/PPA/inherited regressions')
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
 report=dict(schema='anscore-b41-trade-correction-ohlcv-state-checks-v1',status='INCOMPLETE',checks=[],profiles=[],
  source_sha256={},archived_sources={},tools={},plan_sha256=digest(PLAN),phase='PLAN_VALIDATION',active_child=None,
  archive_complete=False,oracle_completed_calls=0,suite_complete=False,automatic_retry=False,
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
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
  spec=importlib.util.spec_from_file_location('b41_trade_oracle',ROOT/'reference_model.py')
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
     profile=next(p for p in report['profiles']if child_spec['name']=='sim_'+p['label']);counts=profile['counts'];checked=2*(counts['commands']+10)
     expected=dict(zip(['N','T'],profile['parameters']));expected.update(accepted=checked+5,checked=checked,
       holds=12*(counts['commands']+10)+3,futures=counts['commands']+10,resets=counts['live_resets']+6,cancelled=5)
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
