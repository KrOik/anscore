"""One separately approved A gate, complete runtime pre/post, nested Job20."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
R=Path(__file__).resolve().parent.parent
P=R/'cores/storage/ram_range_min_index'
A='474202814626d9cf7f9ad1dddc3a9e2802e6006557257bed6426816a116e143e'
S='8aff538286c1f53da328e77bc8559751cb98733f3cafdf9c36fc04539dff154a'
PP='28ad33540f2cce30461247d1d8b7d4f46727f4540ddaee713c489207c68c4fee'
INPUTS={
 'TOOL_INVENTORY.json':('cores/signal_processing/exact_1d_transport/TOOL_INVENTORY.json','9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b'),
 'tool_runtime.py':('cores/signal_processing/exact_1d_transport/sim/runtime.py','7419e696ad10d1f4e8daca7e4fed45f5e4517e7db7a8f27f88441913de65f3f2'),
 'tree_process.py':('cores/acceleration/exact_undirected_steiner_tree/tree_process.py','4e72238dd4ad0836df7a614914e67a5e57cf871cb60fe0b0251a85b2e6f71a2a')}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d,exclusive=False):
 with p.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as f:f.write(json.dumps(d,indent=2)+'\n')
def local(n):
 assert n and not any(c in n for c in ('\\',':','\0','\n','\r'))
 p=(R/n).resolve();assert p.is_relative_to(R) and not p.is_symlink();return p
def inventory(p):return {f.relative_to(p).as_posix():sha(f) for f in p.rglob('*') if f.is_file()}
def load(p,n):
 spec=importlib.util.spec_from_file_location('b30_a_outer_'+n,p/(n+'.py'));assert spec and spec.loader
 m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
def main(ap,expected):
 assert os.name=='nt' and sha(Path(__file__))==expected
 ap=ap.resolve();assert ap.is_relative_to(R/'.git');H=sha(ap);approval=read(ap)
 required=dict(schema='b30-a-prepare-once-v1',approved_by='root',author_sha256=A,author_seal_sha256=S,
  preparation_plan_sha256=PP,max_invocations=1,hard_seconds=20,automatic_retry=False,
  outer_launcher_sha256=expected,outer_runtime_inputs={k:dict(path=v[0],sha256=v[1]) for k,v in INPUTS.items()})
 assert all(approval.get(k)==v for k,v in required.items())
 reviews=approval['independent_reviews'];assert len(reviews)>=3
 def review_guard():
  for n,h in reviews.items():assert local(n).is_relative_to(R/'.git') and sha(local(n))==h
 review_guard()
 assert sha(P/'AUTHOR_INPUTS.json')==A and sha(P/'AUTHOR_SEAL.json')==S and sha(P/'PREPARATION_PLAN.json')==PP
 own={**read(P/'AUTHOR_INPUTS.json')['sources'],'AUTHOR_INPUTS.json':A,'AUTHOR_SEAL.json':S}
 assert inventory(P)==own and len(own)==26
 assert not (P/'prepared').exists() and not (P/'preparation_evidence').exists() and not (P/'SOURCE_SEAL.json').exists()
 context=approval['execution_context'];assert context['approval_path']==str(ap)
 assert context['original_package_root']==str(P) and context['output_directory']==str(P/'prepared')
 repo=P/'preparation_evidence/sources';cp=repo/'cores/storage/ram_range_min_index'
 assert context['tested_repository_root']==str(repo) and context['tested_package_root']==str(cp) and context['preparation_cwd']==str(cp)
 copies={'cores/storage/ram_range_min_index/'+n:h for n,h in own.items()}
 author=read(P/'AUTHOR_INPUTS.json');copies.update(author['external_sources']);copies[author['baseline_manifest']]=author['baseline_manifest_sha256']
 assert context['tested_copies_sha256']==copies and len(copies)==28
 for n,h in copies.items():assert sha(local(n))==h
 out=R/'.git/b30-a-preparation-outer-execution01';assert not out.exists();out.mkdir()
 receipt=dict(schema=1,status='STARTED_ONCE',launcher_sha256=expected,approval_sha256=H,
  author_sha256=A,author_seal_sha256=S,preparation_plan_sha256=PP,preparation_invocations=1,
  hard_seconds_per_tree=20,automatic_retry=False,child=None,hardware='HW_UNVERIFIED')
 def save():write(out/'receipt.json',receipt)
 retained={}
 runtime=None;tools=None
 def boundary():
  assert sha(Path(__file__))==expected and sha(ap)==H;review_guard()
  for n,h in own.items():assert sha(P/n)==h
  for n,h in copies.items():assert sha(local(n))==h
  for n,h in retained.items():assert sha(out/n)==h
  for _,(n,h) in INPUTS.items():assert sha(local(n))==h
  runtime.verify(tools)
 try:
  save();write(out/'LOCK.json',dict(status='STARTED_ONCE',approval_sha256=H,launcher_sha256=expected),True)
  for n,source in [('launcher.py',Path(__file__)),('approval.json',ap)]+[(n,local(v[0])) for n,v in INPUTS.items()]:
   raw=source.read_bytes()
   with (out/n).open('xb') as f:f.write(raw)
   retained[n]=sha(out/n)
  retained['LOCK.json']=sha(out/'LOCK.json')
  assert retained['launcher.py']==expected and retained['approval.json']==H
  for n,(_,h) in INPUTS.items():assert retained[n]==h
  runtime=load(out,'tool_runtime');tree=load(out,'tree_process');tools=read(out/'TOOL_INVENTORY.json')
  assert Path(sys.executable).resolve()==Path(tools['tools']['PYTHON']['path']).resolve()
  assert sha(Path(sys.executable))==tools['tools']['PYTHON']['sha256']
  temporary=out/'tmp';temporary.mkdir();system=Path(os.environ['SystemRoot']).resolve(strict=True)
  env=dict(SystemRoot=str(system),WINDIR=str(system),PATH=os.pathsep.join(tools['path_prefix']),TEMP=str(temporary),TMP=str(temporary),
   PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',PYTHONPATH='',PYTHONIOENCODING='utf-8',LANG='C',LC_ALL='C')
  argv=[tools['tools']['PYTHON']['path'],'-B',str(P/'run_tests.py'),'--prepare','--approved-author',A,'--approval',str(ap)]
  receipt.update(argv=argv,cwd=str(R),environment=env,retained_inputs_sha256=retained);save();boundary()
  metadata,stdout,stderr=tree.run_child(dict(argv=argv,cwd=str(R)),env);receipt['child']=metadata
  for suffix,raw in [('stdout',stdout),('stderr',stderr)]:
   with (out/(suffix+'.raw')).open('xb') as f:f.write(raw)
   receipt[suffix]=dict(sha256=sha(out/(suffix+'.raw')),bytes=len(raw))
   retained[suffix+'.raw']=receipt[suffix]['sha256']
  save();boundary()
  assert metadata['exit_code']==0 and not metadata['timed_out'] and metadata['launch_error'] is None
  assert 0<=metadata['elapsed_seconds']<20 and metadata['supervision']['contained_before_resume'] is True and metadata['supervision']['job_closed'] is True
  assert stdout==b'PASS PREPARATION_GATE\r\n' and stderr==b''
  evidence=read(P/'preparation_evidence/receipt.json')
  assert evidence['status']=='PREPARATION_PASS' and evidence['approval_sha256']==H and evidence['execution_context']==context
  assert evidence['returncode']==0 and not evidence['timed_out'] and evidence['failure'] is None and evidence['elapsed_seconds']<20
  assert evidence['process_tree_cleanup']['windows_kill_on_close_job_closed'] is True
  receipt.update(status='PASS_PREPARATION_ONCE_FULL_RUNTIME_OUTER_JOB20',preparation_evidence_receipt_sha256=sha(P/'preparation_evidence/receipt.json'),
   prepared_receipt_sha256=sha(P/'prepared/receipt.json'),prepared_lock_sha256=sha(P/'prepared/LOCK.json'))
  save();print('PASS B30_A_PREPARATION_OUTER_ONCE');return 0
 except Exception as error:
  receipt.update(status='FAILED_STOPPED_NO_RETRY',failure=dict(type=type(error).__name__,message=str(error)));save()
  files={'.git/b30-a-preparation-outer-execution01/'+n:h for n,h in inventory(out).items()}
  files.update({'cores/storage/ram_range_min_index/'+n:h for n,h in inventory(P).items()})
  write(out/'FAILURE_ARCHIVE.json',dict(status='PERMANENT_PRESERVED_IN_PLACE',files_sha256=files,automatic_retry=False),True)
  print('FAILED_STOPPED B30_A_PREPARATION_OUTER_NO_RETRY');return 1
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--approval',type=Path,required=True);parser.add_argument('--approved-launcher',required=True)
 args=parser.parse_args();raise SystemExit(main(args.approval,args.approved_launcher))
