"""Finite record-first runner. Planning hashes only; no oracle imports here."""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
TOOLS={'iverilog':BIN/'iverilog.exe','vvp':BIN/'vvp.exe','python':Path(sys.executable)}
BASELINE='98176a8f970354ebd6191d0370662ab35ff53664'
PLAN=ROOT/'FINITE_PLAN.json'
INPUTS=['rtl/watermark_event_merge.sv','example/dual_itch_time_merge.sv',
 'sim/tb_watermark_event_merge.sv','sim/tb_dual_itch_time_merge.sv',
 'reference_model.py','prepare_vectors.py','run_checks.py','files.f','example/files.f',
 'README.md','ARCHITECTURE.md','SOURCES.md','LICENSE','.gitattributes',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../ram_deadline_scheduler/rtl/ram_deadline_scheduler.sv',
 '../../communication/moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv']
PROFILES=[dict(label='f1_d8_t1',parameters=[1,8,1]),dict(label='f3_d128_t8',parameters=[3,128,8]),dict(label='f8_d512_t32',parameters=[8,512,32])]
EXAMPLE_EXPECTED=dict(packets=9,events=7,admins=10,resets=4,futures=2,cancelled=1)

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def commands(stamp):
 out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp;checks=[]
 def add(name,argv,kind='HDL',marker=None):checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT),kind=kind,marker=marker,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2))
 archived=out/'executed_inputs'/ROOT.relative_to(REPO)
 for p in PROFILES:add('prepare_'+p['label'],[TOOLS['python'],'-B',archived/'prepare_vectors.py','--profile',','.join(map(str,p['parameters'])),'--output',out/(p['label']+'.txt')],'PREPARATION','PASS watermark_event_vectors ')
 add('syntax_default',[TOOLS['iverilog'],'-g2012','-Wall','-tnull','-s','watermark_event_merge','-f','files.f'])
 add('syntax_maximum',[TOOLS['iverilog'],'-g2012','-Wall','-tnull','-s','watermark_event_merge','-Pwatermark_event_merge.FEEDS=8','-Pwatermark_event_merge.DATA_W=512','-Pwatermark_event_merge.TAG_W=32','-f','files.f'])
 add('syntax_example',[TOOLS['iverilog'],'-g2012','-Wall','-tnull','-s','dual_itch_time_merge','-f','example/files.f'])
 for p in PROFILES:
  f,d,t=p['parameters'];image=work/(p['label']+'.vvp')
  add('compile_'+p['label'],[TOOLS['iverilog'],'-g2012','-Wall','-s','tb_watermark_event_merge',f'-Ptb_watermark_event_merge.F={f}',f'-Ptb_watermark_event_merge.D={d}',f'-Ptb_watermark_event_merge.T={t}','-o',image,'-f','files.f','sim/tb_watermark_event_merge.sv'])
  add('sim_'+p['label'],[TOOLS['vvp'],image,'+vectors='+(out/(p['label']+'.txt')).as_posix()],marker=f'PASS watermark_event_merge F={f} D={d} T={t} ')
 image=work/'example.vvp'
 add('compile_example',[TOOLS['iverilog'],'-g2012','-Wall','-s','tb_dual_itch_time_merge','-o',image,'-f','example/files.f','sim/tb_dual_itch_time_merge.sv'])
 add('sim_example',[TOOLS['vvp'],image],marker='PASS dual_itch_time_merge ')
 return checks

def write_plan():
 assert not list((ROOT/'reports').glob('*/results.json')),'Execution already started; no planning rewrite'
 plan=dict(schema='anscore-b43-watermark-event-merge-plan-v1',baseline_commit=BASELINE,source_review='PENDING_C_AND_ROOT',
  expected_hdl_children=11,expected_preparation_children=3,successful_simulations_if_pass=4,
  numerical_planning_calls=0,archived_oracle_preparation_children=3,automatic_retry=False,fail_stop=True,
  source_sha256={n:digest(ROOT/n) for n in INPUTS},tool_sha256={n:digest(p) for n,p in TOOLS.items()},
  profiles=PROFILES,checks=commands('<stamp>'),example_expected=EXAMPLE_EXPECTED,example_minimum_holds=30,
  scope='Three independent archived preparation children;3 syntax+4 compile/sim pairs. No old runner/model/checker imports, inherited regression, synthesis/PnR/STA/board/PPA or cleanup.')
 PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('PENDING_PLAN_SHA256',digest(PLAN))

def execute(spec,env,out):
 start=time.monotonic();cleanup=[];status='PASS';returncode=None;stdout=b'';stderr=b'';pid=None
 child=None;capture_complete=False;capture_error=None;drain_failed=False
 try:
  child=subprocess.Popen(spec['argv'],cwd=spec['cwd'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
   **({'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}))
  pid=child.pid
  try:
   stdout,stderr=child.communicate(timeout=spec['hard_seconds']);capture_complete=True
  except subprocess.TimeoutExpired as expired:
   status='TIMEOUT';stdout=expired.output or b'';stderr=expired.stderr or b''
  except Exception:
   status='CAPTURE_FAILED';capture_error=traceback.format_exc()
 except Exception:
  status='SPAWN_FAILED';capture_error=traceback.format_exc()
 finally:
  if child is not None:
   # Every acquired process reaches the same bounded cleanup, including a
   # non-Timeout communicate exception. Exactly one tree-kill and one drain.
   if not capture_complete:
    helper_out=helper_err=b'';entry=dict(kind='TREE_TERMINATION',hard_seconds=spec['tree_kill_seconds'])
    try:
     if os.name=='nt':
      killed=subprocess.run([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),'/PID',str(pid),'/T','/F'],
       capture_output=True,timeout=spec['tree_kill_seconds'],creationflags=subprocess.CREATE_NO_WINDOW)
      helper_out,helper_err=killed.stdout,killed.stderr;entry['returncode']=killed.returncode
     else:
      import signal
      os.killpg(pid,signal.SIGKILL);entry['returncode']=0
    except subprocess.TimeoutExpired as expired:
     helper_out,helper_err=expired.output or b'',expired.stderr or b'';entry['error']='TREE_KILL_TIMEOUT'
    except Exception as e:entry['error']=repr(e)
    for stream,raw in [('stdout',helper_out),('stderr',helper_err)]:
     path=out/(spec['name']+'.taskkill.'+stream+'.txt')
     try:
      path.write_bytes(raw);entry[stream+'_path']=path.name;entry[stream+'_sha256']=hashlib.sha256(raw).hexdigest()
     except Exception as e:entry[stream+'_archive_error']=repr(e)
    cleanup.append(entry)
    try:
     if child.poll() is None:child.kill() # Direct-parent fallback adds no wait budget.
    except Exception as e:cleanup.append(dict(kind='DIRECT_KILL',error=repr(e)))
    try:
     stdout,stderr=child.communicate(timeout=spec['drain_seconds']);capture_complete=True
    except subprocess.TimeoutExpired as expired:
     stdout=expired.output or stdout;stderr=expired.stderr or stderr;drain_failed=True
     cleanup.append(dict(kind='PIPE_DRAIN',hard_seconds=spec['drain_seconds'],error='DRAIN_TIMEOUT'))
    except Exception as e:
     drain_failed=True;cleanup.append(dict(kind='PIPE_DRAIN',hard_seconds=spec['drain_seconds'],error=repr(e)))
   for stream in [child.stdout,child.stderr]:
    if stream is not None and not stream.closed:
     try:
      if drain_failed:os.close(stream.fileno()) # No second communicate/join wait.
      else:stream.close()
     except Exception as e:cleanup.append(dict(kind='PIPE_CLOSE',error=repr(e)))
   returncode=child.poll()
   if returncode is None:cleanup.append(dict(kind='CHILD_STATE',error='TERMINATION_UNCONFIRMED'))
   if status=='PASS' and returncode!=0:status='FAIL'
 (out/(spec['name']+'.stdout.txt')).write_bytes(stdout)
 (out/(spec['name']+'.stderr.txt')).write_bytes(stderr)
 if status=='PASS' and spec['marker'] and spec['marker'].encode() not in stdout:status='FAIL_MARKER'
 return dict(spec,status=status,returncode=returncode,pid=pid,cleanup=cleanup,output_capture_complete=capture_complete,capture_error=capture_error,
  stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest(),seconds=round(time.monotonic()-start,3))

def run():
 assert not list((ROOT/'reports').glob('*/results.json')),'One-attempt guard: retain prior evidence; separate reviewed repair required'
 plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_C_AND_ROOT'
 assert plan['checks']==commands('<stamp>') and plan['profiles']==PROFILES
 assert plan['source_sha256']=={n:digest(ROOT/n) for n in INPUTS}
 assert plan['tool_sha256']=={n:digest(path) for n,path in TOOLS.items()}
 stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
 out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False);work=ROOT/'.work'/stamp;work.mkdir(parents=True,exist_ok=False)
 report=dict(schema='anscore-b43-watermark-event-merge-checks-v1',status='INCOMPLETE',baseline_commit=BASELINE,
  plan_sha256=digest(PLAN),source_sha256={},archived_sources={},tools={n:dict(path=str(p),sha256=digest(p)) for n,p in TOOLS.items()},
  profiles=[],preparations=[],checks=[],archive_complete=False,active_child=None,automatic_retry=False,suite_complete=False,
  numerical_planning_calls=0,oracle_completed_children=0,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
 def save():
  temporary=out/'results.json.tmp'
  with temporary.open('w',encoding='utf-8',newline='\n') as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
  temporary.replace(out/'results.json')
 def invariant():
  assert report['archive_complete']
  assert all(digest(ROOT/n)==h==digest(ROOT/report['archived_sources'][n]) for n,h in report['source_sha256'].items())
  assert digest(PLAN)==report['plan_sha256']==digest(out/'plan.json')
  assert all(digest(Path(v['path']))==v['sha256'] for v in report['tools'].values())
  assert all(digest(out/p['vector'])==p['vector_sha256'] and digest(out/p['summary'])==p['summary_sha256'] for p in report['profiles'])
  assert all(digest(ROOT/c['image'])==c['image_sha256'] for c in report['checks'] if 'image' in c)
 save()
 try:
  (out/'plan.json').write_bytes(PLAN.read_bytes())
  for n in INPUTS:
   source=(ROOT/n).resolve();target=out/'executed_inputs'/source.relative_to(REPO)
   if target.name=='.gitattributes':target=target.with_name('.gitattributes.executed.txt')
   target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes())
   report['source_sha256'][n]=digest(target);report['archived_sources'][n]=target.relative_to(ROOT).as_posix()
  report['archive_complete']=True;save()
  env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
  for spec in commands(stamp):
   invariant();report['active_child']=spec['name'];save();rec=execute(spec,env,out)
   (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(rec)
   report['active_child']=None;save() # Completed-child evidence precedes any post-processing.
   if spec['kind']=='PREPARATION' and rec['status']=='PASS':
    p=next(v for v in PROFILES if spec['name']=='prepare_'+v['label']);summary=out/(p['label']+'.summary.json');data=json.loads(summary.read_bytes());vector=out/(p['label']+'.txt')
    assert data['profile']==p['parameters'] and digest(vector)==data['vector_sha256'] and vector.stat().st_size==data['vector_bytes']
    report['profiles'].append(dict(p,**data,vector=vector.name,summary=summary.name,summary_sha256=digest(summary)))
    report['oracle_completed_children']+=1
   if spec['kind']=='HDL' and rec['status']=='PASS' and spec['name'].startswith('compile_'):
    image=Path(spec['argv'][spec['argv'].index('-o')+1]);rec.update(image=image.relative_to(ROOT).as_posix(),image_sha256=digest(image))
   if spec['name'].startswith('sim_'):
    rec['execution_image_sha256']=digest(Path(spec['argv'][1]))
    if rec['status']=='PASS':
     line=next(s for s in (out/(spec['name']+'.stdout.txt')).read_text().splitlines() if s.startswith(spec['marker']))
     rec['observed']={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',line)}
     if spec['name']=='sim_example':covered=all(rec['observed'].get(k)==v for k,v in EXAMPLE_EXPECTED.items()) and rec['observed'].get('holds',0)>=30
     else:
      p=next(v for v in report['profiles'] if spec['name']=='sim_'+v['label']);c=p['counts'];f,d,t=p['parameters']
      expected=dict(F=f,D=d,T=t,commands=c['commands'],holds=6*c['commands'],preoffers=c['expected_preoffers'],future_gets=c['future_gets'],resets=c['live_resets']+1)
      covered=all(rec['observed'].get(k)==v for k,v in expected.items()) and c['live_resets']==5 and c['future_gets']>=180
     if not covered:rec['status']='FAIL_COVERAGE'
   save();print(spec['name'],rec['status'],flush=True)
   if rec['status']!='PASS':report['status']=rec['status'];break
  else:report['status']='PASS'
 except Exception:report.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
 finally:
  try:invariant();unchanged=True
  except Exception:unchanged=False
  sequence=[v['name'] for v in report['preparations']+report['checks']]==[v['name'] for v in commands(stamp)]
  complete=report['status']=='PASS' and unchanged and sequence and report['oracle_completed_children']==3
  if report['status']=='PASS' and not complete:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
  report.update(inputs_unchanged=unchanged,exact_plan_executed=sequence,suite_complete=complete,
   maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if complete else ['RTL_CANDIDATE','HW_UNVERIFIED'])
  save();print(out.relative_to(ROOT).as_posix(),flush=True)
 return 0 if report['suite_complete'] else 1

if __name__=='__main__':
 if sys.argv[1:]==['--write-plan']:write_plan()
 elif sys.argv[1:]==['--execute-approved-plan']:raise SystemExit(run())
 else:raise SystemExit('Use --write-plan or independently reviewed --execute-approved-plan')
