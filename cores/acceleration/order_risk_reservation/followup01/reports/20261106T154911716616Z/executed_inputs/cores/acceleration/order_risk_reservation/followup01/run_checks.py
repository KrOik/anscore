"""SPDX-License-Identifier: Apache-2.0. B47 A independent followup01; zero preparations, eight HDL children.
No project import, AST, numerical or HDL execution before root+peer approval.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
HERE=Path(__file__).resolve().parent
ROOT=HERE.parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=HERE/'FINITE_PLAN.json';SEAL=HERE/'SOURCE_SEAL.json';REVIEW=HERE/'SOURCE_REVIEW.json'
PREREQUISITES=HERE/'PREREQUISITES.json'
OLD_REPORT=ROOT/'reports/20261106T153545298533Z'
GUARD=HERE/'RUN_ONCE.json'
BASE='d32ea87e268c5957b7203560a5b46864e282a6e1'
GATE='B47_ORDER_RISK_RESERVATION_FOLLOWUP01_ONCE_01'
PROFILES=((1,1,1),(3,5,8),(16,32,32))
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path):return json.loads(path.read_bytes())
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def head_commit():
    value=(REPO/'.git/HEAD').read_text().strip()
    if not value.startswith('ref: '):return value
    ref=value[5:];candidate=REPO/'.git'/ref
    if candidate.is_file():return candidate.read_text().strip()
    for line in (REPO/'.git/packed-refs').read_text().splitlines():
        if line and not line.startswith(('#','^')):
            oid,name=line.split(' ',1)
            if name==ref:return oid
    raise RuntimeError('Cannot read baseline reference')
def commands(stamp):
    out=HERE/'reports'/stamp;cwd=out/'executed_inputs'/HERE.relative_to(REPO)
    work=HERE/'.work'/stamp;vectors=OLD_REPORT/'vectors';result=[]
    def add(name,kind,argv,marker=None,expected=None):
        result.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(cwd),marker=marker,
            expected=expected,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    for a,k,t in PROFILES:
        label=f'core_a{a}_k{k}_t{t}';image=work/(label+'.vvp')
        add('compile_'+label,'HDL_COMPILE',[BIN/'iverilog.exe','-g2012','-Wall','-s','tb_order_risk_reservation',
            f'-Ptb_order_risk_reservation.A={a}',f'-Ptb_order_risk_reservation.K={k}',f'-Ptb_order_risk_reservation.T={t}',
            '-o',image,'-f','files.f','sim/tb_order_risk_reservation.sv'])
        add('simulate_'+label,'HDL_SIMULATION',[BIN/'vvp.exe',image,'+vectors='+(vectors/(label+'.txt')).as_posix()],
            'B47_A_CORE_PASS ')
    image=work/'example.vvp'
    add('compile_example','HDL_COMPILE',[BIN/'iverilog.exe','-g2012','-Wall','-s','tb_ouch42_order_risk',
        '-o',image,'-f','example/files.f','sim/tb_ouch42_order_risk.sv'])
    add('simulate_example','HDL_SIMULATION',[BIN/'vvp.exe',image],'B47_A_EXAMPLE_PASS ',
        dict(checks=37,holds=148,frames=11,resets=4))
    return result

def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    record=dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
        process_exited=False,output_capture_complete=False,process_evidence_saved=False)
    report['children'].append(record)
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
            except BaseException:
                record.update(status='SPAWN_FAILED' if child is None else 'HARNESS_FAILED',
                    exception=traceback.format_exc())
            finally:
                alive=False
                if child is not None:
                    try: alive=child.poll() is None
                    except BaseException as exc: alive=True;record['initial_poll_error']=repr(exc)
                if alive:
                    entry=dict(kind='TREE_TERMINATION',status='STARTING',hard_seconds=5)
                    record['cleanup'].append(entry);hs=time.monotonic()
                    ho=out/(spec['name']+'.taskkill.stdout.raw')
                    he=out/(spec['name']+'.taskkill.stderr.raw')
                    try:
                        try: save()
                        except BaseException as exc: entry['record_error']=repr(exc)
                        with ho.open('xb',buffering=0) as ko,he.open('xb',buffering=0) as ke:
                            helper=subprocess.Popen([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),
                                '/PID',str(child.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,
                                creationflags=subprocess.CREATE_NO_WINDOW)
                            entry.update(pid=helper.pid,status='RUNNING')
                            try: save()
                            except BaseException as exc: entry['pid_record_error']=repr(exc)
                            remaining=5-(time.monotonic()-hs)
                            if remaining<=0: raise subprocess.TimeoutExpired('taskkill',5)
                            helper.wait(timeout=remaining)
                            entry['status']='TIMEOUT' if time.monotonic()-hs>=5 else 'EXITED'
                            ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                    except subprocess.TimeoutExpired: entry['status']='TIMEOUT'
                    except BaseException as exc: entry['error']=repr(exc)
                    finally:
                        # These independent nonwaiting kills run even if raw open,
                        # spawn, PID save, helper wait or raw persistence failed.
                        helper_alive=False
                        if helper is not None:
                            try: helper_alive=helper.poll() is None
                            except BaseException as exc:
                                helper_alive=True;entry['helper_poll_error']=repr(exc)
                        if helper_alive:
                            try: helper.kill();entry['helper_direct_kill']='ISSUED'
                            except BaseException as exc: entry['helper_kill_error']=repr(exc)
                        try: target_alive=child.poll() is None
                        except BaseException as exc:
                            target_alive=True;entry['target_poll_error']=repr(exc)
                        if target_alive:
                            try: child.kill();entry['target_direct_kill']='ISSUED'
                            except BaseException as exc: entry['target_kill_error']=repr(exc)
                    entry['helper_seconds']=time.monotonic()-hs
                    if entry['helper_seconds']>=5: entry['status']='TIMEOUT'
                    observation=time.monotonic()
                    try: child.wait(timeout=2)  # Sole target observation after termination.
                    except subprocess.TimeoutExpired: entry['target_observation']='UNCONFIRMED'
                    except BaseException as exc: entry['target_wait_error']=repr(exc)
                    entry['target_observation_seconds']=time.monotonic()-observation
                    if entry['target_observation_seconds']>=2: entry['target_observation_deadline_exceeded']=True
                    # Final helper observation happens after the sole target interval.
                    try:
                        entry['exit_code']=None if helper is None else helper.poll()
                        entry['process_exited']=helper is not None and entry['exit_code'] is not None
                        entry['active_helper']=helper.pid if helper is not None and entry['exit_code'] is None else None
                    except BaseException as exc:
                        entry.update(terminal_poll_error=repr(exc),process_exited=False,
                            active_helper=helper.pid if helper is not None else None)
                    entry['capture_errors']=[]
                    for stream,path in (('stdout',ho),('stderr',he)):
                        try:
                            with path.open('ab',buffering=0) as raw: raw.flush();os.fsync(raw.fileno())
                            entry[stream]=dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
                        except BaseException as exc: entry['capture_errors'].append(dict(stream=stream,error=repr(exc)))
                    entry['output_capture_complete']=entry['process_exited'] and not entry['capture_errors']
                so.flush();se.flush();os.fsync(so.fileno());os.fsync(se.fileno())
    except BaseException:
        record.update(status='HARNESS_FAILED',capture_exception=traceback.format_exc())
    try: code=child.poll() if child is not None else None
    except BaseException as exc: code=None;record['terminal_poll_error']=repr(exc)
    record.update(exit_code=code,process_exited=child is not None and code is not None,
        seconds=time.monotonic()-start,capture_errors=[])
    for stream,path in (('stdout',stdout_path),('stderr',stderr_path)):
        try: record[stream]=dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
        except BaseException as exc: record['capture_errors'].append(dict(stream=stream,error=repr(exc)))
    record['output_capture_complete']=record['process_exited'] and not record['capture_errors'] and all(
        x.get('output_capture_complete',False) for x in record['cleanup'])
    if child is not None and code is None:
        record['status']='TERMINATION_UNCONFIRMED'
        report['active_child']=dict(name=spec['name'],pid=child.pid,status=record['status'])
    else: report['active_child']=None
    report['active_helpers']=[x['active_helper'] for x in record['cleanup'] if x.get('active_helper')]
    report['active_helper']=report['active_helpers'][0] if report['active_helpers'] else None
    if report['active_helpers']: record['status']='HELPER_TERMINATION_UNCONFIRMED'
    if record['status']=='PASS' and not record['output_capture_complete']: record['status']='CAPTURE_INCOMPLETE'
    record['process_evidence_saved']=True
    terminal_record=out/(spec['name']+'.json')
    durable(terminal_record,record)
    report['child_records'][terminal_record.name]=dict(sha256=digest(terminal_record),bytes=terminal_record.stat().st_size)
    save() # Before any receipt, image or marker parsing.
    return record



def main():
    assert os.name=='nt' and sys.argv[1:]==['--execute-approved-plan']
    plan,seal,review=load(PLAN),load(SEAL),load(REVIEW)
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['execution_gate']==GATE and review['baseline_commit']==BASE
    assert review['runner_sha256']==digest(Path(__file__))
    assert review['plan_sha256']==digest(PLAN) and review['source_seal_sha256']==digest(SEAL)
    assert plan['baseline_commit']==seal['baseline_commit']==BASE and head_commit()==BASE
    assert plan['automatic_retry'] is False and plan['execution_gate']==GATE
    assert plan['children']==commands('<stamp>') and plan['source_sha256']==seal['source_sha256']
    sources=plan['source_sha256'];tools=plan['tools_sha256']
    prerequisites=load(PREREQUISITES)
    assert digest(PREREQUISITES)==plan['prerequisites_sha256']
    assert prerequisites['original_receipt_sha256']=='011d56278c7b527e7ecec455d64702851808acf59d174392f38c5cedc376838f'
    assert len(plan['children'])==8 and all(x['kind']!='PREPARATION' for x in plan['children'])
    assert plan['path_prefix']==[str(BIN),str(BIN.parent/'lib')]
    environment=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',
        PATH=os.pathsep.join(plan['path_prefix']+[os.environ.get('PATH','')]))
    assert tools[str(Path(sys.executable))]==digest(Path(sys.executable))
    controls={name:digest(current) for name,current in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]}
    def invariant():
        assert digest(PLAN)==controls['plan'] and digest(SEAL)==controls['seal'] and digest(REVIEW)==controls['review']
        for name,value in sources.items():assert digest(REPO/name)==value,name
        for name,value in tools.items():assert digest(Path(name))==value,name
        for name,value in prerequisites['files_sha256'].items():assert digest(REPO/name)==value,name
    invariant()
    assert not GUARD.exists() and (not (HERE/'reports').exists() or not any((HERE/'reports').iterdir()))
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    durable(GUARD,dict(schema='b47-order-risk-once-v1',status='ATTEMPT_STARTED',baseline_commit=BASE,
        plan_sha256=controls['plan'],review_sha256=controls['review'],automatic_retry=False),True)
    out=HERE/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    vectors=out/'vectors';vectors.mkdir();work=HERE/'.work'/stamp;work.mkdir(parents=True,exist_ok=False)
    report=dict(schema='b47-order-risk-followup01-results-v1',status='INCOMPLETE',baseline_commit=BASE,children=[],child_records={},
        active_child=None,active_helpers=[],active_helper=None,automatic_retry=False,suite_complete=False,
        inputs_unchanged=False,exact_plan_executed=False,archive_complete=False,source_sha256=sources,archived_sources={},
        tools_sha256=tools,plan_sha256=controls['plan'],source_seal_sha256=controls['seal'],review_sha256=controls['review'],
        vectors=plan['reused_vectors'],images={},preparation_children=0,
        prerequisites_sha256=plan['prerequisites_sha256'],original_receipt_sha256=prerequisites['original_receipt_sha256'])
    def save():durable(out/'results.json',report)
    save()
    try:
        for name,value in sources.items():
            original=REPO/name;archive=out/'executed_inputs'/name
            if archive.name=='.gitattributes':archive=archive.with_name('.gitattributes.executed.txt')
            archive.parent.mkdir(parents=True,exist_ok=True)
            with archive.open('xb') as stream:stream.write(original.read_bytes());stream.flush();os.fsync(stream.fileno())
            assert digest(archive)==value
            report['archived_sources'][name]=archive.relative_to(ROOT).as_posix()
        for name,current in [('plan.json',PLAN),('seal.json',SEAL),('review.json',REVIEW)]:
            with (out/name).open('xb') as stream:stream.write(current.read_bytes());stream.flush();os.fsync(stream.fileno())
        report['archive_complete']=True;save()
        frozen_vectors={str(ROOT/name):value for name,value in plan['reused_vectors'].items()};compiled={}
        for spec in commands(stamp):
            invariant()
            for name,value in report['archived_sources'].items():assert digest(ROOT/value)==sources[name]
            for name,value in frozen_vectors.items():assert digest(Path(name))==value
            launch_spec=dict(spec)
            if spec['kind']=='HDL_SIMULATION':
                image=Path(spec['argv'][1]);expected_image=compiled[str(image)]
                observed_image=digest(image);assert observed_image==expected_image
                # execute durably saves these fields in STARTING before Popen.
                launch_spec.update(execution_image_sha256=observed_image,execution_image_prechecked=True)
            record=execute(launch_spec,environment,out,report,save)
            assert record['status']=='PASS' and record['exit_code']==0 and record['process_exited']
            assert record['output_capture_complete'] and record['process_evidence_saved'] and not record['cleanup']
            stdout=(out/record['stdout']['path']).read_text(encoding='utf-8',errors='replace')
            if spec['marker']:
                assert stdout.count(spec['marker'])==1 and record['stderr']['bytes']==0
                observed={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',stdout)}
                record['observed']=observed
                if spec['kind']=='PREPARATION':
                    vector=Path(spec['argv'][-1]);data=vector.read_text(encoding='ascii').splitlines()
                    assert int(data[0])==len(data)-1==observed['records']
                    report['vectors'][vector.relative_to(ROOT).as_posix()]=digest(vector)
                    frozen_vectors[str(vector)]=digest(vector)
                elif spec['name'].startswith('simulate_core_'):
                    vector=Path(spec['argv'][2].split('=',1)[1]);n=int(vector.read_text(encoding='ascii').splitlines()[0])
                    expected=dict(records=n,checks=n,holds=4*n,blocked=4*(n-1),resets=9,canceled=4)
                    assert observed==expected;record['expected']=expected
                elif spec['expected'] is not None:assert observed==spec['expected']
            if spec['kind']=='HDL_COMPILE':
                image=Path(spec['argv'][spec['argv'].index('-o')+1]);compiled[str(image)]=digest(image)
                record['compiled_image_sha256']=digest(image);report['images'][image.relative_to(ROOT).as_posix()]=digest(image)
            elif spec['kind']=='HDL_SIMULATION':
                image=Path(spec['argv'][1]);assert digest(image)==compiled[str(image)]
                record['execution_image_sha256']=digest(image)
            terminal=out/(spec['name']+'.json');durable(terminal,record)
            report['child_records'][terminal.name]=dict(sha256=digest(terminal),bytes=terminal.stat().st_size)
            save()
        invariant()
        for name,value in report['archived_sources'].items():assert digest(ROOT/value)==sources[name]
        for name,value in frozen_vectors.items():assert digest(Path(name))==value
        for name,value in compiled.items():assert digest(Path(name))==value
        assert not report['active_child'] and not report['active_helper'] and not report['active_helpers']
        report.update(status='PASS',suite_complete=True,inputs_unchanged=True,exact_plan_executed=True)
    except BaseException:
        report.update(status='FAIL_STOP',exception=traceback.format_exc())
        try:invariant();report['inputs_unchanged']=True
        except BaseException:report['inputs_unchanged']=False
    finally:
        save();print(json.dumps(dict(status=report['status'],receipt=str(out/'results.json'))))
    return 0 if report['suite_complete'] else 1

if __name__=='__main__':raise SystemExit(main())
