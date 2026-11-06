"""SPDX-License-Identifier: Apache-2.0. B43 explicit finite plan; no oracle imports."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';PLAN=ROOT/'FINITE_PLAN.json'
PROFILES=[(1,1,False),(3,8,False),(128,32,False),(4,8,True)]
SOURCES=['rtl/ipv4_lpm_forward.sv','example/ipv4_two_route_forwarder.sv',
 'sim/tb_ipv4_lpm_forward.sv','sim/tb_ipv4_two_route_forwarder.sv','reference_model.py','prepare_vectors.py','run_checks.py',
 'files.f','example/files.f','README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes','manifest.json',
 '../../storage/ram_prefix_table/rtl/ram_prefix_table.sv','../../acceleration/operator_library/rtl/acc_ipv4_hdr_csum.v']

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def label(p):return 'example_t8' if p[2] else 'n%d_t%d'%p[:2]
def commands(stamp):
 iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe');out=ROOT/'reports'/stamp;checks=[]
 def add(name,argv,kind='HDL',marker=None):
  checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),kind=kind,marker=marker,timeout_seconds=20,tree_kill_seconds=5,drain_seconds=2))
 archived=out/'executed_inputs'/ROOT.relative_to(REPO)/'prepare_vectors.py'
 for p in PROFILES:
  n=label(p);add('prepare_'+n,[sys.executable,'-B',archived,'--routes',p[0],'--tag',p[1],
   *(['--example'] if p[2] else []),'--output',out/(n+'.txt')],'PREPARATION','PASS prepare_ipv4_lpm ')
 add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','ipv4_lpm_forward','-f','files.f'])
 add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','ipv4_lpm_forward',
  '-Pipv4_lpm_forward.ROUTES=128','-Pipv4_lpm_forward.TAG_W=32','-f','files.f'])
 add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','ipv4_two_route_forwarder','-f','example/files.f'])
 for p in PROFILES:
  n=label(p);image=ROOT/'.work'/stamp/(n+'.vvp');top='tb_ipv4_two_route_forwarder' if p[2] else 'tb_ipv4_lpm_forward'
  params=[] if p[2] else ['-P%s.N=%d'%(top,p[0]),'-P%s.T=%d'%(top,p[1])]
  add('compile_'+n,[iv,'-g2012','-Wall','-s',top,*params,'-o',image,'-f','example/files.f','sim/'+top+'.sv'])
  add('sim_'+n,[vvp,image,'+vectors='+(out/(n+'.txt')).as_posix()],marker=
   'PASS ipv4_two_route_forwarder ' if p[2] else 'PASS ipv4_lpm_forward N=%d T=%d '%p[:2])
 return checks

def freeze():
 if PLAN.exists() or (ROOT/'reports').exists():raise RuntimeError('Existing plan/execution; no automatic replanning')
 plan=dict(schema='anscore-b43-ipv4-lpm-finite-plan-v1',baseline_commit='98176a8f970354ebd6191d0370662ab35ff53664',
  source_review='PENDING_A',expected_hdl_children=11,expected_preparation_children=4,successful_simulations_if_pass=4,
  automatic_retry=False,fail_stop=True,numerical_planning_calls=0,archived_vector_generation_calls=4,
  executable_sources={n:digest(ROOT/n) for n in SOURCES},
  tools={str(t):digest(t) for t in [BIN/'iverilog.exe',BIN/'vvp.exe',Path(sys.executable)]},
  profiles=[dict(label=label(p),parameters=dict(routes=p[0],tag=p[1],example=p[2])) for p in PROFILES],checks=commands('<stamp>'),
  scope='Four isolated archived independent byte-string/LPM preparations;3 syntax+4 compile/simulation pairs. No old runner/model imports, inherited checks, synthesis/PnR/STA/board/PPA.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('FROZEN',digest(PLAN))

def child(spec,env,out):
 start=time.monotonic();stdout=stderr=b'';rec=dict(spec,cleanup=[])
 try:
  process=subprocess.Popen(spec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
   **({'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}))
 except OSError as exc:rec.update(status='NOT_RUN',returncode=None,error=repr(exc))
 else:
  try:
   stdout,stderr=process.communicate(timeout=20);rec.update(status='PASS' if process.returncode==0 else 'FAIL',returncode=process.returncode)
  except subprocess.TimeoutExpired as exc:
   rec.update(status='TIMEOUT');stdout,stderr=exc.stdout or b'',exc.stderr or b''
   try:
    if os.name=='nt':
     killed=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(process.pid),'/T','/F'],
      capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
     rec['cleanup'].append(dict(returncode=killed.returncode,stdout=killed.stdout.decode(errors='replace'),stderr=killed.stderr.decode(errors='replace')))
    else:os.killpg(process.pid,signal.SIGKILL)
   except(OSError,subprocess.SubprocessError) as exc:rec['cleanup'].append(dict(error=repr(exc)))
   try:
    if process.poll() is None:process.kill()
    stdout,stderr=process.communicate(timeout=2)
   except(OSError,subprocess.SubprocessError) as exc:rec['cleanup'].append(dict(drain_error=repr(exc)))
   rec['returncode']=process.poll()
 if rec['status']=='PASS' and spec['marker']:
  if sum(s.startswith(spec['marker'].encode()) for s in stdout.splitlines())!=1 or (spec['name'].startswith('sim_') and b'$finish' not in stdout):rec['status']='FAIL_NO_MARKER'
 for stream,raw in [('stdout',stdout),('stderr',stderr)]:
  (out/(spec['name']+'.'+stream+'.txt')).write_bytes(raw);rec[stream+'_sha256']=hashlib.sha256(raw).hexdigest()
 rec['seconds']=round(time.monotonic()-start,4)
 if '-o' in spec['argv']:
  image=Path(spec['argv'][spec['argv'].index('-o')+1])
  if image.is_file():rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=digest(image))
 return rec
def run():
 if (ROOT/'reports').exists():raise RuntimeError('Existing execution; separately reviewed finite followup required')
 plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_A'
 assert plan['checks']==commands('<stamp>') and set(plan['executable_sources'])==set(SOURCES)
 assert all(digest(ROOT/n)==h for n,h in plan['executable_sources'].items())
 assert all(digest(Path(n))==h for n,h in plan['tools'].items())
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
 (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b43-ipv4-lpm-finite-v1',status='INCOMPLETE',baseline_commit=plan['baseline_commit'],
  source_sha256={},archived_sources={},profiles=[],preparations=[],checks=[],plan_sha256=digest(PLAN),tools=plan['tools'],
  automatic_retry=False,active_child=None,archive_complete=False,suite_complete=False,planning_oracle_calls=0,
  numerical_preparation_calls=0,numerical_preparation_attempts=0,hardware='HW_UNVERIFIED',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN')
 def save():
  temporary=out/'results.json.tmp'
  with temporary.open('w',encoding='utf-8',newline='\n') as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
  temporary.replace(out/'results.json')
 def invariant():
  assert all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n]) for n,h in report['source_sha256'].items())
  assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  assert all(digest(Path(n))==h for n,h in report['tools'].items())
  assert all(digest(out/p['vector'])==p['vector_sha256'] and digest(out/p['summary'])==p['summary_sha256'] for p in report['profiles'])
  assert all(digest(ROOT/c['image'])==c['image_sha256'] for c in report['checks'] if 'image' in c)
 save()
 try:
  shutil.copyfile(PLAN,out/'plan.json')
  for n in SOURCES:
   source=(ROOT/n).resolve();target=out/'executed_inputs'/source.relative_to(REPO)
   target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
   report['source_sha256'][n]=digest(target);report['archived_sources'][n]=target.relative_to(ROOT).as_posix()
  report['archive_complete']=True;save()
  env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
  for spec in commands(stamp):
   invariant();report['active_child']=spec['name']
   if spec['kind']=='PREPARATION':report['numerical_preparation_attempts']+=1
   save()
   image_hash=digest(Path(spec['argv'][1])) if Path(spec['argv'][0]).stem.lower()=='vvp' else None
   rec=child(spec,env,out)
   if image_hash:rec['execution_image_sha256']=image_hash
   (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(rec)
   report['active_child']=None;save()  # Completed process is durable before parsing.
   if rec['status']=='PASS' and spec['kind']=='PREPARATION':
    report['numerical_preparation_calls']+=1;save()
    profile=next(x for x in plan['profiles'] if spec['name']=='prepare_'+x['label']);vector=out/(profile['label']+'.txt');summary=vector.with_suffix('.summary.json')
    data=json.loads(summary.read_bytes());assert data['parameters']==profile['parameters'] and digest(vector)==data['vector_sha256']
    assert data['oracle_imports']==1 and data['planning_oracle_calls']==0
    assert Path(data['oracle_source_path'])==out/'executed_inputs'/ROOT.relative_to(REPO)/'reference_model.py'
    assert data['oracle_source_sha256']==plan['executable_sources']['reference_model.py']
    report['profiles'].append(dict(label=profile['label'],**data,vector=vector.name,summary=summary.name,summary_sha256=digest(summary)))
   elif rec['status']=='PASS' and spec['name'].startswith('sim_'):
    line=next(x for x in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if x.startswith(spec['marker']))
    rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
    profile=next(p for p in report['profiles'] if spec['name']=='sim_'+p['label']);expected=profile['expected_runtime']
    if not all(rec['observed'].get(k)==v for k,v in expected.items()) or any(rec['observed'].get(k,0)<10 for k in ['holds','preoffers']):
     rec.update(status='FAIL_COVERAGE',expected_coverage=expected)
   save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];break
  else:report['status']='PASS'
 except Exception:
  report.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
 finally:
  try:invariant();unchanged=True
  except Exception:unchanged=False
  sequence=[x['name'] for x in report['preparations']+report['checks']]==[x['name'] for x in commands(stamp)]
  ok=report['status']=='PASS' and unchanged and sequence and report['archive_complete']
  if report['status']=='PASS' and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(inputs_unchanged=unchanged,check_sequence_matches=sequence,suite_complete=ok,
   maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED'])
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete'] else 1
if __name__=='__main__':
 if sys.argv[1:]==['--freeze-plan']:freeze()
 elif sys.argv[1:]==['--execute-approved-plan']:raise SystemExit(run())
 else:raise SystemExit('Use --freeze-plan or independently reviewed --execute-approved-plan')
