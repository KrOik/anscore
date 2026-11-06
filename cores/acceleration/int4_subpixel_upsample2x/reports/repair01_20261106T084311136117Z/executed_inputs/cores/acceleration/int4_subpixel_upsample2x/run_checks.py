"""SPDX-License-Identifier: Apache-2.0. B42 explicit finite plan; no oracle imports."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';PLAN=ROOT/'FINITE_PLAN.json'
PROFILES=[(1,1,1,1,1),(9,3,7,5,8),(64,16,1024,1024,32)]
SOURCES=['rtl/int4_subpixel_upsample2x.sv','example/rgb_subpixel8.sv',
 'sim/tb_int4_subpixel_upsample2x.sv','reference_model.py','prepare_vectors.py','run_checks.py',
 'files.f','example/files.f','README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes','manifest.json',
 '../int4_weight_matvec/rtl/int4_weight_matvec.sv','../int4_weight_matvec/rtl/deps/stream_requantize.v']
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def label(p):return 'ci%d_co%d_w%d_h%d_t%d'%p
def commands(stamp):
 iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe');out=ROOT/'reports'/stamp;checks=[]
 def add(name,argv,kind,marker=None):
  checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),kind=kind,marker=marker,timeout_seconds=20,tree_kill_seconds=5,drain_seconds=2))
 archived=out/'executed_inputs'/ROOT.relative_to(REPO)/'prepare_vectors.py'
 for p in PROFILES:
  n=label(p);add('prepare_'+n,[sys.executable,'-B',archived,'--profile',','.join(map(str,p)),'--output',out/(n+'.txt')],'PREPARATION','PASS prepare_subpixel ')
 add('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','int4_subpixel_upsample2x','-f','files.f'],'HDL')
 add('syntax_maximum',[iv,'-g2012','-Wall','-tnull','-s','int4_subpixel_upsample2x',
  '-Pint4_subpixel_upsample2x.MAX_IN_CHANNELS=64','-Pint4_subpixel_upsample2x.MAX_OUT_CHANNELS=16',
  '-Pint4_subpixel_upsample2x.MAX_WIDTH=1024','-Pint4_subpixel_upsample2x.MAX_HEIGHT=1024',
  '-Pint4_subpixel_upsample2x.TAG_W=32','-f','files.f'],'HDL')
 add('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','rgb_subpixel8','-f','example/files.f'],'HDL')
 for p in PROFILES:
  n=label(p);image=ROOT/'.work'/stamp/(n+'.vvp')
  add('compile_'+n,[iv,'-g2012','-Wall','-s','tb_int4_subpixel_upsample2x',
   *['-Ptb_int4_subpixel_upsample2x.%s=%d'%(k,v) for k,v in zip(['CI','CO','W','H','T'],p)],
   '-o',image,'-f','example/files.f','sim/tb_int4_subpixel_upsample2x.sv'],'HDL')
  add('sim_'+n,[vvp,image,'+vectors='+(out/(n+'.txt')).as_posix()],'HDL',
   'PASS int4_subpixel_upsample2x CI=%d CO=%d W=%d H=%d T=%d '%p)
 return checks
def freeze():
 if PLAN.exists() or (ROOT/'reports').exists():raise RuntimeError('Existing plan/execution; no automatic replanning')
 plan=dict(schema='anscore-b42-subpixel-finite-plan-v1',baseline_commit='2e7a6fb51f32e525c1026c28d1f2f45e36545ebc',
  source_review='PENDING_A',expected_hdl_children=9,expected_preparation_children=3,successful_simulations_if_pass=3,
  automatic_retry=False,fail_stop=True,numerical_planning_calls=0,archived_vector_generation_calls=3,
  executable_sources={n:digest(ROOT/n) for n in SOURCES},
  tools={str(t):digest(t) for t in [BIN/'iverilog.exe',BIN/'vvp.exe',Path(sys.executable)]},
  profiles=[dict(label=label(p),parameters=list(p)) for p in PROFILES],checks=commands('<stamp>'),
  scope='Three archived independent integer preparations,3 syntax+3 compile/simulation pairs. No old runner/model, inherited checks, synthesis/PnR/STA/board/PPA.')
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
 if (ROOT/'reports').exists():raise RuntimeError('Existing execution; explicit separately reviewed repair required')
 plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_A'
 assert plan['checks']==commands('<stamp>') and set(plan['executable_sources'])==set(SOURCES)
 assert all(digest(ROOT/n)==h for n,h in plan['executable_sources'].items())
 assert all(digest(Path(n))==h for n,h in plan['tools'].items())
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
 (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b42-subpixel-finite-v1',status='INCOMPLETE',baseline_commit=plan['baseline_commit'],
  source_sha256={},archived_sources={},profiles=[],preparations=[],checks=[],plan_sha256=digest(PLAN),tools=plan['tools'],
  automatic_retry=False,active_child=None,archive_complete=False,suite_complete=False,hardware='HW_UNVERIFIED',
  synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN')
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
   invariant();report['active_child']=spec['name'];save();rec=child(spec,env,out)
   (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(rec)
   report['active_child']=None;save()
   if spec['kind']=='PREPARATION':
    if rec['status']=='PASS':
     profile=next(x for x in plan['profiles'] if spec['name']=='prepare_'+x['label']);vector=out/(profile['label']+'.txt');summary=vector.with_suffix('.summary.json')
     data=json.loads(summary.read_bytes());assert data['profile']==profile['parameters'] and digest(vector)==data['vector_sha256']
     report['profiles'].append(dict(profile,**data,vector=vector.name,summary=summary.name,summary_sha256=digest(summary)))
   else:
    if rec['status']=='PASS' and spec['name'].startswith('sim_'):
     line=next(x for x in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if x.startswith(spec['marker']))
     rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
     counts=next(p['counts'] for p in report['profiles'] if spec['name']=='sim_'+p['label'])
     if not all(rec['observed'].get(k)==v for k,v in counts.items()) or rec['observed'].get('resets')!=6 or rec['observed'].get('futures')!=5 or rec['observed'].get('future_commands')!=counts['frames']+1 or any(rec['observed'].get(k,0)<1 for k in ['holds','rsp_holds','preoffers']):rec.update(status='FAIL_COVERAGE',expected_coverage=counts)
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
