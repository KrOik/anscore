"""SPDX-License-Identifier: Apache-2.0. Reviewed finite plan only; no retry/network/synthesis."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
SOURCES=['run_tests.py','reference_model.py','PRECHECK_PLAN.json','rtl/chroma_median_suppress.sv',
         'example/rgb_chroma_clean.sv','sim/tb_chroma_median_suppress.sv','sim/tb_rgb_chroma_clean.sv',
         'files.f','example/files.f',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window.v',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window_padded.v',
         '../../signal_processing/dsp_isp_library/isp/median/median_network.v',
         '../../signal_processing/dsp_isp_library/isp/csc_stream.v',
         '../../signal_processing/dsp_isp_library/isp/csc_coeffs.vh']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def freeze_plan():
    """Finite source/hash planning only: never imports/prepares the oracle or HDL."""
    plan_path=ROOT/'PRECHECK_PLAN.json'
    if (ROOT/'reports').exists():raise RuntimeError('Existing evidence blocks refreezing')
    planning_calls=(json.loads(plan_path.read_text())['planning_python_calls'] if plan_path.exists() else 0)+1
    profiles=[dict(name='1x1_d8_t1',w=1,h=1,d=8,t=1),
              dict(name='9x7_d10_t8',w=9,h=7,d=10,t=8),
              dict(name='17x13_d10_t32',w=17,h=13,d=10,t=32)]
    example=dict(name='example',w=16,h=12,d=8,t=8)
    build=ROOT/'.build'/'<stamp>';report=ROOT/'reports'/'<stamp>';checks=[]
    def add(name,argv,cwd=ROOT,marker=None):
        checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(cwd),marker=marker,
                           execution_deadline_seconds=20,cleanup_budget_seconds=7))
    add('lint_default',[IV,'-g2012','-Wall','-tnull','-s','chroma_median_suppress','-f','files.f'])
    add('lint_maximum',[IV,'-g2012','-Wall','-tnull','-s','chroma_median_suppress',
        '-Pchroma_median_suppress.WIDTH=512','-Pchroma_median_suppress.HEIGHT=128',
        '-Pchroma_median_suppress.BITS=10','-Pchroma_median_suppress.TAG_W=32','-f','files.f'])
    add('lint_example',[IV,'-g2012','-Wall','-tnull','-s','rgb_chroma_clean','-f','example/files.f'])
    for profile in profiles:
        name=profile['name'];image=build/(name+'.vvp')
        parameters=[f"-Ptb_chroma_median_suppress.{key.upper()}={profile[key]}" for key in ['w','h','d','t']]
        add('compile_'+name,[IV,'-g2012','-Wall','-s','tb_chroma_median_suppress',*parameters,
            '-o',image,'-f','files.f','sim/tb_chroma_median_suppress.sv'])
        marker=(f"PASS CHROMA_MEDIAN W={profile['w']} H={profile['h']} D={profile['d']} T={profile['t']} "
                f"commands=34 done=32 checked={32*profile['w']*profile['h']} resets=4 ")
        add('sim_'+name,[VVP,image],report/name,marker)
    image=build/'example.vvp'
    add('compile_example',[IV,'-g2012','-Wall','-s','tb_rgb_chroma_clean','-o',image,'-f','example/files.f',
        'sim/tb_chroma_median_suppress.sv','sim/tb_rgb_chroma_clean.sv'])
    add('sim_example',[VVP,image],report/'example',
        'PASS CHROMA_RGB W=16 H=12 D=8 commands=34 done=32 checked=6144 resets=4 ')
    value=dict(schema='anscore-b40-chroma-median-plan-v1',baseline='a68ca46815777c15c638c42a03899c83385bf052',
        status='SOURCE_REVIEW_PENDING_NOT_RUN',
        authorization='Complete source/model/TB/plan review NO_BLOCKER from A/B/root and explicit root first-run authorization required before oracle import/preparation or HDL',
        execution_deadline_seconds=20,cleanup_budget_seconds=7,automatic_retry=False,fail_stop=True,
        planning_python_calls=planning_calls,oracle_imports=0,oracle_preparations=0,hdl_children=0,
        profiles=profiles,example_profile=example,expected_checks=[c['name'] for c in checks],checks=checks,
        source_sha256={name:sha(ROOT/name) for name in SOURCES if name!='PRECHECK_PLAN.json'},
        tool_sha256={str(path):sha(path) for path in [IV,VVP]},
        vector_files_before_first_hdl=20,scope='32 complete frames/profile, three live reset scenes; maximum geometry syntax only')
    plan_path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf8',newline='\n')
    print('Frozen source-only plan:',sha(plan_path),'checks',len(checks))

def execute(name,argv,cwd,env,report,marker=None,expected_counters=None):
    argv=list(map(str,argv));start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:
            out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    result=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=result.returncode,stdout=result.stdout.decode(errors='replace'),stderr=result.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:cleanup.append(dict(action='tree_kill',error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:cleanup.append(dict(action='group_kill',error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
            except OSError as exc:cleanup.append(dict(action='parent_kill',error=repr(exc)))
            try:out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:
                out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action='drain',error=repr(exc)))
            except OSError as exc:cleanup.append(dict(action='drain',error=repr(exc)))
            code=child.poll()
    counters=None
    if status=='PASS' and name.startswith('sim_'):
        lines=[line for line in out.splitlines() if marker is not None and line.startswith(marker)]
        if len(lines)!=1 or b'$finish' not in out:
            status='FAIL';reason='unique reviewed completion prefix or $finish absent'
        else:
            try:
                counters={k:int(v) for word in lines[0].decode('ascii').split() if '=' in word for k,v in [word.split('=',1)]}
                if any(counters.get(k)!=v for k,v in expected_counters.items()) or counters.get('holds',0)<=0:
                    status='FAIL';reason='simulation counters disagree with independent frozen-vector oracle'
            except (ValueError,UnicodeError):status='FAIL';reason='malformed simulation counters'
    (report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,reason=reason,
        marker=marker.decode() if marker else None,execution_deadline_seconds=20,cleanup_budget_seconds=7,
        cleanup=cleanup,counters=counters,seconds=round(time.monotonic()-start,3),stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    report_root=ROOT/'reports'
    if report_root.exists() and any(path.is_dir() for path in report_root.iterdir()):
        print('Existing started report directory: retain/review it; no automatic retry.',file=sys.stderr);return 1
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    hashes={name:sha(ROOT/name) for name in SOURCES};copies={}
    for name in SOURCES:
        source=(ROOT/name).resolve();target=report/'executed_inputs'/source.relative_to(REPO)
        target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(source.read_bytes())
        copies[name]=target.relative_to(report).as_posix()
    plan=json.loads((ROOT/'PRECHECK_PLAN.json').read_text());expected=plan['expected_checks']
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    records=[];profiles=[];example={};imports=0;attempts=0;prepared=False;complete=False;exception=None;preflight_status=None
    tools_initial={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}
    def checkpoint(event):
        current=dict(schema='anscore-b40-chroma-median-finite-v1',status='INCOMPLETE',
            event=event,source_sha256=hashes,exact_checked_copies=copies,
            preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
            oracle_import_attempts=imports,planning_python_calls=plan['planning_python_calls'],
            expected_checks=expected,records=records,profiles=profiles,example=example,
            automatic_retry=False,tools=tools_initial,synthesis='NOT_RUN',pnr='NOT_RUN',
            sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf8',newline='\n') as stream:
            stream.write(json.dumps(current,indent=2)+'\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(report/'results.json')
    checkpoint('before_oracle_import')
    def run(name,argv,cwd=ROOT,marker=None,counters=None):
        assert all(sha(ROOT/n)==h and sha(report/copies[n])==h for n,h in hashes.items())
        assert {str(p):sha(p) for p in [IV,VVP]}==tools_initial
        reviewed=plan['checks'][len(records)]
        assert reviewed['name']==name
        assert [arg.replace('<stamp>',stamp) for arg in reviewed['argv']]==list(map(str,argv))
        assert reviewed['cwd'].replace('<stamp>',stamp)==str(cwd)
        assert reviewed['marker']==(marker.decode() if marker else None)
        result=execute(name,argv,cwd,env,report,marker,counters);records.append(result)
        checkpoint('after_'+name);print(name,result['status'],flush=True)
        return result['status']=='PASS'
    try:
        if any(value is None for value in tools_initial.values()):
            preflight_status='NOT_RUN';return 1
        assert [check['name'] for check in plan['checks']]==expected
        assert set(plan['source_sha256'])==set(SOURCES)-{'PRECHECK_PLAN.json'}
        assert all(hashes[name]==value for name,value in plan['source_sha256'].items())
        assert tools_initial==plan['tool_sha256']
        spec=importlib.util.spec_from_file_location('b40_chroma_oracle',ROOT/'reference_model.py')
        imports+=1;checkpoint('before_oracle_module_execution')
        oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
        assert oracle.PROFILES==plan['profiles'] and oracle.EXAMPLE==plan['example_profile']
        attempts+=1;checkpoint('before_preparation')
        profiles,example=oracle.prepare(report);prepared=True;checkpoint('after_preparation')
        assert sum(len(p['vectors_sha256']) for p in profiles+[example])==20
        if not run('lint_default',[IV,'-g2012','-Wall','-tnull','-s','chroma_median_suppress','-f','files.f']):return 1
        if not run('lint_maximum',[IV,'-g2012','-Wall','-tnull','-s','chroma_median_suppress','-Pchroma_median_suppress.WIDTH=512','-Pchroma_median_suppress.HEIGHT=128','-Pchroma_median_suppress.BITS=10','-Pchroma_median_suppress.TAG_W=32','-f','files.f']):return 1
        if not run('lint_example',[IV,'-g2012','-Wall','-tnull','-s','rgb_chroma_clean','-f','example/files.f']):return 1
        for p in profiles:
            name=p['name'];image=build/(name+'.vvp')
            parameters=[f"-Ptb_chroma_median_suppress.{key.upper()}={p[key]}" for key in ['w','h','d','t']]
            if not run('compile_'+name,[IV,'-g2012','-Wall','-s','tb_chroma_median_suppress',*parameters,'-o',image,'-f','files.f','sim/tb_chroma_median_suppress.sv']):return 1
            marker=(f"PASS CHROMA_MEDIAN W={p['w']} H={p['h']} D={p['d']} T={p['t']} commands=34 done=32 checked={32*p['w']*p['h']} resets=4 ").encode()
            counters=dict(W=p['w'],H=p['h'],D=p['d'],T=p['t'],commands=34,done=32,checked=p['checked_output_records'],resets=4,applied=p['expected_applied'],changed=p['expected_changed'])
            if not run('sim_'+name,[VVP,image],report/name,marker,counters):return 1
        image=build/'example.vvp'
        if not run('compile_example',[IV,'-g2012','-Wall','-s','tb_rgb_chroma_clean','-o',image,'-f','example/files.f','sim/tb_chroma_median_suppress.sv','sim/tb_rgb_chroma_clean.sv']):return 1
        counters=dict(W=16,H=12,D=8,commands=34,done=32,checked=6144,resets=4,applied=example['expected_applied'],changed=example['expected_changed'])
        if not run('sim_example',[VVP,image],report/'example',b'PASS CHROMA_RGB W=16 H=12 D=8 commands=34 done=32 checked=6144 resets=4 ',counters):return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        sources_unchanged=all(sha(ROOT/name)==h for name,h in hashes.items())
        archives_unchanged=all(sha(report/copies[name])==h for name,h in hashes.items())
        vectors_unchanged=all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items()) and all(sha(report/'example'/n)==h for n,h in example.get('vectors_sha256',{}).items())
        ordered=[record['name'] for record in records]==expected
        ok=prepared and complete and ordered and all(record['status']=='PASS' for record in records)
        tools_final={str(p):sha(p) if p.is_file() else None for p in [IV,VVP]}
        tools_unchanged=tools_final==tools_initial
        intact=sources_unchanged and archives_unchanged and vectors_unchanged and tools_unchanged
        status='SOURCE_CHANGED' if not intact else 'PASS' if ok else next((record['status'] for record in records if record['status']!='PASS'),preflight_status or 'INCOMPLETE')
        result=dict(schema='anscore-b40-chroma-median-finite-v1',status=status,
            source_sha256=hashes,exact_checked_copies=copies,sources_unchanged=sources_unchanged,
            archives_unchanged=archives_unchanged,vectors_unchanged=vectors_unchanged,
            preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
            oracle_import_attempts=imports,planning_python_calls=plan['planning_python_calls'],
            expected_checks=expected,records=records,profiles=profiles,example=example,
            automatic_retry=False,exception=exception,tools=tools_final,tools_unchanged=tools_unchanged,
            synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf8',newline='\n') as stream:
            stream.write(json.dumps(result,indent=2)+'\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(report/'results.json')
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Executed source/archive/vector changed')

if __name__=='__main__':
    if sys.argv[1:]==['--freeze']:freeze_plan()
    elif sys.argv[1:]==['--run']:sys.exit(main())
    else:raise SystemExit('Use --freeze for source-only planning; --run requires explicit root authorization.')

