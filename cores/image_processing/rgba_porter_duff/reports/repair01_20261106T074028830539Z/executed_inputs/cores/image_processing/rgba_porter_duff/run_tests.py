"""SPDX-License-Identifier: Apache-2.0. One reviewed finite run, fail-stop, no retries."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,signal,subprocess,sys,time,traceback
sys.dont_write_bytecode=True

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
SOURCES=['.gitattributes','rtl/rgba_porter_duff.sv','rtl/rgba_pair_premultiply.sv',
         'example/dual_indexed_porter_duff.sv','sim/tb_rgba_porter_duff.sv','sim/tb_dual_indexed_porter_duff.sv',
         'reference_model.py','run_tests.py','files.f','example/files.f','README.md','ARCHITECTURE.md',
         'SOURCES.md','references.json','LICENSE','../indexed_texture_sampler/rtl/indexed_texture_sampler.sv','PRECHECK_PLAN.json']
PROFILES=[dict(name='core_t1',kind='core',t=1),dict(name='core_t32',kind='core',t=32),
          dict(name='pair_1x1_t1',kind='pair',w=1,h=1,t=1),dict(name='pair_8x8_t28',kind='pair',w=8,h=8,t=28)]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write_json(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')

def freeze():
    if (ROOT/'reports').exists():raise RuntimeError('Started evidence blocks refreeze')
    p=ROOT/'PRECHECK_PLAN.json';calls=(json.loads(p.read_text())['planning_python_calls'] if p.exists() else 0)+1
    checks=[];build=ROOT/'.build'/'<stamp>';report=ROOT/'reports'/'<stamp>'
    def add(name,args,cwd=ROOT,marker=None,counters=None):
        checks.append(dict(name=name,argv=list(map(str,args)),cwd=str(cwd),marker=marker,expected_counters=counters,
                           execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    add('lint_core',[IV,'-g2012','-Wall','-tnull','-s','rgba_porter_duff','-f','files.f'])
    add('lint_core_max_tag',[IV,'-g2012','-Wall','-tnull','-s','rgba_porter_duff','-Prgba_porter_duff.TAG_W=32','-f','files.f'])
    add('lint_pair_max',[IV,'-g2012','-Wall','-tnull','-s','dual_indexed_porter_duff',
        '-Pdual_indexed_porter_duff.TEX_WIDTH=256','-Pdual_indexed_porter_duff.TEX_HEIGHT=256',
        '-Pdual_indexed_porter_duff.TAG_W=28','-f','example/files.f'])
    for profile in PROFILES:
        name=profile['name'];core=profile['kind']=='core';top='tb_rgba_porter_duff' if core else 'tb_dual_indexed_porter_duff'
        args=[IV,'-g2012','-Wall','-s',top,f'-P{top}.T={profile["t"]}']
        if not core:args += [f'-P{top}.W={profile["w"]}',f'-P{top}.H={profile["h"]}']
        image=build/(name+'.vvp');args += ['-o',image,'-f','files.f' if core else 'example/files.f',f'sim/{top}.sv']
        add('compile_'+name,args)
        counters=dict(T=profile['t'],checked=4096,resets=4,quant=130051) if core else dict(W=profile['w'],H=profile['h'],T=profile['t'],checked=516,resets=3,commands=9,responses=8,pending=1)
        marker='PASS RGBA_PD_CORE ' if core else 'PASS RGBA_PD_PAIR '
        add('sim_'+name,[VVP,image],report/name,marker,counters)
    write_json(p,dict(schema='anscore-b41-rgba-porter-duff-plan-v1',baseline='31a83135a22f845d85840524986895217567625c',
        status='SOURCE_REVIEW_PENDING_NOT_RUN',authorization='B complete source/model/TB/runner NO_BLOCKER and explicit root authorization required before oracle import/preparation or HDL',
        automatic_retry=False,fail_stop=True,planning_python_calls=calls,oracle_imports=0,oracle_preparations=0,hdl_children=0,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,profiles=PROFILES,
        expected_checks=[c['name'] for c in checks],checks=checks,vector_files_before_first_hdl=20,
        source_sha256={n:sha(ROOT/n) for n in SOURCES if n!='PRECHECK_PLAN.json'},
        tool_sha256={str(p):sha(p) for p in [IV,VVP]},scope='Four finite simulations; quantizer exhaustive 0..130050, all alpha/mode extrema, source gaps, sink holds, live resets, drained management arbitration. Maximum storage is syntax only.'))
    print('Frozen source-only plan',sha(p),'checks',len(checks),flush=True)

def execute(check,stamp,env,report):
    argv=[arg.replace('<stamp>',stamp) for arg in check['argv']];cwd=check['cwd'].replace('<stamp>',stamp)
    start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    r=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=r.returncode,stdout=r.stdout.decode(errors='replace'),stderr=r.stderr.decode(errors='replace')))
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
    if status=='PASS' and check['marker']:
        lines=[line for line in out.decode(errors='replace').splitlines() if line.startswith(check['marker'])]
        try:
            assert len(lines)==1 and b'$finish' in out
            counters={k:int(v) for word in lines[0].split() if '=' in word for k,v in [word.split('=',1)]}
            assert all(counters.get(k)==v for k,v in check['expected_counters'].items())
            assert counters['holds']>0 and counters['gaps']>0
        except (AssertionError,ValueError,KeyError):status='FAIL';reason='Completion/counters disagree with reviewed finite plan'
    name=check['name'];(report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    return dict(name=name,argv=argv,cwd=cwd,status=status,returncode=code,reason=reason,counters=counters,
        execution_deadline_seconds=20,tree_kill_seconds=5,drain_seconds=2,cleanup=cleanup,seconds=round(time.monotonic()-start,3),
        stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    if (ROOT/'reports').exists():raise RuntimeError('Any started report blocks automatic retry; retain and review evidence')
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ');report=ROOT/'reports'/stamp
    report.mkdir(parents=True,exist_ok=False);(ROOT/'.build'/stamp).mkdir(parents=True,exist_ok=False)
    hashes={n:sha(ROOT/n) for n in SOURCES};copies={}
    for n in SOURCES:
        source=(ROOT/n).resolve();target=report/'executed_inputs'/source.relative_to(REPO)
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes());copies[n]=target.relative_to(report).as_posix()
    plan=json.loads((ROOT/'PRECHECK_PLAN.json').read_text());tools={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}
    profiles=[];audit={};records=[];imports=attempts=0;prepared=complete=False;exception=None;preflight=None
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    def checkpoint(status,event,**extra):
        value=dict(schema='anscore-b41-rgba-porter-duff-finite-v1',status=status,event=event,
            source_sha256=hashes,exact_checked_copies=copies,tools=tools,profiles=profiles,arithmetic_audit=audit,
            records=records,expected_checks=plan['expected_checks'],planning_python_calls=plan['planning_python_calls'],
            oracle_import_attempts=imports,preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
            automatic_retry=False,fail_stop=True,exception=exception,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED',**extra)
        tmp=report/'results.json.tmp'
        with tmp.open('w',encoding='utf8',newline='\n') as f:f.write(json.dumps(value,indent=2)+'\n');f.flush();os.fsync(f.fileno())
        tmp.replace(report/'results.json')
    checkpoint('INCOMPLETE','before_oracle_import')
    try:
        assert plan['profiles']==PROFILES
        assert set(plan['source_sha256'])==set(SOURCES)-{'PRECHECK_PLAN.json'}
        assert all(hashes[n]==h for n,h in plan['source_sha256'].items())
        assert all(v is not None for v in tools.values()) and tools==plan['tool_sha256']
        assert [c['name'] for c in plan['checks']]==plan['expected_checks']
        spec=importlib.util.spec_from_file_location('b41_rgba_oracle',ROOT/'reference_model.py');imports+=1
        checkpoint('INCOMPLETE','before_oracle_module_execution');oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
        assert oracle.PROFILES==PROFILES
        attempts+=1;checkpoint('INCOMPLETE','before_preparation');profiles,audit=oracle.prepare(report);prepared=True
        assert sum(len(p['vectors_sha256']) for p in profiles)==20
        for p in profiles:
            c=next(c for c in plan['checks'] if c['name']=='sim_'+p['name'])
            assert all(c['expected_counters'][k]==v for k,v in p['expected_counters'].items())
        checkpoint('INCOMPLETE','after_preparation')
        for check in plan['checks']:
            assert all(sha(ROOT/n)==h and sha(report/copies[n])==h for n,h in hashes.items())
            assert {str(p):sha(p) for p in [IV,VVP]}==tools
            assert all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items())
            r=execute(check,stamp,env,report);records.append(r);checkpoint('INCOMPLETE','after_'+check['name']);print(check['name'],r['status'],flush=True)
            if r['status']!='PASS':return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        sources_ok=all(sha(ROOT/n)==h for n,h in hashes.items());archives_ok=all(sha(report/copies[n])==h for n,h in hashes.items())
        vectors_ok=all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items())
        tools_ok={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}==tools
        intact=sources_ok and archives_ok and vectors_ok and tools_ok
        ordered=[r['name'] for r in records]==plan['expected_checks']
        ok=prepared and complete and ordered and all(r['status']=='PASS' for r in records)
        status='SOURCE_CHANGED' if not intact else 'PASS' if ok else next((r['status'] for r in records if r['status']!='PASS'),preflight or 'INCOMPLETE')
        checkpoint(status,'final',sources_unchanged=sources_ok,archives_unchanged=archives_ok,vectors_unchanged=vectors_ok,tools_unchanged=tools_ok)
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Frozen evidence changed')

if __name__=='__main__':
    if sys.argv[1:]==['--freeze']:freeze()
    elif sys.argv[1:]==['--run']:sys.exit(main())
    else:raise SystemExit('Use --freeze for source-only planning; --run requires reviewed root authorization')
