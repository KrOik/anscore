"""SPDX-License-Identifier: Apache-2.0. Frozen B42 finite scope; no retries/cleanup/network."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
INPUTS=['.gitattributes','rtl/raw_optical_black_rows.sv','example/raw_ob_black_frontend.sv',
        'sim/tb_raw_optical_black_rows.sv','reference_model.py','run_tests.py','files.f','example/files.f',
        'README.md','ARCHITECTURE.md','SOURCES.md','references.json','LICENSE','../isp_stream/rtl/raw_black_level_stream.v']
PROFILES=[dict(name='core_1x1_d8',w=1,h=1,b=8,l=2,r=0,t=1,wrap=0),dict(name='core_7x5_d10',w=7,h=5,b=10,l=3,r=4,t=8,wrap=0),
          dict(name='core_17x9_d12',w=17,h=9,b=12,l=32,r=32,t=32,wrap=0),dict(name='actual_32x8_d10',w=32,h=8,b=10,l=7,r=5,t=8,wrap=1)]
CHECKED=[18,784,3400,5696]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
def freeze():
    assert not (ROOT/'reports').exists() and not (ROOT/'PRECHECK_PLAN.json').exists(),'No automatic replan'
    checks=[];build=ROOT/'.build'/'<stamp>';report=ROOT/'reports'/'<stamp>'
    def add(n,args,cwd=ROOT,marker=None,counters=None):checks.append(dict(name=n,argv=list(map(str,args)),cwd=str(cwd),marker=marker,expected_counters=counters,execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    add('lint_core',[IV,'-g2012','-Wall','-tnull','-s','raw_optical_black_rows','-f','files.f'])
    for top,files in [('raw_optical_black_rows','files.f'),('raw_ob_black_frontend','example/files.f')]:
        add('lint_'+('core_max' if top=='raw_optical_black_rows' else 'actual_max'),[IV,'-g2012','-Wall','-tnull','-s',top,
            f'-P{top}.WIDTH=512',f'-P{top}.HEIGHT=128',f'-P{top}.BITS=12',f'-P{top}.OB_LEFT=32',f'-P{top}.OB_RIGHT=32',f'-P{top}.TAG_W=32','-f',files])
    for p,checked in zip(PROFILES,CHECKED):
        name=p['name'];top='tb_raw_optical_black_rows';image=build/(name+'.vvp')
        args=[IV,'-g2012','-Wall','-s',top]+[f'-P{top}.{k.upper()}={p[k]}' for k in ['w','h','b','l','r','t','wrap']]
        args += ['-o',image,'-f','example/files.f' if p['wrap'] else 'files.f','sim/tb_raw_optical_black_rows.sv']
        add('compile_'+name,args)
        counters={k.upper():p[k] for k in ['w','h','b','l','r','t','wrap']};counters.update(checked=checked,commands=40,done=36,resets=5,cancelled=4)
        add('sim_'+name,[VVP,image],report/name,'PASS RAW_OB ',counters)
    plan=dict(schema='anscore-b42-optical-black-plan-v1',baseline='2e7a6fb51f32e525c1026c28d1f2f45e36545ebc',
        status='SOURCE_REVIEW_PENDING_NOT_RUN',authorization='B complete-source NO_BLOCKER and explicit root first-run authorization required before oracle import/preparation or HDL',
        planning_python_calls=1,oracle_imports=0,oracle_preparations=0,hdl_children=0,automatic_retry=False,fail_stop=True,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,profiles=PROFILES,expected_checks=[c['name'] for c in checks],checks=checks,
        source_sha256={n:sha(ROOT/n) for n in INPUTS},tool_sha256={str(p):sha(p) for p in [IV,VVP]},
        vector_files_before_first_hdl=24,declared_arithmetic_audit=dict(mean_pairs=2837040,max_sum=131040,max_rounded_numerator=131056),
        scope='Exactly3 syntax+4 compile/sim pairs;32 complete/error transactions plus4 cancelled+4 recovery per profile;9898 exact output comparisons. No old/inherited tests or synthesis/PnR/STA/board.',
        archive_policy='Exact bytes, basename.executed.txt to prevent archived .gitattributes from becoming active; package * -text covers every archive')
    write(ROOT/'PRECHECK_PLAN.json',plan);print('Frozen source-only plan',sha(ROOT/'PRECHECK_PLAN.json'),'children',len(checks),flush=True)

def execute(c,stamp,env,report):
    args=[a.replace('<stamp>',stamp) for a in c['argv']];cwd=c['cwd'].replace('<stamp>',stamp)
    start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(args,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    k=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=k.returncode,stdout=k.stdout.decode(errors='replace'),stderr=k.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:cleanup.append(dict(action='tree_kill',error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:cleanup.append(dict(action='group_kill',error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
            except OSError as exc:cleanup.append(dict(action='parent_kill',error=repr(exc)))
            try:out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action='drain',error=repr(exc)))
            except OSError as exc:cleanup.append(dict(action='drain',error=repr(exc)))
            code=child.poll()
    counters=None
    if status=='PASS' and c['marker']:
        lines=[l for l in out.decode(errors='replace').splitlines() if l.startswith(c['marker'])]
        try:
            assert len(lines)==1 and b'$finish' in out
            counters={k:int(v) for word in lines[0].split() if '=' in word for k,v in [word.split('=',1)]}
            assert all(counters.get(k)==v for k,v in c['expected_counters'].items()) and counters['holds']>0 and counters['gaps']>0 and counters['rows']>0
        except (AssertionError,ValueError,KeyError):status='FAIL';reason='Completion/counters disagree with frozen finite plan'
    n=c['name'];(report/(n+'.stdout.txt')).write_bytes(out);(report/(n+'.stderr.txt')).write_bytes(err)
    return dict(name=n,argv=args,cwd=cwd,status=status,returncode=code,reason=reason,counters=counters,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,cleanup=cleanup,seconds=round(time.monotonic()-start,3),
        stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    assert not (ROOT/'reports').exists(),'Any started evidence blocks automatic retry'
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');report=ROOT/'reports'/stamp
    report.mkdir(parents=True);(ROOT/'.build'/stamp).mkdir(parents=True)
    names=INPUTS+['PRECHECK_PLAN.json'];hashes={n:sha(ROOT/n) for n in names};copies={}
    for n in names:
        p=(ROOT/n).resolve();a=report/'executed_inputs'/p.relative_to(REPO);a=a.with_name(a.name+'.executed.txt')
        a.parent.mkdir(parents=True,exist_ok=True);a.write_bytes(p.read_bytes());copies[n]=a.relative_to(report).as_posix()
    plan=json.loads((ROOT/'PRECHECK_PLAN.json').read_text());tools={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}
    records=[];profiles=[];audit={};imports=attempts=0;prepared=complete=False;exception=None
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    def checkpoint(status,event,**extra):
        value=dict(schema='anscore-b42-optical-black-finite-v1',status=status,event=event,source_sha256=hashes,exact_checked_copies=copies,
            tools=tools,profiles=profiles,arithmetic_audit=audit,records=records,expected_checks=plan['expected_checks'],planning_python_calls=1,
            oracle_import_attempts=imports,preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
            automatic_retry=False,fail_stop=True,exception=exception,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED',**extra)
        temp=report/'results.json.tmp'
        with temp.open('w',encoding='utf8',newline='\n') as f:f.write(json.dumps(value,indent=2)+'\n');f.flush();os.fsync(f.fileno())
        temp.replace(report/'results.json')
    checkpoint('INCOMPLETE','before_oracle_import')
    try:
        assert plan['profiles']==PROFILES and set(plan['source_sha256'])==set(INPUTS)
        assert all(hashes[n]==h for n,h in plan['source_sha256'].items()) and tools==plan['tool_sha256'] and all(tools.values())
        assert [c['name'] for c in plan['checks']]==plan['expected_checks']
        spec=importlib.util.spec_from_file_location('b42_optical_black_oracle',ROOT/'reference_model.py');imports+=1
        checkpoint('INCOMPLETE','before_oracle_module_execution');oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
        assert oracle.PROFILES==PROFILES;attempts+=1;checkpoint('INCOMPLETE','before_preparation');profiles,audit=oracle.prepare(report);prepared=True
        assert audit==plan['declared_arithmetic_audit'] and sum(len(p['vectors_sha256']) for p in profiles)==24
        assert sum(p['checked'] for p in profiles)==9898
        for p in profiles:
            c=next(c for c in plan['checks'] if c['name']=='sim_'+p['name'])
            assert all(c['expected_counters'][k]==v for k,v in p['expected_counters'].items())
        checkpoint('INCOMPLETE','after_preparation')
        for c in plan['checks']:
            assert all(sha(ROOT/n)==h and sha(report/copies[n])==h for n,h in hashes.items())
            assert {str(p):sha(p) for p in [IV,VVP]}==tools
            assert all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items())
            r=execute(c,stamp,env,report);records.append(r);checkpoint('INCOMPLETE','after_'+c['name']);print(c['name'],r['status'],flush=True)
            if r['status']!='PASS':return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        source_ok=all(sha(ROOT/n)==h for n,h in hashes.items());archive_ok=all(sha(report/copies[n])==h for n,h in hashes.items())
        vector_ok=all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items());tool_ok={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}==tools
        intact=source_ok and archive_ok and vector_ok and tool_ok
        ok=prepared and complete and [r['name'] for r in records]==plan['expected_checks'] and all(r['status']=='PASS' for r in records)
        status='SOURCE_CHANGED' if not intact else 'PASS' if ok else next((r['status'] for r in records if r['status']!='PASS'),'INCOMPLETE')
        checkpoint(status,'final',sources_unchanged=source_ok,archives_unchanged=archive_ok,vectors_unchanged=vector_ok,tools_unchanged=tool_ok)
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Frozen evidence changed')

if __name__=='__main__':
    if sys.argv[1:]==['--freeze']:freeze()
    elif sys.argv[1:]==['--run']:sys.exit(main())
    else:raise SystemExit('Use --freeze, then full B/root review before --run')
