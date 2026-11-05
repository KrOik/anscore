"""Exactly one sealed finite matrix. Stop at the first failure or 20s timeout."""
from pathlib import Path
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile,time
P=Path(__file__).resolve().parent;R=P.parents[2]
SEAL=P/'SOURCE_SEAL.json';RECEIPT=P/'verification.json'
DEP='cores/acceleration/directed_reachability/rtl/directed_reachability.sv'
DEP_SHA='f2d80d7a1e72f0048a028449c8156f20353468465c1ea1ecdd2a5b84b2a198cf'
MARKER='dag_transitive_reduction_invalid_parameters__see_README'
FIELDS={'mode','N','T','frames','accepted','retired','first','resets','reset_offers','next','backend_rows','adj_reads','reach_reads','commits','result_reads','source_holds','output_holds','states','backend_states','cycles'}
OBS={'probe','state','backend','row','successor','bit','prefix','next','accepted'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def sources():
 return {p.relative_to(P).as_posix():sha(p) for p in sorted(P.rglob('*')) if p.is_file()
  and p not in (SEAL,RECEIPT) and p.relative_to(P).parts[0] not in ('reports','failure_archive') and '__pycache__' not in p.parts}
def tools():
 b=R/'tools/oss-cad-suite/oss-cad-suite/bin'
 return dict(python=r'C:\Program Files\Python312\python.exe',iverilog=str(b/'iverilog.exe'),vvp=str(b/'vvp.exe'))
def freeze():
 assert not SEAL.exists() and not RECEIPT.exists() and not (P/'reports').exists()
 plan=read(P/'TEST_PLAN.json');assert len(plan['children'])==28
 assert sha(R/DEP)==DEP_SHA
 write(SEAL,dict(schema=1,baseline=plan['baseline'],source_sha256=sources(),external_sha256={DEP:DEP_SHA},
  plan_sha256=sha(P/'TEST_PLAN.json'),children=plan['children'],tools_sha256={k:sha(Path(v)) for k,v in tools().items()},
  frozen_before_hdl=True,timeout_seconds=20,tree_timeout=True,first_failure_stops=True,automatic_retry=False))
 print('SEALED '+sha(SEAL))
def parse(line,fields):
 pairs=[x.split('=') for x in line.split()[1:]]
 assert len(pairs)==len(fields) and set(dict(pairs))==fields
 return {k:int(v,16 if k in ('states','backend_states') else 10) for k,v in pairs}
def summarize(command,stdout,plan):
 p=plan['profiles'][command['profile']];fixture=read(P/p['json']);mode=command['mode'];cs=fixture['cases'];ts=fixture['targets'];n=p['N']
 lines=stdout.splitlines();last=[x for x in lines if x.startswith('PASS ')];obs=[x for x in lines if x.startswith('OBS ')]
 assert len(last)==1
 assert all(x.startswith(('PASS ','OBS ')) or re.fullmatch(r'sim/tb_dag_transitive_reduction.sv:\d+: \$finish called at \d+ \(1ps\)',x) for x in lines)
 s=parse(last[0],FIELDS);observations=[parse(x,OBS) for x in obs]
 assert (s['mode'],s['N'],s['T'])==(mode,n,p['T']) and s['cycles']<=p['cycle_limit']
 if mode<2:
  assert not observations and s['frames']==len(cs) and s['accepted']==p['tokens'] and s['retired']==p['outputs'] and s['first']==len(cs)
  assert s['resets']==s['reset_offers']==s['next']==0
  good=[c for c in cs if not c['errors']]
  assert s['backend_rows']==n*sum(c['errors']!=1 for c in cs)
  assert s['adj_reads']==sum(sum(q['keep'] and q['u']<n and q['v']<n for q in c['tokens']) for c in cs)+n*len(good)
  assert s['reach_reads']==sum(sum(x.bit_count() for x in c['adjacency']) for c in good)
  assert s['commits']==s['result_reads']==n*len(good)
  assert s['states']==(0xffff if n>1 else 0xfcff)
  assert s['backend_states']==(0x1ffff if n>1 else 0x1fff3)
  assert s['source_holds']>0
  if mode==1:assert s['output_holds']>0
 else:
  assert len(observations)==len(ts)==s['resets']==s['frames'] and s['reset_offers']==3*len(ts)
  assert s['retired']==n*len(ts)+sum(t['prefix'] for t in ts)
  assert s['first']==len(ts)+sum(bool(t['held']) for t in ts)
  assert s['next']==sum(bool(t['held']) for t in ts)
  for index,(o,t) in enumerate(zip(observations,ts)):
   assert o['probe']==index and o['state']==t['state'] and o['prefix']==t['prefix'] and o['next']==bool(t['held'])
   assert 0<o['accepted']<=len(cs[t['owner']]['tokens'])
   if t['backend']>=0:assert o['backend']==t['backend']
   if t['state']==11:assert o['bit']==n//2
   if t['state']==12:assert o['row']==n//2
  assert s['accepted']==sum(o['accepted']+len(cs[t['fresh']]['tokens']) for o,t in zip(observations,ts))
 return dict(profile=p['name'],mode=mode,summary=s,observations=observations)
def validate_seal():
 f=read(SEAL);assert f['source_sha256']==sources() and f['external_sha256']=={DEP:sha(R/DEP)}=={DEP:DEP_SHA}
 assert f['plan_sha256']==sha(P/'TEST_PLAN.json') and f['children']==read(P/'TEST_PLAN.json')['children']
 assert f['tools_sha256']=={k:sha(Path(v)) for k,v in tools().items()}
 return f
def archive(tmp,receipt):
 a=P/'failure_archive/attempt_01';assert not a.exists()
 for name in [*receipt['source_sha256'],'SOURCE_SEAL.json','verification.json']:
  dest=a/'sources'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(P/name,dest)
 for src in (P/'reports').iterdir():
  dest=a/'reports'/src.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
 for src in tmp.iterdir():
  assert src.name in {f'p{i}.vvp' for i in range(5)} and src.is_file()
  dest=a/'artifacts'/src.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
 dest=a/'external/directed_reachability.sv';dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(R/DEP,dest)
 write(a/'ARCHIVE.json',dict(files_sha256={p.relative_to(a).as_posix():sha(p) for p in a.rglob('*') if p.is_file()},
  original_receipt_sha256=sha(RECEIPT),status=receipt['status'],no_retry=True,timeout_terminal=True))
def run(approved):
 f=validate_seal();assert approved==sha(SEAL)
 assert not RECEIPT.exists() and not (P/'reports').exists() and not (P/'failure_archive').exists()
 (P/'reports').mkdir();tmp=Path(tempfile.mkdtemp(prefix='b27-root-dag-',dir=R/'.git'))
 paths=tools();exp={**paths,'{TMP}':tmp.as_posix()};plan=read(P/'TEST_PLAN.json')
 receipt=dict(status='IN_PROGRESS',hardware='HW_UNVERIFIED',baseline=plan['baseline'],source_sha256=sources(),
  external_sha256=f['external_sha256'],source_seal_sha256=sha(SEAL),plan_sha256=sha(P/'TEST_PLAN.json'),
  path_expansion=exp,timeout_seconds=20,terminal_timeout=False,automatic_retry=False,
  records=[dict(name=c['name'],status='NOT_RUN') for c in plan['children']],results=[])
 env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1'
 b=R/'tools/oss-cad-suite/oss-cad-suite';env['PATH']=str(b/'bin')+os.pathsep+str(b/'lib')+os.pathsep+env.get('PATH','')
 write(RECEIPT,receipt);can_cleanup=False
 try:
  for index,c in enumerate(plan['children']):
   argv=[paths.get(x,x).replace('{TMP}',tmp.as_posix()) for x in c['argv']]
   rec=dict(name=c['name'],argv=argv,status='RUNNING',timeout_seconds=20);receipt['records'][index]=rec;write(RECEIPT,receipt)
   start=time.monotonic();kwargs=dict(executable=argv[0],cwd=P,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
   if os.name=='nt':kwargs['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
   else:kwargs['start_new_session']=True
   child=subprocess.Popen(argv,**kwargs)
   try:out,err=child.communicate(timeout=20)
   except subprocess.TimeoutExpired as timeout:
    receipt['terminal_timeout']=True
    out,err=timeout.stdout or b'',timeout.stderr or b''
    try:
     if os.name=='nt':
      killer=str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe');kill_argv=[killer,'/PID',str(child.pid),'/T','/F']
      killed=subprocess.run(kill_argv,executable=killer,capture_output=True,timeout=5)
      rec['tree_termination']=dict(argv=kill_argv,returncode=killed.returncode,stdout_raw_hex=killed.stdout.hex(),stderr_raw_hex=killed.stderr.hex())
     else:os.killpg(child.pid,9)
    except Exception as cleanup_error:
     rec['tree_cleanup_error']=dict(type=type(cleanup_error).__name__,message=str(cleanup_error))
     if isinstance(cleanup_error,subprocess.TimeoutExpired):
      rec['tree_cleanup_error'].update(stdout_raw_hex=(cleanup_error.stdout or b'').hex(),stderr_raw_hex=(cleanup_error.stderr or b'').hex())
     try:child.kill()
     except Exception as direct_error:rec['direct_cleanup_error']=str(direct_error)
    try:out,err=child.communicate(timeout=5)
    except subprocess.TimeoutExpired as drain:
     rec['drain_timeout']=True;out,err=drain.stdout or out,drain.stderr or err
    rec['status']='TIMEOUT'
   for stream,data in [('stdout',out),('stderr',err)]:
    path=P/'reports'/f'{index:02d}_{c["name"]}.{stream}';path.write_bytes(data)
    rec[stream]=path.relative_to(P).as_posix();rec[stream+'_sha256']=sha(path)
   rec.update(returncode=child.returncode,elapsed_seconds=time.monotonic()-start)
   if rec['status']=='TIMEOUT':write(RECEIPT,receipt);raise TimeoutError('terminal 20s process-tree limit')
   rec['status']='OBSERVED';write(RECEIPT,receipt)
   if c['kind']=='reject':assert child.returncode>0 and MARKER.encode() in out+err
   else:
    assert child.returncode==0
    if c['kind']!='version':assert not err
    if c['kind']=='simulation':receipt['results'].append(summarize(c,out.decode('utf-8'),plan))
    elif c['kind']=='oracle':assert out.decode('utf-8').strip()=='PASS fixed BFS edge-deletion certificates profiles=5'
    elif c['kind']!='version':assert not out
   rec['status']='PASS'
   if c['kind']=='compile':rec['artifact_sha256']=sha(tmp/f'p{c["profile"]}.vvp')
   write(RECEIPT,receipt)
  assert sources()==f['source_sha256'] and sha(R/DEP)==DEP_SHA
  receipt['status']='UNIT_SIM_PASS';receipt['max_child_seconds']=max(r['elapsed_seconds'] for r in receipt['records'])
  receipt['totals']=plan['totals'];write(RECEIPT,receipt)
  can_cleanup=True
  print('UNIT_SIM_PASS children=28 simulations=15')
 except Exception as error:
  receipt['status']='TIMEOUT_TERMINAL' if receipt['terminal_timeout'] else 'FAIL_STOPPED'
  receipt['failure']=dict(type=type(error).__name__,message=str(error))
  write(RECEIPT,receipt);archive(tmp,receipt);can_cleanup=True;raise
 finally:
  assert tmp.resolve().parent==(R/'.git').resolve() and tmp.name.startswith('b27-root-dag-')
  if can_cleanup:
   for path in tmp.iterdir():
    assert path.name in {f'p{i}.vvp' for i in range(5)} and path.is_file() and not path.is_symlink();path.unlink()
   tmp.rmdir()
def check():
 f=validate_seal();r=read(RECEIPT);p=read(P/'TEST_PLAN.json')
 assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and r['source_sha256']==f['source_sha256']
 assert r['source_seal_sha256']==sha(SEAL) and r['external_sha256']==f['external_sha256']
 assert len(r['records'])==28 and len(r['results'])==15
 actual=[];streams=set()
 for c,rec in zip(p['children'],r['records']):
  assert rec['name']==c['name'] and rec['status']=='PASS' and rec['elapsed_seconds']<20
  assert rec['argv']==[r['path_expansion'].get(x,x).replace('{TMP}',r['path_expansion']['{TMP}']) for x in c['argv']]
  for k in ('stdout','stderr'):assert sha(P/rec[k])==rec[k+'_sha256'];streams.add(rec[k])
  out=(P/rec['stdout']).read_bytes();err=(P/rec['stderr']).read_bytes()
  if c['kind']=='reject':assert rec['returncode']>0 and MARKER.encode() in out+err
  else:
   assert rec['returncode']==0
   if c['kind']!='version':assert not err
  if c['kind']=='simulation':actual.append(summarize(c,out.decode('utf-8'),p))
 assert actual==r['results']
 assert streams=={p.relative_to(P).as_posix() for p in (P/'reports').iterdir() if p.is_file()}
 print('CHECK PASS read-only children=28 simulations=15')
if __name__=='__main__':
 a=argparse.ArgumentParser();g=a.add_mutually_exclusive_group(required=True)
 g.add_argument('--seal',action='store_true');g.add_argument('--run',action='store_true');g.add_argument('--check',action='store_true');a.add_argument('--approved-seal');x=a.parse_args()
 if x.seal:freeze()
 elif x.run:run(x.approved_seal)
 else:check()
