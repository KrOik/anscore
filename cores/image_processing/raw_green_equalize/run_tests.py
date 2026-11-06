"""SPDX-License-Identifier: Apache-2.0. Reviewed finite plan only; no retry/network/synthesis."""
from pathlib import Path
import datetime,hashlib,importlib.util,json,os,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin';IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
SOURCES=['run_tests.py','reference_model.py','PRECHECK_PLAN.json','rtl/raw_green_equalize.sv',
         'example/green_bayer_rgb.sv','sim/tb_raw_green_equalize.sv','sim/tb_green_bayer_rgb.sv',
         'files.f','example/files.f',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window.v',
         '../../signal_processing/dsp_isp_library/infra/window/stream_window_padded.v',
         '../../signal_processing/dsp_isp_library/isp/bayer/rtl/bayer_demosaic.sv']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

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
    records=[];profiles=[];example={};attempts=0;prepared=False;complete=False;exception=None
    tools_initial={str(p):sha(p) for p in [IV,VVP]}
    def checkpoint(event):
        current=dict(schema='anscore-b39-raw-green-finite-v1',status='INCOMPLETE',
            event=event,source_sha256=hashes,exact_checked_copies=copies,
            preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
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
        assert [check['name'] for check in plan['checks']]==expected
        assert set(plan['source_sha256'])==set(SOURCES)-{'PRECHECK_PLAN.json'}
        assert all(hashes[name]==value for name,value in plan['source_sha256'].items())
        assert tools_initial==plan['tool_sha256']
        spec=importlib.util.spec_from_file_location('b39_raw_green_oracle',ROOT/'reference_model.py')
        oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
        assert oracle.PROFILES==plan['profiles'] and oracle.EXAMPLE==plan['example_profile']
        attempts+=1;checkpoint('before_preparation')
        profiles,example=oracle.prepare(report);prepared=True;checkpoint('after_preparation')
        assert sum(len(p['vectors_sha256']) for p in profiles+[example])==20
        if not run('lint_default',[IV,'-g2012','-Wall','-tnull','-s','raw_green_equalize','-f','files.f']):return 1
        if not run('lint_maximum',[IV,'-g2012','-Wall','-tnull','-s','raw_green_equalize','-Praw_green_equalize.WIDTH=512','-Praw_green_equalize.HEIGHT=128','-Praw_green_equalize.BITS=12','-Praw_green_equalize.TAG_W=32','-f','files.f']):return 1
        if not run('lint_example',[IV,'-g2012','-Wall','-tnull','-s','green_bayer_rgb','-f','example/files.f']):return 1
        for p in profiles:
            name=p['name'];image=build/(name+'.vvp')
            parameters=[f"-Ptb_raw_green_equalize.{key.upper()}={p[key]}" for key in ['w','h','d','t']]
            if not run('compile_'+name,[IV,'-g2012','-Wall','-s','tb_raw_green_equalize',*parameters,'-o',image,'-f','files.f','sim/tb_raw_green_equalize.sv']):return 1
            marker=(f"PASS RAW_GIC W={p['w']} H={p['h']} D={p['d']} T={p['t']} commands=34 done=32 checked={32*p['w']*p['h']} resets=4 ").encode()
            counters=dict(W=p['w'],H=p['h'],D=p['d'],T=p['t'],commands=34,done=32,checked=p['checked_output_records'],resets=4,applied=p['expected_applied'],changed=p['expected_changed'])
            if not run('sim_'+name,[VVP,image],report/name,marker,counters):return 1
        image=build/'example.vvp'
        if not run('compile_example',[IV,'-g2012','-Wall','-s','tb_green_bayer_rgb','-o',image,'-f','example/files.f','sim/tb_raw_green_equalize.sv','sim/tb_green_bayer_rgb.sv']):return 1
        counters=dict(W=16,H=12,D=10,commands=34,done=32,checked=6144,resets=4,applied=example['expected_applied'],changed=example['expected_changed'])
        if not run('sim_example',[VVP,image],report/'example',b'PASS GREEN_RGB W=16 H=12 D=10 commands=34 done=32 checked=6144 resets=4 ',counters):return 1
        complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        sources_unchanged=all(sha(ROOT/name)==h for name,h in hashes.items())
        archives_unchanged=all(sha(report/copies[name])==h for name,h in hashes.items())
        vectors_unchanged=all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items()) and all(sha(report/'example'/n)==h for n,h in example.get('vectors_sha256',{}).items())
        ordered=[record['name'] for record in records]==expected
        ok=prepared and complete and ordered and all(record['status']=='PASS' for record in records)
        tools_final={str(p):sha(p) for p in [IV,VVP]}
        tools_unchanged=tools_final==tools_initial
        intact=sources_unchanged and archives_unchanged and vectors_unchanged and tools_unchanged
        status='SOURCE_CHANGED' if not intact else 'PASS' if ok else next((record['status'] for record in records if record['status']!='PASS'),'INCOMPLETE')
        result=dict(schema='anscore-b39-raw-green-finite-v1',status=status,
            source_sha256=hashes,exact_checked_copies=copies,sources_unchanged=sources_unchanged,
            archives_unchanged=archives_unchanged,vectors_unchanged=vectors_unchanged,
            preparation_attempts=attempts,preparation_complete=prepared,suite_complete=complete,
            expected_checks=expected,records=records,profiles=profiles,example=example,
            automatic_retry=False,exception=exception,tools=tools_final,tools_unchanged=tools_unchanged,
            synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf8',newline='\n') as stream:
            stream.write(json.dumps(result,indent=2)+'\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(report/'results.json')
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Executed source/archive/vector changed')
if __name__=='__main__':sys.exit(main())
