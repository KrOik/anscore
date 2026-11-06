"""B42 explicit timeout follow-up: unchanged golden records, bounded two-piece run."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,signal,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2];BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=ROOT/'REPAIR01_PLAN.json'
PARENT='reports/20261106T082646812505Z'
VECTOR=PARENT+'/ci64_co16_w1024_h1024_t32.txt'
SOURCES=['rtl/int4_subpixel_upsample2x.sv','example/rgb_subpixel8.sv','sim/tb_int4_subpixel_upsample2x.sv',
 'sim/tb_int4_subpixel_upsample2x_repair01.sv','reference_model.py','prepare_vectors.py','run_checks.py',
 'prepare_repair01_slices.py','run_repair01.py','REPAIR01_TB_PATCH.json','files.f','example/files.f',
 'README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes','manifest.json',
 '../int4_weight_matvec/rtl/int4_weight_matvec.sv','../int4_weight_matvec/rtl/deps/stream_requantize.v']
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def commands(stamp):
 out=ROOT/'reports'/stamp;image=ROOT/'.work'/stamp/'max_progress.vvp';top='tb_int4_subpixel_upsample2x_repair01';checks=[]
 def add(name,argv,kind,marker=None):checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),kind=kind,marker=marker,timeout_seconds=20,tree_kill_seconds=5,drain_seconds=2))
 archived=out/'executed_inputs'/ROOT.relative_to(REPO)/'prepare_repair01_slices.py'
 add('literal_slices',[sys.executable,'-B',archived,ROOT/VECTOR,out],'LITERAL_DATA_PREPARATION','PASS literal_subpixel_slices ')
 add('compile_repair_max',[BIN/'iverilog.exe','-g2012','-Wall','-s',top,
  *['-P%s.%s=%d'%(top,k,v) for k,v in zip(['CI','CO','W','H','T'],[64,16,1024,1024,32])],
  '-o',image,'-f','example/files.f','sim/tb_int4_subpixel_upsample2x_repair01.sv'],'HDL')
 for label in ['remaining25','fullrow']:
  add('sim_'+label,[BIN/'vvp.exe',image,'+vectors='+(out/(label+'.txt')).as_posix()],'HDL',
   'PASS int4_subpixel_upsample2x CI=64 CO=16 W=1024 H=1024 T=32 ')
 return checks
def freeze():
 assert not PLAN.exists() and not any((ROOT/'reports').glob('repair01_*'))
 parent=json.loads((ROOT/PARENT/'results.json').read_bytes())
 assert digest(ROOT/PARENT/'results.json')=='ff6f8273e7064903d97123a7f1f82dd8e5f9b347aeb3eec7003c9d8666a9b71d'
 assert parent['status']=='TIMEOUT' and len(parent['checks'])==9
 evidence={PARENT+'/results.json':digest(ROOT/PARENT/'results.json'),VECTOR:digest(ROOT/VECTOR),'FINITE_PLAN.json':digest(ROOT/'FINITE_PLAN.json')}
 evidence.update({row['image']:row['image_sha256'] for row in parent['checks'] if 'image' in row})
 plan=dict(schema='anscore-b42-subpixel-repair01-plan-v1',baseline_commit='2e7a6fb51f32e525c1026c28d1f2f45e36545ebc',
  source_review='PENDING_A',parent_evidence=evidence,source_sha256={n:digest(ROOT/n) for n in SOURCES},
  tools={str(p):digest(p) for p in [BIN/'iverilog.exe',BIN/'vvp.exe',Path(sys.executable)]},checks=commands('<stamp>'),
  expected_hdl_children=3,literal_preparation_children=1,new_oracle_calls=0,successful_simulations_if_pass=2,
  expected_original_counts=dict(frames=26,inputs=3693,outputs=67678,configs=3173),
  automatic_retry=False,fail_stop=True,
  scope='One literal source-vector record split,one instrumented maximum compile,two simulations: other25 original frames then intact fullrow17. Original RTL/TB/model/runner/vector unchanged. No successful old profile/syntax rerun. Progress-only copied TB; all old assertions remain. If either piece fails, stop; no further automatic split/retry or deadline increase.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('FROZEN_REPAIR01',digest(PLAN))
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
 assert not any((ROOT/'reports').glob('repair01_*')),'Explicit single attempt only'
 plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_A'
 assert plan['checks']==commands('<stamp>') and set(plan['source_sha256'])==set(SOURCES)
 for n,h in plan['source_sha256'].items():assert digest(ROOT/n)==h,n
 for n,h in plan['parent_evidence'].items():assert digest(ROOT/n)==h,n
 for n,h in plan['tools'].items():assert digest(Path(n))==h,n
 stamp='repair01_'+datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False);(ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b42-subpixel-repair01-v1',status='INCOMPLETE',plan_sha256=digest(PLAN),
  source_sha256={},archived_sources={},tools=plan['tools'],parent_evidence=plan['parent_evidence'],checks=[],preparations=[],profiles=[],
  new_oracle_calls=0,automatic_retry=False,archive_complete=False,active_child=None,suite_complete=False,hardware='HW_UNVERIFIED')
 def save():
  tmp=out/'results.json.tmp'
  with tmp.open('w',encoding='utf8',newline='\n') as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
  tmp.replace(out/'results.json')
 def invariant():
  assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  for n,h in report['source_sha256'].items():assert digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n]),n
  for n,h in report['parent_evidence'].items():assert digest(ROOT/n)==h,n
  for n,h in report['tools'].items():assert digest(Path(n))==h,n
  for p in report['profiles']:assert digest(out/p['vector'])==p['vector_sha256']
  if 'slice_summary_sha256' in report:assert digest(out/'slice_summary.json')==report['slice_summary_sha256']
  for row in report['checks']:
   if 'image' in row:assert digest(ROOT/row['image'])==row['image_sha256']
 save()
 try:
  shutil.copyfile(PLAN,out/'plan.json')
  for n in SOURCES:
   source=(ROOT/n).resolve();archive=out/'executed_inputs'/source.relative_to(REPO)
   archive.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,archive)
   report['source_sha256'][n]=digest(archive);report['archived_sources'][n]=archive.relative_to(ROOT).as_posix()
  report['archive_complete']=True;save()
  env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
  for spec in commands(stamp):
   invariant();report['active_child']=spec['name'];save();rec=child(spec,env,out)
   (report['checks'] if spec['kind']=='HDL' else report['preparations']).append(rec);report['active_child']=None;save()
   if rec['status']=='PASS' and spec['kind']=='LITERAL_DATA_PREPARATION':
    summary=json.loads((out/'slice_summary.json').read_bytes())
    assert all(summary['combined'][k]==v for k,v in plan['expected_original_counts'].items()) and summary['oracle_calls']==0
    report['profiles']=summary['parts'];report['slice_summary_sha256']=digest(out/'slice_summary.json')
   if rec['status']=='PASS' and spec['name'].startswith('sim_'):
    line=next(x for x in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if x.startswith(spec['marker']))
    rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
    counts=next(p['counts'] for p in report['profiles'] if spec['name']=='sim_'+p['label'])
    if not all(rec['observed'].get(k)==v for k,v in counts.items()) or rec['observed'].get('resets')!=6 or rec['observed'].get('futures')!=5 or rec['observed'].get('future_commands')!=counts['frames']+1 or any(rec['observed'].get(k,0)<1 for k in ['holds','rsp_holds','preoffers']):rec.update(status='FAIL_COVERAGE',expected_coverage=counts)
   if spec['name'].startswith('sim_'):rec['execution_image_sha256']=digest(Path(spec['argv'][1]))
   save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];break
  else:report['status']='PASS'
 except Exception:report.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
 finally:
  try:invariant();unchanged=True
  except Exception:unchanged=False
  sequence=[r['name'] for r in report['preparations']+report['checks']]==[s['name'] for s in commands(stamp)]
  ok=report['status']=='PASS' and unchanged and sequence and report['archive_complete']
  if report['status']=='PASS' and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(inputs_unchanged=unchanged,check_sequence_matches=sequence,suite_complete=ok)
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete'] else 1
if __name__=='__main__':
 if sys.argv[1:]==['--freeze-plan']:freeze()
 elif sys.argv[1:]==['--execute-approved-plan']:raise SystemExit(run())
 else:raise SystemExit('Use explicit reviewed REPAIR01 plan')
