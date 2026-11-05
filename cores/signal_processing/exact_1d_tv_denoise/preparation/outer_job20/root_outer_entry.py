from pathlib import Path
import hashlib,importlib.util,json,os,sys
R=Path(__file__).resolve().parent.parent
P=R/'cores/signal_processing/exact_1d_tv_denoise'
O=R/'.git/b29-b-prepare-outer01'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def dump(p,d):
 with p.open('x',encoding='utf-8',newline='\n') as f:json.dump(d,f,indent=2);f.write('\n')
assert not sys.flags.optimize
ap=R/'.git/b29-b-preparation-approval01.json';approval=json.loads(ap.read_bytes())
assert sha(P/'SOURCE_FREEZE.json')==approval['source_freeze_sha256']
assert not (P/'preparation').exists() and not (P/'prepared').exists() and not (P/'SOURCE_SEAL.json').exists()
helper=R/approval['outer_supervisor']['source'];assert sha(helper)==approval['outer_supervisor']['sha256']
O.mkdir(exist_ok=False)
lock={'status':'ONE_PREPARATION_STARTED','approval_sha256':sha(ap),'source_freeze_sha256':sha(P/'SOURCE_FREEZE.json'),'automatic_retry':False,'hard_seconds':20}
dump(O/'LOCK.json',lock)
copy=O/'tree_process.py';copy.write_bytes(helper.read_bytes());assert sha(copy)==sha(helper)
spec=importlib.util.spec_from_file_location('b29_b_once_root_job20',copy);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
argv=[approval['tools']['PYTHON']['path'],'-B',str(P/'prepare.py'),'--approved-source-freeze',approval['source_freeze_sha256'],'--approval',str(ap)]
env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
meta,out,err=module.run_child({'argv':argv,'cwd':str(R)},env)
for name,data in [('stdout.raw',out),('stderr.raw',err)]:
 with (O/name).open('xb') as f:f.write(data)
result={'status':'PASS' if meta['exit_code']==0 and not meta['timed_out'] and meta['launch_error'] is None and meta['elapsed_seconds']<20 and out==b'PASS PREPARED TV cases=10 profiles=6 fixed_only=1 no_hdl=1\r\n' and not err else 'FAILED_STOPPED_NO_RETRY','argv':argv,'approval_sha256':sha(ap),'helper_sha256':sha(copy),'metadata':meta,'streams':{n:{'sha256':sha(O/n),'bytes':(O/n).stat().st_size} for n in ['stdout.raw','stderr.raw']},'invocations':1,'automatic_retry':False}
dump(O/'RECEIPT.json',result)
print(json.dumps(result))
raise SystemExit(0 if result['status']=='PASS' else 1)
