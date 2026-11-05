"""One frozen finite attempt; 20-second children, first failure stops, no retry."""
from pathlib import Path
import argparse,hashlib,json,os,re,signal,subprocess,time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
SEAL=ROOT/'SOURCE_FREEZE.json'
REPORT=ROOT/'verification.json'
LOGS=ROOT/'reports'
ARTIFACTS=REPO/'.git/b27-b-artifacts'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,data):p.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def sources():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()
        and p not in [SEAL,REPORT] and p.relative_to(ROOT).parts[0] not in ['reports','failure_archive']}
def freeze():
    assert not SEAL.exists() and not REPORT.exists(),'never replace a seal or receipt'
    plan=read(ROOT/'TEST_PLAN.json')
    assert len(plan['children'])==21 and plan['totals']['main_frames']==90 and plan['totals']['reset_count']==58
    tools={c['argv'][0]:sha(Path(c['argv'][0])) for c in plan['children']}
    write(SEAL,dict(schema=1,baseline=plan['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),
       frozen_before_any_hdl=True,files_sha256=sources(),tools_sha256=tools,timeout_seconds=20,attempt=1))
    print('SEALED',sha(SEAL),'files',len(read(SEAL)['files_sha256']))
def check():
    seal=read(SEAL)
    assert sources()==seal['files_sha256'] and sha(ROOT/'TEST_PLAN.json')==seal['plan_sha256']
    assert all(sha(Path(p))==v for p,v in seal['tools_sha256'].items())
    if REPORT.exists():
        r=read(REPORT);plan=read(ROOT/'TEST_PLAN.json')
        assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and r['not_run']==[]
        assert r['source_freeze_sha256']==sha(SEAL) and r['source_sha256']==dict(seal['files_sha256'],**{SEAL.name:sha(SEAL)})
        assert len(r['records'])==21
        for record,command in zip(r['records'],plan['children'],strict=True):
            assert record['status']==command['expected']
            for stream in ['stdout','stderr']:assert sha(ROOT/record[stream+'_file'])==record[stream+'_sha256']
        assert {p.relative_to(ROOT).as_posix() for p in LOGS.iterdir() if p.is_file()}=={
            x[stream+'_file'] for x in r['records'] for stream in ['stdout','stderr']}
    print('PASS read-only source/receipt integrity; no oracle or HDL invocation')

REC=re.compile(r'REC cmd=(\d+) phase=(\d+) part=(\d+) poly=([0-9a-f]+) tag=([0-9a-f]+) factor=([0-9a-f]+) multiplicity=(\d+) degree=(\d+) last=(\d+) gap=(\d+)')
FRAME=re.compile(r'FRAME cmd=(\d+) phase=(\d+) parts=(\d+)')
PROBE=re.compile(r'PROBE id=(\d+) state=(\d+) operation=(\d+) iteration=(\d+) level=(\d+) prefix=(\d+) u=([0-9a-f]+) v=([0-9a-f]+) q=([0-9a-f]+) c=([0-9a-f]+) w=([0-9a-f]+) z=([0-9a-f]+) last=(\d+) offer=(\d+)')
def rows(pattern,output):return [m.groups() for line in output.splitlines() if (m:=pattern.fullmatch(line))]

def kill_tree(child):
    """Best-effort cleanup evidence; the original timeout remains terminal."""
    evidence={}
    try:
        if os.name=='nt':
            killer=Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'
            assert killer.is_absolute()
            argv=[str(killer),'/PID',str(child.pid),'/T','/F'];evidence['argv']=argv
            result=subprocess.run(argv,capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
            evidence.update(returncode=result.returncode,stdout_raw_hex=result.stdout.hex(),stderr_raw_hex=result.stderr.hex())
            if result.returncode!=0 and child.poll() is None:
                child.kill();evidence['parent_kill_fallback']=True
        else:
            evidence['process_group']=child.pid
            os.killpg(child.pid,signal.SIGKILL);evidence['killpg_sent']=True
    except Exception as error:
        evidence['cleanup_error']=str(error)
        try:
            if child.poll() is None:child.kill();evidence['parent_kill_fallback']=True
        except Exception as fallback:evidence['fallback_error']=str(fallback)
    return evidence
def validate(command,output,profiles):
    if command['kind']!='simulation':return None
    p=profiles[command['profile']];fixture=read(ROOT/p['certificate']);mode=command['mode']
    summaries=[line for line in output.splitlines() if line.startswith('PASS mode=')]
    assert len(summaries)==1,'missing/duplicate final completion'
    values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',summaries[0])}
    assert values['mode']==mode and values['D']==p['degree']
    expected=[];expected_frames=[];metrics={k:0 for k in ['gcd_cancels','gcd_swaps','gcd_done','div_cancels','div_done','roots']}
    def factors(c,id,phase,count=None):
        for part,x in enumerate(c['factors'][:count]):
            expected.append([id,phase,part,c['poly'],c['tag'],x['factor'],x['multiplicity'],x['degree'],int(x['last']),x['gap']])
    def add_metrics(m):
        for k in metrics:metrics[k]+=m[k]
    if mode!=2:
        for i,c in enumerate(fixture['cases']):
            factors(c,i,0);expected_frames.append([i,0,len(c['factors'])]);add_metrics(c['metrics'])
        n=p['main_count'];nf=len(expected)
        assert values['accepts']==values['completed']==n and values['canceled']==0
        assert values['factors']==values['latency_checks']==nf
        assert all(values[k]==0 for k in ['prefix','fresh','resets','next','reset_offers'])
        assert values['source_holds']>0 and values['output_holds']==(0 if mode==0 else 3*nf)
    else:
        for probe in fixture['probes']:
            factors(probe['owner'],probe['id'],1,probe['predicate']['retired'])
            factors(probe['fresh'],probe['id'],2)
            expected_frames.append([probe['id'],2,len(probe['fresh']['factors'])])
            add_metrics(probe['owner_prefix_metrics']);add_metrics(probe['fresh']['metrics'])
        n=p['reset_count'];prefix=p['owner_prefix_factors'];fresh=p['fresh_factors']
        held=sum(x['predicate']['state']==5 for x in fixture['probes'])
        assert values['accepts']==2*n and values['completed']==values['canceled']==values['resets']==n
        assert values['next']==1 and values['reset_offers']==3*n
        assert values['factors']==prefix+fresh and values['prefix']==prefix and values['fresh']==fresh
        assert values['latency_checks']==prefix+fresh+held and values['output_holds']>=3*(prefix+fresh+held)
        observed=rows(PROBE,output);assert len(observed)==n,'missing real reset observations'
        for row,probe in zip(observed,fixture['probes'],strict=True):
            actual=[int(x,16 if 6<=i<=11 else 10) for i,x in enumerate(row)]
            x=probe['predicate'];mask=x['mask']
            wanted=[probe['id'],x['state'],x['operation'] if mask&1 else 0,x['iteration'],x['level'],x['retired'],
                    x['u'] if mask&2 else 0,x['v'] if mask&2 else 0,x['q'] if mask&4 else 0,
                    x['c'] if mask&8 else 0,x['w'] if mask&8 else 0,x['z'] if mask&16 else 0,
                    int(x['last']) if mask&32 else 0,int(probe['actual_next_offer'])]
            assert actual==wanted,('actual registered reset predicate differs',actual,wanted)
    actual=[[int(x,16 if i in [3,4,5] else 10) for i,x in enumerate(row)] for row in rows(REC,output)]
    assert actual==expected,'retired factors differ from independent certificates'
    assert [[int(x) for x in row] for row in rows(FRAME,output)]==expected_frames,'missing/extra/early completed frame'
    assert all(values[k]==v for k,v in metrics.items()),('engine operation counts differ',values,metrics)
    return dict(profile=p['name'],mode=mode,observed=values)

def archive_failure(report):
    archive=ROOT/'failure_archive/attempt_01';assert not archive.exists(),'never replace failure history'
    for relative in [*report['source_sha256'],REPORT.name]:
        dest=archive/'sources'/relative;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes((ROOT/relative).read_bytes())
    if ARTIFACTS.exists():
        for p in ARTIFACTS.rglob('*'):
            if p.is_file():
                dest=archive/'artifacts'/p.relative_to(ARTIFACTS);dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(p.read_bytes())
    for p in LOGS.iterdir():
        if p.is_file():
            dest=archive/'logs'/p.name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(p.read_bytes())
    index={p.relative_to(archive).as_posix():sha(p) for p in sorted(archive.rglob('*')) if p.is_file()}
    write(archive/'ARCHIVE.json',dict(status=report['status'],files_sha256=index,original_receipt_sha256=sha(REPORT),no_automatic_retry=True))

def execute(approved):
    check();assert approved==sha(SEAL),'exact root-approved source seal required'
    assert not REPORT.exists() and not LOGS.exists() and not ARTIFACTS.exists(),'one attempt only; never overwrite evidence'
    plan=read(ROOT/'TEST_PLAN.json');profiles={p['name']:p for p in plan['profiles']}
    ARTIFACTS.mkdir();LOGS.mkdir()
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    records=[];results=[];stopped=False;terminal_timeout=False
    for number,command in enumerate(plan['children']):
        record=dict(name=command['name'],argv=command['argv'],expected=command['expected'],timeout_seconds=20)
        if stopped:
            records.append(dict(record,status='NOT_RUN',exit_code=None,elapsed_seconds=0,stdout='',stderr=''));continue
        start=time.monotonic();raw_out=b'';raw_err=b''
        try:
            kwargs=dict(cwd=command['cwd'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            if os.name=='nt':kwargs['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
            else:kwargs['start_new_session']=True
            child=subprocess.Popen(command['argv'],**kwargs)
            try:raw_out,raw_err=child.communicate(timeout=20)
            except subprocess.TimeoutExpired as timeout:
                raw_out=timeout.stdout or b'';raw_err=timeout.stderr or b''
                record['process_tree_cleanup']=kill_tree(child)
                try:raw_out,raw_err=child.communicate(timeout=5)
                except subprocess.TimeoutExpired as drain:
                    record['process_tree_cleanup']['drain_timeout']=True
                    raw_out=drain.stdout or raw_out;raw_err=drain.stderr or raw_err
                timeout.stdout=raw_out;timeout.stderr=raw_err;raise timeout
            record.update(exit_code=child.returncode,stdout=raw_out.decode('utf-8',errors='replace'),stderr=raw_err.decode('utf-8',errors='replace'))
            if command['expected']=='EXPECTED_REJECT':assert child.returncode>0 and command['marker'] in record['stdout']+record['stderr'],'missing named rejection'
            else:assert child.returncode==0,'unexpected child failure'
            result=validate(command,record['stdout'],profiles)
            if result:results.append(result)
            record['status']=command['expected']
        except subprocess.TimeoutExpired as error:
            stopped=True;terminal_timeout=True;raw_out=error.stdout or b'';raw_err=error.stderr or b''
            record.update(status='TIMEOUT',exit_code=None,stdout=raw_out.decode('utf-8',errors='replace'),stderr=raw_err.decode('utf-8',errors='replace'),error='terminal child timeout; no automatic retry')
        except Exception as error:
            stopped=True;record.update(status='OBSERVED',error=str(error));record.setdefault('exit_code',None);record.setdefault('stdout','');record.setdefault('stderr','')
        record['elapsed_seconds']=round(time.monotonic()-start,6)
        for stream,raw in [('stdout',raw_out),('stderr',raw_err)]:
            path=LOGS/f"{number:03d}_{command['name']}.{stream}";path.write_bytes(raw)
            record[stream+'_file']=path.relative_to(ROOT).as_posix();record[stream+'_sha256']=sha(path)
        records.append(record);print(command['name'],record['status'],record['elapsed_seconds'],flush=True)
    assert sources()==read(SEAL)['files_sha256'],'sealed sources changed during attempt'
    report=dict(status='TIMEOUT_TERMINAL' if terminal_timeout else 'FAIL_STOPPED' if stopped else 'UNIT_SIM_PASS',hardware='HW_UNVERIFIED',
       baseline=plan['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),source_freeze_sha256=sha(SEAL),
       source_sha256=dict(read(SEAL)['files_sha256'],**{SEAL.name:sha(SEAL)}),attempt=1,terminal_timeout=terminal_timeout,
       timeout_seconds=20,totals=plan['totals'],records=records,results=results,max_child_seconds=max(x['elapsed_seconds'] for x in records),
       not_run=[x['name'] for x in records if x['status']=='NOT_RUN'])
    write(REPORT,report)
    if stopped:archive_failure(report)
    print(report['status'],sha(REPORT),flush=True)
    if stopped:raise SystemExit(1)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);action=parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--seal',action='store_true');action.add_argument('--check',action='store_true');action.add_argument('--execute',action='store_true')
    parser.add_argument('--approved-seal');args=parser.parse_args()
    if args.seal:freeze()
    elif args.check:check()
    else:execute(args.approved_seal)
