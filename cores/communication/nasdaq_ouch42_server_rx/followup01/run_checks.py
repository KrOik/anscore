"""SPDX-License-Identifier: Apache-2.0. B46 A independent EOF followup01 finite source gate.

This helper is itself reviewed/sealed source. Never run before root+peer approval.
It imports only stdlib; there are zero preparation children or project imports.
"""
from pathlib import Path
import argparse,datetime,hashlib,json,os,re,subprocess,sys,time,traceback
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
BASELINE='50b8d36a3ce65cae5c4b3ab4604fa24f3567204b'
PLAN=HERE/'FINITE_PLAN.json';SEAL=HERE/'SOURCE_SEAL.json';REVIEW=HERE/'SOURCE_REVIEW.json'
GUARD=REPO/'.git/anscore-b46-ouch42-followup01-once.json'
GATE='B46_NASDAQ_OUCH42_SERVER_RX_FOLLOWUP01_ONCE'
OLD_REPORT=ROOT/'reports/20261106T141729488803Z'


def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path): return json.loads(path.read_bytes())


def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as f:
        json.dump(value,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())


def head_commit():
    git_dir=REPO/'.git';value=(git_dir/'HEAD').read_text().strip()
    if not value.startswith('ref: '): return value
    ref=value[5:];p=git_dir/ref
    if p.is_file(): return p.read_text().strip()
    for line in (git_dir/'packed-refs').read_text().splitlines():
        if line and not line.startswith(('#','^')):
            sha,name=line.split(' ',1)
            if name==ref: return sha
    raise RuntimeError('baseline HEAD ref not found')


def commands(stamp):
    out=HERE/'reports'/stamp;archive=out/'executed_inputs'/ROOT.relative_to(REPO)
    work=HERE/'.work'/stamp;vectors=OLD_REPORT/'vectors';checks=[]
    def add(name,kind,argv,marker=None):
        checks.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(archive),
            marker=marker,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    for tag in (1,8,32):
        label=f'core_t{tag}';image=work/(label+'.vvp')
        add('compile_'+label,'HDL',[BIN/'iverilog.exe','-g2012','-Wall','-s',
            'tb_nasdaq_ouch42_server_rx',f'-Ptb_nasdaq_ouch42_server_rx.T={tag}',
            '-o',image,'-f','files.f','followup01/sim/tb_nasdaq_ouch42_server_rx.sv'])
        add('sim_'+label,'HDL',[BIN/'vvp.exe',image,'+vectors='+(vectors/(label+'.txt')).as_posix()],
            'B46_A_CORE_PASS ')
    for depth,tag in ((128,8),(4096,32)):
        label=f'soup_d{depth}_t{tag}';image=work/(label+'.vvp')
        add('compile_'+label,'HDL',[BIN/'iverilog.exe','-g2012','-Wall','-s',
            'tb_soupbintcp_ouch42_rx',f'-Ptb_soupbintcp_ouch42_rx.D={depth}',
            f'-Ptb_soupbintcp_ouch42_rx.T={tag}','-o',image,'-f','example/files.f',
            'followup01/sim/tb_soupbintcp_ouch42_rx.sv'])
        add('sim_'+label,'HDL',[BIN/'vvp.exe',image,'+vectors='+(vectors/(label+'.txt')).as_posix()],
            'B46_A_SOUP_PASS ')
    return checks


def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    record=dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
        process_exited=False,output_capture_complete=False,process_evidence_saved=False)
    report['preparations' if spec['kind']=='PREPARATION' else 'checks'].append(record)
    report['active_child']=dict(name=spec['name'],pid=None,status='STARTING');save()
    stdout_path=out/(spec['name']+'.stdout.raw');stderr_path=out/(spec['name']+'.stderr.raw')
    try:
        with stdout_path.open('xb',buffering=0) as so,stderr_path.open('xb',buffering=0) as se:
            try:
                child=subprocess.Popen(spec['argv'],cwd=spec['cwd'],env=env,stdin=subprocess.DEVNULL,
                    stdout=so,stderr=se,creationflags=subprocess.CREATE_NO_WINDOW)
                record.update(pid=child.pid,status='RUNNING')
                report['active_child']=dict(name=spec['name'],pid=child.pid,status='RUNNING');save()
                remaining=20-(time.monotonic()-start)
                if remaining<=0: raise subprocess.TimeoutExpired(spec['name'],20)
                child.wait(timeout=remaining)
                elapsed=time.monotonic()-start
                record.update(execution_seconds=elapsed,
                    status='TIMEOUT' if elapsed>=20 else ('PASS' if child.returncode==0 else 'FAIL'))
            except subprocess.TimeoutExpired:
                record['status']='TIMEOUT'
            except Exception:
                record.update(status='SPAWN_FAILED' if child is None else 'HARNESS_FAILED',
                    exception=traceback.format_exc())
            finally:
                alive=False
                if child is not None:
                    try: alive=child.poll() is None
                    except Exception as exc: alive=True;record['initial_poll_error']=repr(exc)
                if alive:
                    entry=dict(kind='TREE_TERMINATION',status='STARTING',hard_seconds=5)
                    record['cleanup'].append(entry);hs=time.monotonic()
                    ho=out/(spec['name']+'.taskkill.stdout.raw')
                    he=out/(spec['name']+'.taskkill.stderr.raw')
                    try:
                        try: save()
                        except Exception as exc: entry['record_error']=repr(exc)
                        with ho.open('xb',buffering=0) as ko,he.open('xb',buffering=0) as ke:
                            helper=subprocess.Popen([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),
                                '/PID',str(child.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,
                                creationflags=subprocess.CREATE_NO_WINDOW)
                            entry.update(pid=helper.pid,status='RUNNING')
                            try: save()
                            except Exception as exc: entry['pid_record_error']=repr(exc)
                            remaining=5-(time.monotonic()-hs)
                            if remaining<=0: raise subprocess.TimeoutExpired('taskkill',5)
                            helper.wait(timeout=remaining)
                            entry['status']='TIMEOUT' if time.monotonic()-hs>=5 else 'EXITED'
                            ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                    except subprocess.TimeoutExpired: entry['status']='TIMEOUT'
                    except Exception as exc: entry['error']=repr(exc)
                    finally:
                        # These independent nonwaiting kills run even if raw open,
                        # spawn, PID save, helper wait or raw persistence failed.
                        helper_alive=False
                        if helper is not None:
                            try: helper_alive=helper.poll() is None
                            except Exception as exc:
                                helper_alive=True;entry['helper_poll_error']=repr(exc)
                        if helper_alive:
                            try: helper.kill();entry['helper_direct_kill']='ISSUED'
                            except Exception as exc: entry['helper_kill_error']=repr(exc)
                        try: target_alive=child.poll() is None
                        except Exception as exc:
                            target_alive=True;entry['target_poll_error']=repr(exc)
                        if target_alive:
                            try: child.kill();entry['target_direct_kill']='ISSUED'
                            except Exception as exc: entry['target_kill_error']=repr(exc)
                    entry['helper_seconds']=time.monotonic()-hs
                    if entry['helper_seconds']>=5: entry['status']='TIMEOUT'
                    observation=time.monotonic()
                    try: child.wait(timeout=2)  # Sole target observation after termination.
                    except subprocess.TimeoutExpired: entry['target_observation']='UNCONFIRMED'
                    except Exception as exc: entry['target_wait_error']=repr(exc)
                    entry['target_observation_seconds']=time.monotonic()-observation
                    if entry['target_observation_seconds']>=2: entry['target_observation_deadline_exceeded']=True
                    # Final helper observation happens after the sole target interval.
                    try:
                        entry['exit_code']=None if helper is None else helper.poll()
                        entry['process_exited']=helper is not None and entry['exit_code'] is not None
                        entry['active_helper']=helper.pid if helper is not None and entry['exit_code'] is None else None
                    except Exception as exc:
                        entry.update(terminal_poll_error=repr(exc),process_exited=False,
                            active_helper=helper.pid if helper is not None else None)
                    entry['capture_errors']=[]
                    for stream,path in (('stdout',ho),('stderr',he)):
                        try:
                            with path.open('ab',buffering=0) as raw: raw.flush();os.fsync(raw.fileno())
                            entry[stream]=dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
                        except Exception as exc: entry['capture_errors'].append(dict(stream=stream,error=repr(exc)))
                    entry['output_capture_complete']=entry['process_exited'] and not entry['capture_errors']
                so.flush();se.flush();os.fsync(so.fileno());os.fsync(se.fileno())
    except Exception:
        record.update(status='HARNESS_FAILED',capture_exception=traceback.format_exc())
    try: code=child.poll() if child is not None else None
    except Exception as exc: code=None;record['terminal_poll_error']=repr(exc)
    record.update(exit_code=code,process_exited=child is not None and code is not None,
        seconds=time.monotonic()-start,capture_errors=[])
    for stream,path in (('stdout',stdout_path),('stderr',stderr_path)):
        try: record[stream]=dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
        except Exception as exc: record['capture_errors'].append(dict(stream=stream,error=repr(exc)))
    record['output_capture_complete']=record['process_exited'] and not record['capture_errors'] and all(
        x.get('output_capture_complete',False) for x in record['cleanup'])
    if child is not None and code is None:
        record['status']='TERMINATION_UNCONFIRMED'
        report['active_child']=dict(name=spec['name'],pid=child.pid,status=record['status'])
    else: report['active_child']=None
    report['active_helpers']=[x['active_helper'] for x in record['cleanup'] if x.get('active_helper')]
    if report['active_helpers']: record['status']='HELPER_TERMINATION_UNCONFIRMED'
    if record['status']=='PASS' and not record['output_capture_complete']: record['status']='CAPTURE_INCOMPLETE'
    record['process_evidence_saved']=True
    terminal_record=out/(spec['name']+'.json')
    durable(terminal_record,record)
    report['child_records'][terminal_record.name]=dict(sha256=digest(terminal_record),bytes=terminal_record.stat().st_size)
    save() # Before any receipt, image or marker parsing.
    return record


def run():
    assert os.name=='nt' and head_commit()==BASELINE
    plan,seal,approval=load(PLAN),load(SEAL),load(REVIEW)
    assert plan['baseline_commit']==seal['baseline_commit']==approval['baseline_commit']==BASELINE
    assert plan['status']=='SOURCE_REVIEW_PENDING_NOT_EXECUTED'
    assert plan['source_seal_sha256']==digest(SEAL)==approval['source_seal_sha256']
    assert approval['plan_sha256']==digest(PLAN) and approval['execution_gate']==GATE
    assert approval['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and approval['explicit_unique_execution_gate'] is True
    assert approval['root_review']['reviewer']=='root' and approval['peer_review']['reviewer']!='root'
    assert approval['root_review']['verdict']==approval['peer_review']['verdict']=='NO_BLOCKER'
    assert plan['commands']==commands('<stamp>')
    assert plan['expected_preparation_children']==plan['oracle_imports']==0
    assert plan['expected_hdl_children']==10 and plan['expected_successful_simulations']==5
    assert plan['automatic_retry'] is False and plan['fail_stop'] is True
    assert plan['source_sha256']=={x['path']:x['sha256'] for x in seal['files']}
    for x in seal['files']:
        p=REPO/x['path'];assert digest(p)==x['sha256'] and p.stat().st_size==x['bytes']
    required_tools={str(Path(sys.executable)),str(BIN/'iverilog.exe'),str(BIN/'vvp.exe'),
                    str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe')}
    assert required_tools<={x['path'] for x in plan['tools']}
    for x in plan['tools']:
        p=Path(x['path']);assert digest(p)==x['sha256'] and p.stat().st_size==x['bytes']
    old=load(OLD_REPORT/'results.json')
    assert digest(OLD_REPORT/'results.json')==plan['original_attempt']['results_sha256']
    assert old['status']=='FAIL_STOP' and old['archive_complete'] and old['inputs_unchanged']
    assert old['active_child'] is None and not old['active_helpers'] and not old['suite_complete']
    assert len(old['preparations'])==1 and old['preparations'][0]['status']=='PASS'
    expected_old=['syntax_core_t1','syntax_core_t8','syntax_core_t32',
        'syntax_soup_d128_t8','syntax_soup_d4096_t32','compile_core_t1','sim_core_t1']
    assert [x['name'] for x in old['checks']]==expected_old
    for record in old['preparations']+old['checks']:
        failed=record['name']=='sim_core_t1'
        assert record['status']==('FAIL' if failed else 'PASS') and record['exit_code']==(1 if failed else 0)
        assert record['process_evidence_saved'] and record['process_exited'] and record['output_capture_complete']
        assert not record['cleanup'] and record['execution_seconds']<20
        saved=OLD_REPORT/(record['name']+'.json');pin=old['child_records'][saved.name]
        assert digest(saved)==pin['sha256'] and saved.stat().st_size==pin['bytes'] and load(saved)==record
        for stream in ('stdout','stderr'):
            pin=record[stream];raw=OLD_REPORT/pin['path']
            assert digest(raw)==pin['sha256'] and raw.stat().st_size==pin['bytes']
    for source in old['sources']:
        assert digest(REPO/source['path'])==source['sha256']==digest(OLD_REPORT/source['archive'])
    for current,name,key in [(ROOT/'FINITE_PLAN.json','plan.json','plan_sha256'),
            (ROOT/'SOURCE_SEAL.json','seal.json','source_seal_sha256'),
            (ROOT/'SOURCE_REVIEW.json','review.json','approval_sha256')]:
        assert digest(current)==old[key]==digest(OLD_REPORT/name)
    receipt=load(OLD_REPORT/'vectors/receipt.json')
    assert receipt==old['vector_receipt']
    for vector in old['vectors']:
        path=OLD_REPORT/'vectors'/vector['path']
        assert digest(path)==vector['sha256'] and path.stat().st_size==vector['bytes']
    assert not GUARD.exists() and not (HERE/'reports').exists() and not (HERE/'.work').exists()
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    durable(GUARD,dict(status='ATTEMPT_STARTED',run_id=stamp,baseline_commit=BASELINE,
        execution_gate=GATE,plan_sha256=digest(PLAN),source_seal_sha256=digest(SEAL),
        approval_sha256=digest(REVIEW),automatic_retry=False),exclusive=True)
    out=HERE/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (HERE/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(status='INCOMPLETE',baseline_commit=BASELINE,run_id=stamp,
        guard_sha256=digest(GUARD),plan_sha256=digest(PLAN),source_seal_sha256=digest(SEAL),
        approval_sha256=digest(REVIEW),preparations=[],checks=[],child_records={},sources=[],tools=plan['tools'],
        active_child=None,active_helpers=[],archive_complete=False,suite_complete=False,
        automatic_retry=False,preparation_children=0,oracle_imports=0,numerical_planning_calls=0,
        vectors=old['vectors'],vector_receipt=receipt,retained_prior_attempt=plan['original_attempt'],
        numerical_preparation_calls_this_followup=0,synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
    def save():
        temporary=out/'results.json.tmp';durable(temporary,report);temporary.replace(out/'results.json')
    def archive(path,raw):
        path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('xb') as f: f.write(raw);f.flush();os.fsync(f.fileno())
    def invariant(spec=None):
        assert report['archive_complete'] and head_commit()==BASELINE
        assert digest(GUARD)==report['guard_sha256']
        for x in report['sources']:
            current=REPO/x['path'];copy=out/x['archive']
            assert digest(current)==x['sha256']==digest(copy)
            assert current.stat().st_size==x['bytes']==copy.stat().st_size
        for name,current,key in [('plan.json',PLAN,'plan_sha256'),('seal.json',SEAL,'source_seal_sha256'),
                ('review.json',REVIEW,'approval_sha256')]: assert digest(current)==report[key]==digest(out/name)
        for x in report['tools']: assert digest(Path(x['path']))==x['sha256']
        for name,x in report['child_records'].items():
            p=out/name;assert digest(p)==x['sha256'] and p.stat().st_size==x['bytes']
        for r in report['preparations']+report['checks']:
            assert r['process_evidence_saved'] and load(out/(r['name']+'.json'))==r
            for entry in [r]+r['cleanup']:
                for stream in ('stdout','stderr'):
                    if stream in entry:
                        x=entry[stream];p=out/x['path'];assert digest(p)==x['sha256'] and p.stat().st_size==x['bytes']
            if 'image' in r: assert digest(REPO/r['image'])==r['image_sha256']
        for x in report.get('vectors',[]):
            p=OLD_REPORT/'vectors'/x['path'];assert digest(p)==x['sha256'] and p.stat().st_size==x['bytes']
        if spec and spec['name'].startswith('sim_'):
            prior=next(r for r in report['checks'] if r['name']=='compile_'+spec['name'][4:])
            assert prior['status']=='PASS' and digest(Path(spec['argv'][1]))==prior['image_sha256']
    save()
    try:
        for source,name in ((PLAN,'plan.json'),(SEAL,'seal.json'),(REVIEW,'review.json')): archive(out/name,source.read_bytes())
        for x in seal['files']:
            destination=out/'executed_inputs'/x['path']
            if destination.name=='.gitattributes': destination=destination.with_name('.gitattributes.executed.txt')
            archive(destination,(REPO/x['path']).read_bytes())
            report['sources'].append(dict(x,archive=destination.relative_to(out).as_posix()))
        report['archive_complete']=True;save()
        env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),
            PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1')
        report['environment']=dict(PATH=env['PATH'],PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1')
        for spec in commands(stamp):
            invariant(spec)
            record=execute(spec,env,out,report,save)
            if record['status']=='PASS' and spec['marker']:
                raw=(out/record['stdout']['path']).read_bytes()
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'].encode())]
                if len(lines)!=1 or record['stderr']['bytes']!=0: record['status']='FAIL_MARKER'
                else:
                    observed={key.decode():int(value) for key,value in re.findall(rb'\b(\w+)=(-?\d+)',lines[0])}
                    if 'CORE' in spec['marker']:
                        tag=int(spec['name'].split('_t')[1]);x=receipt['core'][str(tag)]
                        expected=dict(T=tag,cases=2557,checks=2560,bytes=x['bytes']+35,resets=4,canceled=3,holds=10240)
                    else:
                        match=re.fullmatch(r'sim_soup_d(\d+)_t(\d+)',spec['name']);depth,tag=map(int,match.groups())
                        x=receipt['integration'][f'{depth}_{tag}']
                        expected=dict(D=depth,T=tag,cases=29,checks=35,bytes=x['bytes']+170,payload=669,resets=9,canceled=3,holds=116)
                    record.update(observed=observed,expected=expected)
                    if observed!=expected: record['status']='FAIL_COVERAGE'
            if record['status']=='PASS' and spec['name'].startswith('compile_'):
                image=Path(spec['argv'][spec['argv'].index('-o')+1]);record.update(
                    image=image.relative_to(REPO).as_posix(),image_sha256=digest(image))
            if spec['name'].startswith('sim_'): record['execution_image_sha256']=digest(Path(spec['argv'][1]))
            terminal_record=out/(spec['name']+'.json');durable(terminal_record,record)
            report['child_records'][terminal_record.name]=dict(sha256=digest(terminal_record),bytes=terminal_record.stat().st_size)
            save();invariant()
            print(spec['name'],record['status'],flush=True)
            if record['status']!='PASS': report['status']='FAIL_STOP';break
        else: report['status']='PASS'
    except Exception: report.update(status='RUNNER_FAILED',exception=traceback.format_exc())
    finally:
        try: invariant();unchanged=True
        except Exception: unchanged=False
        observed=[x['name'] for x in report['preparations']+report['checks']]
        sequence=observed==[x['name'] for x in commands(stamp)]
        complete=report['status']=='PASS' and unchanged and sequence and not report['active_child'] and not report['active_helpers']
        if report['status']=='PASS' and not complete: report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        report.update(inputs_unchanged=unchanged,exact_plan_executed=sequence,suite_complete=complete,
            maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if complete else ['RTL_CANDIDATE','HW_UNVERIFIED'])
        save();print(out.relative_to(HERE).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--execute',required=True,action='store_true')
    parser.parse_args();raise SystemExit(run())
