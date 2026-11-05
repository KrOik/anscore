"""One reviewed finite matrix; every child has a 20s process-tree deadline."""
from pathlib import Path
import argparse,ctypes,hashlib,json,os,re,shutil,signal,subprocess,tempfile,time
P=Path(__file__).resolve().parent;R=P.parents[2]
SEAL=P/'SOURCE_SEAL.json';RECEIPT=P/'verification.json'
MARKER='general_weighted_matching_invalid_parameters__see_README'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf8',newline='\n')
def sources():
 return {p.relative_to(P).as_posix():sha(p) for p in sorted(P.rglob('*')) if p.is_file()
  and p not in (SEAL,RECEIPT) and p.relative_to(P).parts[0] not in ('reports','failure_archive') and '__pycache__' not in p.parts}
def tools():
 b=R/'tools/oss-cad-suite/oss-cad-suite/bin'
 return dict(python=r'C:\Program Files\Python312\python.exe',iverilog=str(b/'iverilog.exe'),vvp=str(b/'vvp.exe'))
def freeze():
 assert not SEAL.exists() and not RECEIPT.exists() and not (P/'reports').exists()
 plan=read(P/'TEST_PLAN.json');assert len(plan['children'])==23
 prep=read(P/'preparation/receipt.json')
 assert prep['status']=='PASS' and prep['returncode']==0 and not prep['timeout']
 write(SEAL,dict(schema=1,baseline=plan['baseline'],source_sha256=sources(),external_sha256={},
  plan_sha256=sha(P/'TEST_PLAN.json'),children=plan['children'],tools_sha256={k:sha(Path(v)) for k,v in tools().items()},
  frozen_before_hdl=True,timeout_seconds=20,tree_timeout=True,first_failure_stops=True,automatic_retry=False))
 print('SEALED '+sha(SEAL))
def validate_seal():
 f=read(SEAL);assert f['source_sha256']==sources() and f['external_sha256']=={}
 assert f['plan_sha256']==sha(P/'TEST_PLAN.json') and f['children']==read(P/'TEST_PLAN.json')['children']
 assert f['tools_sha256']=={k:sha(Path(v)) for k,v in tools().items()}
 return f
def parse(line):
 pairs=[q.split('=') for q in line.split()[1:]]
 assert len(pairs)==len(dict(pairs)) and all(len(q)==2 for q in pairs)
 return {k:int(v) if re.fullmatch(r'-?\d+',v) else v for k,v in pairs}
def expected_rows(frame,n,phase,kind='REC'):
 rows=[]
 for row in range(1 if frame['error'] else n):
  err=frame['error'];mate=frame['mates'][row]
  rows.append((kind,dict(phase=phase,frame=frame['id'],row=row,keep=int(not err),last=int(bool(err) or row==n-1),
   error=err,tag=frame['tag'],node=0 if err else row,matched=int(not err and mate>=0),
   partner=0 if err or mate<0 else mate,cardinality=frame['cardinality'],total=frame['total'])))
 return rows
def summarize(command,stdout,plan):
 p=plan['profiles'][command['profile']];f=read(P/f'fixtures/p{p["index"]}.json');mode=command['mode'];n=p['N']
 events=[];summaries=[];finish=[]
 for line in stdout.splitlines():
  if line.startswith(('REC ','PREFIX ','OBS ')):events.append((line.split()[0],parse(line)))
  elif line.startswith('PASS '):summaries.append(parse(line))
  else:
   assert re.fullmatch(r'sim/tb.sv:\d+: \$finish called at \d+ \(1ps\)',line),line
   finish.append(line)
 assert len(summaries)==len(finish)==1
 s=summaries[0]
 assert set(s)=={'profile','mode','N','W','T','frames','accepted','retired','resets','reset_offers','next','held','source_holds','cycles'}
 assert (s['profile'],s['mode'],s['N'],s['W'],s['T'])==(p['index'],mode,n,p['W'],p['T'])
 assert s['cycles']<=p['cycle_limit'] and s['held']>=3*s['retired'] and s['source_holds']>0
 expected=[];observations=[]
 if mode==0:
  for frame in f['cases']:expected.extend(expected_rows(frame,n,-1))
  assert s['frames']==len(f['cases']) and s['accepted']==p['tokens'] and s['retired']==p['rows']
  assert s['resets']==s['reset_offers']==0 and s['next']==len(f['cases'])-1
 else:
  observed=[v for k,v in events if k=='OBS'];assert len(observed)==len(p['probes'])
  prefix=0;cancel_tokens=0
  for probe,o in zip(p['probes'],observed,strict=True):
   assert set(o)=={'probe','state','mask','scan','address','choice','edge_positive','prefix','accepted'}
   assert o['probe']==probe and o['state']==(14 if probe==16 else probe)
   assert o['prefix']==(n-1 if probe==16 else 0)
   if probe==0:assert o['address']==n*n//2 and o['accepted']==0
   elif probe==1:assert o['accepted']==1
   else:assert o['accepted']==len(f['cancel' if probe==15 else 'fresh']['tokens'])
   if probe in [3,4,5]:assert o['mask']>=2
   if probe==6:assert o['scan']<n and o['mask']&(1<<o['scan'])
   if probe==8:assert o['edge_positive']==1
   if probe==10:assert o['mask']==p['commit_target']
   if probe==12:assert o['mask']!=0
   if probe==13:assert isinstance(o['choice'],int) and o['choice']>0
   if probe==16:
    expected.extend(expected_rows(f['fresh'],n,probe,'PREFIX')[:n-1]);prefix+=n-1
   expected.append(('OBS',o));expected.extend(expected_rows(f['fresh'],n,probe))
   cancel_tokens+=o['accepted'];observations.append(o)
  assert s['frames']==s['resets']==len(observed) and s['reset_offers']==3*len(observed) and s['next']==0
  assert s['accepted']==cancel_tokens+len(observed)*len(f['fresh']['tokens'])
  assert s['retired']==n*len(observed)+prefix
 assert events==expected
 return dict(profile=p['index'],mode=mode,summary=s,observations=observations,
             actual_record_lines=sum(k=='REC' for k,v in events),actual_prefix_lines=sum(k=='PREFIX' for k,v in events))
def archive(tmp,receipt):
 a=P/'failure_archive/attempt_01';assert not a.exists()
 for name in [*receipt['source_sha256'],'SOURCE_SEAL.json','verification.json']:
  dest=a/'sources'/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(P/name,dest)
 for src in (P/'reports').iterdir():
  dest=a/'reports'/src.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
 for src in tmp.iterdir():
  assert src.name in {f'p{i}.vvp' for i in range(5)} and src.is_file()
  dest=a/'artifacts'/src.name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,dest)
 write(a/'ARCHIVE.json',dict(files_sha256={p.relative_to(a).as_posix():sha(p) for p in a.rglob('*') if p.is_file()},
  original_receipt_sha256=sha(RECEIPT),status=receipt['status'],no_retry=True,timeout_terminal=True))

class WindowsJob:
    """Place a suspended child in a kill-on-close Job before any compiler code runs."""
    def __init__(self):
        from ctypes import wintypes as wt
        class Basic(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', wt.DWORD), ('min_working_set', ctypes.c_size_t),
                        ('max_working_set', ctypes.c_size_t), ('active_limit', wt.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', wt.DWORD), ('scheduling', wt.DWORD)]
        class Io(ctypes.Structure):
            _fields_ = [(p, ctypes.c_uint64) for p in ['read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes']]
        class Extended(ctypes.Structure):
            _fields_ = [('basic', Basic), ('io', Io), ('process_memory', ctypes.c_size_t),
                        ('job_memory', ctypes.c_size_t), ('peak_process', ctypes.c_size_t), ('peak_job', ctypes.c_size_t)]
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wt.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE]
        self.kernel.TerminateJobObject.argtypes = [wt.HANDLE, wt.UINT]
        self.kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended();limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error());self.close();raise error

    def assign_and_resume(self, child, deadline):
        if not self.kernel.AssignProcessToJobObject(self.handle, int(child._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(child.args, 20)
        # Popen closes the primary thread handle. Resume the assigned suspended process
        # through the native system call; no external helper or uncontained child runs.
        native = ctypes.WinDLL('ntdll')
        native.NtResumeProcess.argtypes = [ctypes.c_void_p]
        native.NtResumeProcess.restype = ctypes.c_long
        status = native.NtResumeProcess(int(child._handle))
        if status != 0:
            raise OSError(f'NtResumeProcess status 0x{status & 0xffffffff:08x}')

    def terminate(self):
        return bool(self.kernel.TerminateJobObject(self.handle, 1))

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle);self.handle = None


def run_child(command, env):
    start = time.monotonic();deadline = start+20.0
    job = None;child = None;raw_out = raw_err = b'';cleanup = {};timed_out = False;error = None
    try:
        kwargs = dict(cwd=command['cwd'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if os.name == 'nt':
            job = WindowsJob()
            kwargs['creationflags'] = 0x4 | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        else:
            kwargs['start_new_session'] = True
        child = subprocess.Popen(command['argv'], **kwargs)
        cleanup['pid'] = child.pid
        if job:
            job.assign_and_resume(child, deadline);cleanup['contained_before_resume'] = True
        try:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command['argv'], 20)
            raw_out, raw_err = child.communicate(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            timed_out = True;raw_out = exc.stdout or b'';raw_err = exc.stderr or b''
            cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
            if job:
                cleanup['terminate_job_sent'] = job.terminate();job.close()
            else:
                os.killpg(child.pid, signal.SIGKILL);cleanup['killpg_sent'] = True
            # Only drain already terminated processes; no extension of execution time.
            try:
                raw_out, raw_err = child.communicate(timeout=0.5)
            except subprocess.TimeoutExpired as drain:
                raw_out = drain.stdout or raw_out;raw_err = drain.stderr or raw_err
                cleanup['drain_incomplete'] = True
    except subprocess.TimeoutExpired as exc:
        timed_out = True;error = type(exc).__name__+': '+str(exc)
        cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
    except Exception as exc:
        error = type(exc).__name__+': '+str(exc)
    finally:
        if job:
            job.close()  # Also kills descendants left after a normal parent exit.
        if child is not None and child.poll() is None:
            try:
                if os.name != 'nt': os.killpg(child.pid, signal.SIGKILL)
                child.kill()
                raw_out, raw_err = child.communicate(timeout=0.5)
            except Exception as exc:
                cleanup['fallback_error'] = type(exc).__name__+': '+str(exc)
    return dict(exit_code=None if child is None else child.returncode,
                elapsed_seconds=round(time.monotonic()-start, 6), timed_out=timed_out,
                supervision=cleanup, launch_error=error), raw_out, raw_err



def run(approved):
 f=validate_seal();assert approved==sha(SEAL)
 assert not RECEIPT.exists() and not (P/'reports').exists() and not (P/'failure_archive').exists()
 (P/'reports').mkdir();tmp=Path(tempfile.mkdtemp(prefix='b28-root-matching-',dir=R/'.git'))
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
   metadata,out,err=run_child(dict(argv=argv,cwd=str(P)),env)
   rec.update(returncode=metadata['exit_code'],elapsed_seconds=metadata['elapsed_seconds'],
    supervision=metadata['supervision'],launch_error=metadata['launch_error'],timeout=metadata['timed_out'])
   if metadata['timed_out']:
    receipt['terminal_timeout']=True;rec['status']='TIMEOUT'
   for stream,data in [('stdout',out),('stderr',err)]:
    path=P/'reports'/f'{index:02d}_{c["name"]}.{stream}';path.write_bytes(data)
    rec[stream]=path.relative_to(P).as_posix();rec[stream+'_sha256']=sha(path)
   if rec['status']=='TIMEOUT':write(RECEIPT,receipt);raise TimeoutError('terminal 20s process-tree limit')
   rec['status']='OBSERVED';write(RECEIPT,receipt)
   assert rec['launch_error'] is None,rec['launch_error']
   assert rec['elapsed_seconds']<20
   if c['kind']=='reject':assert rec['returncode'] is not None and rec['returncode']>0 and MARKER.encode() in out+err
   else:
    assert rec['returncode']==0
    if c['kind']!='version':assert not err
    if c['kind']=='simulation':receipt['results'].append(summarize(c,out.decode('utf-8'),plan))
    elif c['kind']=='oracle':assert out.decode('utf-8').strip()=='PASS fixed edge-subset certificates profiles=5'
    elif c['kind']!='version':assert not out
   rec['status']='EXPECTED_REJECT' if c['kind']=='reject' else 'PASS'
   if c['kind']=='compile':rec['artifact_sha256']=sha(tmp/f'p{c["profile"]}.vvp')
   write(RECEIPT,receipt)
  assert sources()==f['source_sha256']
  receipt['status']='UNIT_SIM_PASS';receipt['max_child_seconds']=max(r['elapsed_seconds'] for r in receipt['records'])
  receipt['totals']=plan['totals'];write(RECEIPT,receipt)
  can_cleanup=True
  print('UNIT_SIM_PASS children=23 simulations=8')
 except Exception as error:
  receipt['status']='TIMEOUT_TERMINAL' if receipt['terminal_timeout'] else 'FAIL_STOPPED'
  receipt['failure']=dict(type=type(error).__name__,message=str(error))
  if rec['status'] not in ['TIMEOUT','PASS','EXPECTED_REJECT']:rec['status']='FAIL'
  write(RECEIPT,receipt);archive(tmp,receipt);can_cleanup=True;raise
 finally:
  assert tmp.resolve().parent==(R/'.git').resolve() and tmp.name.startswith('b28-root-matching-')
  if can_cleanup:
   for path in tmp.iterdir():
    assert path.name in {f'p{i}.vvp' for i in range(5)} and path.is_file() and not path.is_symlink();path.unlink()
   tmp.rmdir()

def check():
 f=validate_seal();r=read(RECEIPT);p=read(P/'TEST_PLAN.json')
 assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout']
 assert r['source_sha256']==f['source_sha256'] and r['external_sha256']=={}
 assert r['source_seal_sha256']==sha(SEAL) and r['plan_sha256']==f['plan_sha256']
 assert len(r['records'])==23 and len(r['results'])==8
 actual=[];streams=set()
 for c,rec in zip(p['children'],r['records'],strict=True):
  assert rec['name']==c['name'] and rec['status']==('EXPECTED_REJECT' if c['kind']=='reject' else 'PASS')
  assert rec['elapsed_seconds']<20
  assert rec['argv']==[r['path_expansion'].get(x,x).replace('{TMP}',r['path_expansion']['{TMP}']) for x in c['argv']]
  for k in ['stdout','stderr']:
   assert sha(P/rec[k])==rec[k+'_sha256'];streams.add(rec[k])
  out=(P/rec['stdout']).read_bytes();err=(P/rec['stderr']).read_bytes()
  if c['kind']=='reject':assert rec['returncode']>0 and MARKER.encode() in out+err
  else:
   assert rec['returncode']==0
   if c['kind']!='version':assert not err
   if c['kind']=='oracle':assert out.decode('utf8').strip()=='PASS fixed edge-subset certificates profiles=5'
   elif c['kind']=='simulation':actual.append(summarize(c,out.decode('utf8'),p))
   elif c['kind']!='version':assert not out
 assert actual==r['results'] and streams=={p.relative_to(P).as_posix() for p in (P/'reports').iterdir() if p.is_file()}
 print('CHECK PASS read-only children=23 simulations=8')

if __name__=='__main__':
 a=argparse.ArgumentParser();g=a.add_mutually_exclusive_group(required=True)
 g.add_argument('--seal',action='store_true');g.add_argument('--run',action='store_true');g.add_argument('--check',action='store_true')
 a.add_argument('--approved-seal');x=a.parse_args()
 if x.seal:freeze()
 elif x.run:run(x.approved_seal)
 else:check()
