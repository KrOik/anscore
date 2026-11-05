"""Sealed, finite, single-attempt qualification. Every child has a hard20s timeout."""
import argparse,hashlib,json,os,re,shutil,subprocess,tempfile,time
from pathlib import Path
ROOT=Path(__file__).resolve().parent
WORKSPACE=ROOT.parents[2]
MARKER='binary_hu_moments_invalid_parameters__see_README'
SUMMARY={'mode','W','H','T','frames','outputs','queued','resets','fresh','prefix','next','reset_offers',
         'latency','bank','alu','mul','raw_checks','source_holds','output_holds','states','cycles'}
OBS={'target','state','pc','step','raw','index','count','mass','errors','prefix','next','accepted','owned','acc'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def source_map():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name not in ('SOURCE_FREEZE.json','verification.json') and 'failure_archive' not in p.parts
            and '__pycache__' not in p.parts}
def owned(stage):
    files={p.relative_to(WORKSPACE).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()}
    write(WORKSPACE/'.git/b26-c-owned.json',dict(stage=stage,files_sha256=files))
def plan():return read(ROOT/'TEST_PLAN.json')
def seal():
    assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
    assert not (ROOT/'failure_archive').exists()
    p=plan();s=source_map()
    assert len(p['children'])==306 and p['totals']['simulations']==290
    for name in s:
        b=(ROOT/name).read_bytes();b.decode('utf-8');assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf'),name
    d=dict(stage='BEFORE_FIRST_HDL_CHILD_AWAIT_ROOT_PREFLIGHT',baseline=p['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),
           source_sha256=s,children=p['children'],timeout_seconds=20,timeout_terminal=True,no_adaptive_splits=True,
           root_read_only_preflight_required=True)
    write(ROOT/'SOURCE_FREEZE.json',d);owned('SEALED_AWAIT_ROOT_PREFLIGHT')
    print('SOURCE_FROZEN SHA256='+sha(ROOT/'SOURCE_FREEZE.json')+' sources='+str(len(s)))
def parse_line(line,fields):
    pairs=[x.split('=') for x in line.split()[1:]];assert len(pairs)==len(fields) and {x[0] for x in pairs}==fields
    return {k:int(v,16 if k in ('states','owned') else 10) for k,v in pairs}
def check_probe(q,g,d,o):
    z=g['target'];n=q['WIDTH']*q['HEIGHT'];ww=q['WORK_W'];state=o['state']
    states={15:0,16:0,17:0,18:0,19:7,20:7,21:7,22:7,23:1,24:1,25:2,26:9,34:2,35:13,36:7}
    expected=z if z<=14 else 13 if 27<=z<=33 else states[z]
    assert state==expected and o['target']==z
    assert o['count']==o['accepted']==len(d['owner']['tokens']) and o['mass']==d['owner']['area']
    assert o['errors']==d['owner']['errors'] and o['prefix']==g['prefix'] and o['next']==g['next']
    if z==15:assert o['accepted']==1 and o['mass']==0
    if z==16:assert o['accepted']==1 and o['mass']==1
    if z==17:assert o['accepted']==n//2
    if z==18:assert o['accepted']==n-1
    if 19<=z<=21:assert o['pc']==0 and o['step']=={19:0,20:ww//2,21:ww-1}[z]
    if z in (22,36):assert o['pc']==78 and o['step']==ww//2
    if z==36:assert o['acc']!=0
    if z in (23,24):assert o['raw']=={23:0,24:9}[z]
    if z in (25,26):assert o['pc']==78
    if 27<=z<=33:assert o['index']==z-27 and o['prefix']==z-27
    if z==34:assert o['pc']==0 and o['next']==1
    if z==35:assert o['index']==0 and o['next']==1
def work_prefix(o,ww,instructions):
    state=o['state'];pc=o['pc'];mask=0
    if state in (0,14):return (0,0,0,0,0)
    if state==1:
        for k in range(o['raw']):mask|=1<<k
        return (o['raw'],0,0,o['raw'],mask)
    bank=10;alu=0;mul=0;raw=10;mask=(1<<10)-1
    stop=pc if state<10 else len(instructions)
    for ins in instructions[:stop]:
        bank+=3;alu+=3 if ins['op']=='MUL' else 1;mul+=ww if ins['op']=='MUL' else 0;mask|=1<<ins['dd']
    if state>=10:
        bank+=2*o['index']+{10:0,11:1,12:2,13:2}[state]
    else:
        bank+={2:0,3:1,4:2,5:2,6:2,7:2,8:2,9:2}[state]
        if state==6:alu+=1
        if state in (7,8):alu+=2
        if state==7:mul+=o['step']
        if state==8:mul+=ww
        if state==9:
            alu+=3 if instructions[pc]['op']=='MUL' else 1
            mul+=ww if instructions[pc]['op']=='MUL' else 0
    return bank,alu,mul,raw,mask
def result(p,g,kind,stdout):
    lines=stdout.splitlines();ps=[x for x in lines if x.startswith('PASS ')];os_=[x for x in lines if x.startswith('OBS ')]
    assert len(ps)==1
    assert all(x.startswith(('PASS ','OBS ')) or re.fullmatch(r'sim/tb_binary_hu_moments.sv:\d+: \$finish called at \d+ \(1ps\)',x) for x in lines)
    s=parse_line(ps[0],SUMMARY);obs=[parse_line(x,OBS) for x in os_];d=read(ROOT/g['json']);ww=p['WORK_W']
    assert (s['W'],s['H'],s['T'])==(p['WIDTH'],p['HEIGHT'],p['TAG_W'])
    assert s['cycles']<=p['cycle_limit'] and s['frames']==g['frames'] and s['outputs']==g['outputs']
    if kind=='main':
        assert not obs
        assert (s['mode'],s['queued'],s['resets'],s['fresh'],s['prefix'],s['next'],s['reset_offers'],s['latency'])==(0,g['queued'],0,0,0,0,0,g['frames'])
        good=sum(not c['errors'] for c in d['frames']);expected=(261*good,169*good,45*ww*good,10*good)
        if g['queued']:assert s['source_holds']>0
    else:
        assert len(obs)==1;check_probe(p,g,d,obs[0])
        assert (s['mode'],s['queued'],s['resets'],s['fresh'],s['prefix'],s['next'],s['reset_offers'])==(1,0,1,1,g['prefix'],g['next'],3)
        assert s['latency']==1+int(obs[0]['state'] in (13,14))
        prefix=work_prefix(obs[0],ww,read(ROOT/'INSTRUCTIONS.json')['instructions'])
        assert obs[0]['owned']==prefix[4]
        expected=tuple(a+b for a,b in zip(prefix[:4],(261,169,45*ww,10)))
        fresh=d['fresh'];assert fresh['complete'] and len(fresh['tokens'])==p['WIDTH']*p['HEIGHT'] and len(fresh['outputs'])==7 and fresh['errors']==0
    assert tuple(s[k] for k in ('bank','alu','mul','raw_checks'))==expected
    assert s['output_holds']==2*(s['outputs']+s['prefix'])
    return dict(profile=p['name'],group=g['name'],kind=kind,summary=s,observations=obs)
def archive(tmp,receipt):
    dest=ROOT/'failure_archive/attempt_01';assert not dest.exists();(dest/'sources').mkdir(parents=True)
    for name in [*receipt['source_sha256'],'SOURCE_FREEZE.json','verification.json']:
        out=dest/'sources'/name;out.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,out)
    (dest/'artifacts').mkdir()
    for p in sorted(tmp.glob('*.vvp')):shutil.copyfile(p,dest/'artifacts'/p.name)
    m={p.relative_to(dest).as_posix():sha(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    write(dest/'ARCHIVE.json',dict(status=receipt['status'],files_sha256=m,timeout_terminal=True,
          ordinary_failure_requires_specific_root_authorization=True))
def run():
    p=plan();f=read(ROOT/'SOURCE_FREEZE.json')
    assert f['children']==p['children'] and f['source_sha256']==source_map() and f['plan_sha256']==sha(ROOT/'TEST_PLAN.json')
    assert not (ROOT/'verification.json').exists() and not (ROOT/'failure_archive').exists(),'one immutable attempt only'
    toolbin=WORKSPACE/'tools/oss-cad-suite/oss-cad-suite/bin'
    replacements=dict(python=r'C:\Program Files\Python312\python.exe',iverilog=str(toolbin/'iverilog.exe'),vvp=str(toolbin/'vvp.exe'))
    for value in replacements.values():assert Path(value).is_file(),value
    tmp=Path(tempfile.mkdtemp(prefix='b26-c-hu-',dir=WORKSPACE/'.git'))
    receipt=dict(status='IN_PROGRESS',hardware='HW_UNVERIFIED',baseline=p['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),
        source_freeze_sha256=sha(ROOT/'SOURCE_FREEZE.json'),source_sha256=source_map(),timeout_seconds=20,terminal_timeout=False,
        path_expansion={**replacements,'{TMP}':tmp.as_posix()},records=[dict(name=c['name'],status='NOT_RUN') for c in p['children']],results=[])
    lookup={g['name']:(q,g,kind) for q in p['profiles'] for kind in ('main','resets') for g in q[kind]}
    env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1'
    env['PATH']=str(toolbin)+os.pathsep+str(toolbin.parent/'lib')+os.pathsep+env.get('PATH','')
    write(ROOT/'verification.json',receipt)
    try:
        for i,c in enumerate(p['children']):
            argv=[replacements.get(x,x).replace('{TMP}',tmp.as_posix()) for x in c['argv']]
            rec=dict(name=c['name'],argv=argv,timeout_seconds=20,status='RUNNING');receipt['records'][i]=rec;write(ROOT/'verification.json',receipt)
            start=time.monotonic()
            kwargs=dict(executable=argv[0],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            if os.name=='nt':kwargs['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP
            else:kwargs['start_new_session']=True
            child=subprocess.Popen(argv,**kwargs)
            try:
                out,err=child.communicate(timeout=20)
                rec.update(stdout_raw_hex=out.hex(),stderr_raw_hex=err.hex())
                rec.update(status='OBSERVED',elapsed_seconds=time.monotonic()-start,exit_code=child.returncode,
                           stdout=out.decode('utf-8'),stderr=err.decode('utf-8'))
            except subprocess.TimeoutExpired as ex:
                receipt['terminal_timeout']=True
                rec.update(status='TIMEOUT',elapsed_seconds=time.monotonic()-start,exit_code=None,
                           stdout_raw_hex=(ex.stdout or b'').hex(),stderr_raw_hex=(ex.stderr or b'').hex())
                try:
                    if os.name=='nt':
                        killer=str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe')
                        kill_argv=[killer,'/PID',str(child.pid),'/T','/F']
                        killed=subprocess.run(kill_argv,executable=killer,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5)
                        rec['tree_termination']=dict(argv=kill_argv,exit_code=killed.returncode,
                            stdout_raw_hex=killed.stdout.hex(),stderr_raw_hex=killed.stderr.hex())
                    else:
                        os.killpg(child.pid,9)
                        rec['tree_termination']=dict(process_group=child.pid,signal=9)
                    out,err=child.communicate(timeout=5)
                    rec.update(elapsed_seconds=time.monotonic()-start,exit_code=child.returncode,
                               stdout_raw_hex=out.hex(),stderr_raw_hex=err.hex())
                    rec.update(stdout=out.decode('utf-8'),stderr=err.decode('utf-8'))
                except Exception as cleanup_error:
                    rec['tree_cleanup_error']=dict(type=type(cleanup_error).__name__,message=str(cleanup_error))
                    if isinstance(cleanup_error,subprocess.TimeoutExpired):
                        rec['tree_cleanup_error'].update(argv=cleanup_error.cmd,
                            stdout_raw_hex=(cleanup_error.stdout or b'').hex(),stderr_raw_hex=(cleanup_error.stderr or b'').hex())
                    write(ROOT/'verification.json',receipt)
                    raise
                write(ROOT/'verification.json',receipt);raise
            write(ROOT/'verification.json',receipt)
            if c['expected']=='REJECT_INVALID_PARAMETERS_MARKER':assert rec['exit_code']!=0 and MARKER in rec['stdout']+rec['stderr']
            else:
                assert rec['exit_code']==0 and rec['stderr']==''
                if c['name']=='fixture_oracles':assert rec['stdout'].strip()=='PASS fixture_oracles cases=628 fixtures=290'
                elif c['name'] in lookup:
                    q,g,kind=lookup[c['name']];receipt['results'].append(result(q,g,kind,rec['stdout']))
                elif c['name']!='tool_version':assert rec['stdout']==''
            rec['status']='PASS';write(ROOT/'verification.json',receipt)
        receipt['status']='UNIT_SIM_PASS';receipt['totals']=p['totals'];receipt['max_child_seconds']=max(x['elapsed_seconds'] for x in receipt['records'])
        keys=('frames','outputs','queued','resets','fresh','prefix','next','reset_offers','latency','bank','alu','mul','raw_checks','source_holds','output_holds')
        receipt['observed_totals']={k:sum(x['summary'][k] for x in receipt['results']) for k in keys}
        write(ROOT/'verification.json',receipt);owned('READY_UNIT_SIM_PASS')
        print('UNIT_SIM_PASS children=306 simulations=290 max_seconds='+str(receipt['max_child_seconds']))
    except Exception as ex:
        receipt['status']='INCOMPLETE_TIMEOUT' if receipt['terminal_timeout'] else 'FAIL_STOPPED'
        receipt['failure']=dict(type=type(ex).__name__,message=str(ex),executed=sum(x['status']!='NOT_RUN' for x in receipt['records']))
        write(ROOT/'verification.json',receipt);archive(tmp,receipt);owned(receipt['status']);raise
    finally:
        # This one tempfile directory is the exact object returned by mkdtemp.
        assert tmp.resolve().name.startswith('b26-c-hu-') and tmp.resolve().parent==(WORKSPACE/'.git').resolve()
        shutil.rmtree(tmp)
def check():
    p=plan();f=read(ROOT/'SOURCE_FREEZE.json');r=read(ROOT/'verification.json')
    assert f['source_sha256']==source_map()==r['source_sha256'] and r['source_freeze_sha256']==sha(ROOT/'SOURCE_FREEZE.json')
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout'] and len(r['records'])==306
    lookup={g['name']:(q,g,kind) for q in p['profiles'] for kind in ('main','resets') for g in q[kind]};results=[]
    exp=r['path_expansion']
    for c,rec in zip(p['children'],r['records']):
        assert rec['argv']==[exp.get(x,x).replace('{TMP}',exp['{TMP}']) for x in c['argv']]
        assert rec['name']==c['name'] and rec['status']=='PASS' and rec['timeout_seconds']==20 and rec['elapsed_seconds']<20
        if c['expected']=='PASS':assert rec['exit_code']==0 and rec['stderr']==''
        else:assert rec['exit_code']!=0 and MARKER in rec['stdout']+rec['stderr']
        if c['name'] in lookup:
            q,g,kind=lookup[c['name']];results.append(result(q,g,kind,rec['stdout']))
    assert results==r['results'];print('CHECK PASS children=306 simulations=290')
if __name__=='__main__':
    a=argparse.ArgumentParser();g=a.add_mutually_exclusive_group(required=True)
    g.add_argument('--seal',action='store_true');g.add_argument('--run',action='store_true');g.add_argument('--check',action='store_true');args=a.parse_args()
    if args.seal:seal()
    elif args.run:run()
    else:check()
