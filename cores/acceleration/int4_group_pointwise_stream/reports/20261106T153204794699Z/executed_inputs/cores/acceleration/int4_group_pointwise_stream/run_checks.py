"""B47 grouped pointwise one-attempt finite qualification; no project imports."""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
KILL_EXE=Path(os.environ['SystemRoot'])/'System32/taskkill.exe'
GUARD=REPO/'.git/anscore-b47-group-pointwise-once.json'
PLAN=ROOT/'FINITE_PLAN.json';SEAL=ROOT/'SOURCE_SEAL.json';REVIEW=ROOT/'SOURCE_REVIEW.json'
BASE='d32ea87e268c5957b7203560a5b46864e282a6e1'
PROFILES={'tiny':(1,1,1,1,1),'small':(3,9,3,7,8),'maximum':(8,128,8,4096,32)}
SOURCES=('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
 'manifest.json','files.f','example/files.f','rtl/int4_group_pointwise_stream.sv',
 'example/two_rgb_group_projection.sv','model/oracle.py','sim/prepare.py',
 'sim/tb_group_pointwise.sv','sim/tb_two_rgb.sv','run_checks.py',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def raw_new(path,data):
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
def commands(stamp):
    out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp
    specs=[];iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe')
    def add(name,kind,argv,**extra):
        specs.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(ROOT),
            hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    preparation=out/'executed_inputs'/ROOT.relative_to(REPO)/'sim/prepare.py'
    for label in [*PROFILES,'example']:
        add('prepare_'+label,'PREPARATION',[sys.executable,'-I','-B',preparation,
            '--profile',label,'--output',out/(label+'.txt')],profile=label)
    add('syntax_default','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_group_pointwise_stream','-f','files.f'])
    maximum={'GROUPS':1,'MAX_IN_PER_GROUP':1024,'MAX_OUT_PER_GROUP':64,'MAX_PIXELS':4096,'TAG_W':32}
    add('syntax_budget_maximum','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_group_pointwise_stream',
        *['-Pint4_group_pointwise_stream.%s=%d'%(k,v) for k,v in maximum.items()],'-f','files.f'])
    add('syntax_example','HDL',[iv,'-g2012','-Wall','-tnull','-s','two_rgb_group_projection','-f','example/files.f'])
    for label,values in [*PROFILES.items(),('example',None)]:
        top='tb_two_rgb' if values is None else 'tb_group_pointwise'
        params=[] if values is None else ['-Ptb_group_pointwise.%s=%d'%(k,v) for k,v in zip(('G','MI','MO','MP','TW'),values)]
        image=work/(label+'.vvp')
        add('compile_'+label,'HDL',[iv,'-g2012','-Wall','-s',top,*params,'-o',image,
            '-f','example/files.f','sim/'+top+'.sv'],profile=label,image=str(image))
        add('simulate_'+label,'HDL',[vvp,image,'+VECTORS='+(out/(label+'.txt')).as_posix()],
            profile=label,image=str(image),marker='PASS TWO_RGB ' if values is None else 'PASS GROUP_POINTWISE ')
    return specs

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
    plan=json.loads(PLAN.read_bytes());seal=json.loads(SEAL.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['peer_reviewer']=='worker_a' and review['execution_gate']=='B47_GROUP_POINTWISE_ONCE_01'
    assert review['plan_sha256']==digest(PLAN)==seal['plan_sha256']
    assert review['seal_sha256']==digest(SEAL) and review['runner_sha256']==digest(Path(__file__))
    assert plan['schema']=='anscore-b47-group-pointwise-plan-v1' and plan['baseline']==BASE
    assert plan['automatic_retry'] is False and plan['children']==commands('<stamp>') and len(plan['children'])==15
    expected_names={(ROOT/name).resolve().relative_to(REPO).as_posix() for name in SOURCES}
    assert set(plan['source_sha256'])==expected_names and plan['source_sha256']==seal['source_sha256']
    assert plan['tools_sha256']==seal['tools_sha256']
    def current_inputs():
        for name,value in plan['source_sha256'].items():assert digest(REPO/name)==value,name
        for name,value in plan['tools_sha256'].items():assert digest(Path(name))==value,name
    current_inputs()
    assert not GUARD.exists() and not (ROOT/'reports').exists()
    pins={'plan':digest(PLAN),'seal':digest(SEAL),'review':digest(REVIEW)}
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline=BASE,automatic_retry=False,**pins),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b47-group-pointwise-finite-v1',status='INCOMPLETE',baseline=BASE,
        children=[],child_records={},active_child=None,active_helpers=[],active_helper=None,
        source_sha256=plan['source_sha256'],tools_sha256=plan['tools_sha256'],archived_sources={},
        profiles={},images={},execution_images={},archive_complete=False,suite_complete=False,
        automatic_retry=False,runner_oracle_imports=0,**pins)
    def save():durable(out/'results.json',report)
    def invariant():
        current_inputs()
        for key,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:
            assert digest(path)==pins[key]==digest(out/(key+'.json'))
        assert set(report['archived_sources'])==set(plan['source_sha256'])
        for name,value in plan['source_sha256'].items():assert digest(ROOT/report['archived_sources'][name])==value
        for name,value in report['images'].items():assert digest(ROOT/name)==value
        for name,item in report['child_records'].items():
            assert digest(out/name)==item['sha256'] and (out/name).stat().st_size==item['bytes']
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for stream in ['stdout','stderr']:
                    item=record[stream];assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
        for profile in report['profiles'].values():
            for item in profile['files']:
                assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
    def persist(record):
        path=out/(record['name']+'.json');durable(path,record)
        report['child_records'][path.name]=dict(sha256=digest(path),bytes=path.stat().st_size);save()
    save()
    try:
        for key,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:raw_new(out/(key+'.json'),path.read_bytes())
        for name,value in plan['source_sha256'].items():
            target=out/'executed_inputs'/name;target.parent.mkdir(parents=True,exist_ok=True)
            raw_new(target,(REPO/name).read_bytes());assert digest(target)==value
            report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
        env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
        for spec in commands(stamp):
            invariant();image_hash=None
            if spec['name'].startswith('simulate_'):
                image=Path(spec['image']);image_hash=digest(image)
                assert image_hash==report['images'][image.relative_to(ROOT).as_posix()]
                report['execution_images'][spec['name']]=dict(path=image.relative_to(ROOT).as_posix(),sha256=image_hash);save()
            record=execute(spec,env,out,report,save)
            if image_hash is not None:record['execution_image_sha256']=image_hash
            if '-o' in spec['argv'] and Path(spec['image']).is_file():
                image=Path(spec['image']);record['compiled_image_sha256']=digest(image)
                report['images'][image.relative_to(ROOT).as_posix()]=record['compiled_image_sha256']
            persist(record)
            assert record['status']=='PASS' and record['process_exited'] and record['exit_code']==0
            assert record['output_capture_complete'] and record['process_evidence_saved'] and not record['cleanup']
            label=spec.get('profile')
            if spec['kind']=='PREPARATION':
                assert record['stderr']['bytes']==0
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                assert raw.count('PREP_GROUP_POINTWISE ')==1
                summary=json.loads(raw.split('PREP_GROUP_POINTWISE ',1)[1])
                expected={'tiny':5,'small':54,'maximum':32976,'example':72}[label]
                assert summary['profile']==label and summary['scored']==expected
                assert summary['frames']==(3 if label=='example' else 5)
                vector=out/(label+'.txt');receipt=out/(label+'.json')
                assert digest(vector)==summary['sha256'] and vector.stat().st_size==summary['bytes']
                assert json.loads(receipt.read_bytes())==summary
                report['profiles'][label]=dict(summary=summary,files=[dict(path=p.name,sha256=digest(p),bytes=p.stat().st_size) for p in [vector,receipt]])
            elif spec['name'].startswith('simulate_'):
                assert record['stderr']['bytes']==0 and digest(Path(spec['image']))==image_hash
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'])]
                assert len(lines)==1 and '$finish called' in raw
                counters={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                if label=='example':
                    expected=dict(frames=3,scored=73,errors=3,resets=2)
                else:
                    expected=dict(vector_frames=5,vector_scored=report['profiles'][label]['summary']['scored'],
                        recovery_scored=2*PROFILES[label][0],error_results=6,resets=4)
                assert all(counters[k]==v for k,v in expected.items()) and counters['held']>0
                record['observed']=counters;record['expected']=expected
            record['metadata_validated']=True;persist(record);invariant()
            print(spec['name']+' PASS',flush=True)
        assert len(report['profiles'])==4 and len(report['images'])==4 and len(report['children'])==15
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS',suite_complete=True,inputs_unchanged=True,exact_plan_executed=True)
    except BaseException:
        report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except BaseException:unchanged=False
        report['inputs_unchanged']=unchanged
        report['exact_plan_executed']=[r['name'] for r in report['children']]==[s['name'] for s in commands(stamp)]
        if not unchanged:report.update(status='FAIL_STOP',suite_complete=False)
        save();print(json.dumps(dict(status=report['status'],receipt=(out/'results.json').relative_to(REPO).as_posix())))
    return 0 if report['suite_complete'] else 1
if __name__=='__main__':raise SystemExit(main())
