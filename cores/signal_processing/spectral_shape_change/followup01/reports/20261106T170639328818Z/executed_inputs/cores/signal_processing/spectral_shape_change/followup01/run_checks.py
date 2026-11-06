"""SPDX-License-Identifier: Apache-2.0. B48 shape followup01 finite once runner.
No model preparation, project import, AST or HDL call before exact root/C gate.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
FOLLOWUP=Path(__file__).resolve().parent
PACKAGE=FOLLOWUP.parent
ROOT=PACKAGE.parents[2]
BIN=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=FOLLOWUP/'FINITE_PLAN.json';SEAL=FOLLOWUP/'SOURCE_SEAL.json';REVIEW=FOLLOWUP/'SOURCE_REVIEW.json'
GUARD=FOLLOWUP/'RUN_ONCE.json'
BASE='3a58c99bda6f6f62a34d1c20247d3b42d8d89006'
GATE='B48_SPECTRAL_SHAPE_CHANGE_FOLLOWUP01_ONCE_01'
ORIGINAL=PACKAGE/'reports/20261106T165359661187Z/results.json'
ORIGINAL_SHA='423cb711114ed50f1a6a8c9997db899e5dd1ca609bfa79381db5abe84528a17c'
PROFILES=(('core_min',1,1,0,25),('core_odd',7,8,0,49),('core_max',256,32,0,49),('iq64',64,8,1,41))
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path):return json.loads(path.read_bytes())
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def copy_new(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
def head_commit():
    value=(ROOT/'.git/HEAD').read_text().strip()
    if not value.startswith('ref: '):return value
    ref=value[5:];candidate=ROOT/'.git'/ref
    if candidate.is_file():return candidate.read_text().strip()
    for line in (ROOT/'.git/packed-refs').read_text().splitlines():
        if line and not line.startswith(('#','^')):
            oid,name=line.split(' ',1)
            if name==ref:return oid
    raise RuntimeError('Cannot read baseline reference')
def commands(stamp):
    out=FOLLOWUP/'reports'/stamp;cwd=out/'executed_inputs'/PACKAGE.relative_to(ROOT)
    work=FOLLOWUP/'.work'/stamp;result=[]
    for name,capacity,tags,iq,cases in PROFILES:
        image=work/(name+'.vvp')
        expected=dict(cases=cases,results=cases+28,holds=5*(cases+28),resets=9,cancellations=8,arith_errors=1)
        vector=PACKAGE/'reports/20261106T165359661187Z'/name/'vectors.txt'
        for label,kind,argv,marker,wanted in (
            ('compile_','HDL_COMPILE',[BIN/'iverilog.exe','-g2012','-Wall','-s','tb_spectral_shape_change',
             f'-Ptb_spectral_shape_change.MAX_BINS={capacity}',f'-Ptb_spectral_shape_change.TAG_W={tags}',
             f'-Ptb_spectral_shape_change.IQ={iq}','-o',image,'-f','example/files.f',
             'followup01/sim/tb_spectral_shape_change.sv'],None,None),
            ('simulate_','HDL_SIMULATION',[BIN/'vvp.exe',image,'+vectors='+vector.as_posix()],
             'B48_SHAPE_SIM_PASS ',expected)):
            result.append(dict(name=label+name,kind=kind,argv=list(map(str,argv)),cwd=str(cwd),marker=marker,
                expected=wanted,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    return result

def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    record=dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
        process_exited=False,output_capture_complete=False,process_evidence_saved=False)
    report['children'].append(record)
    report['active_child']=dict(name=spec['name'],pid=None,status='STARTING')
    # Immutable initial evidence precedes Popen. In simulation records this
    # includes the current image SHA256 and execution_image_prechecked=True.
    initial=out/(spec['name']+'.initial.json')
    durable(initial,record,True)
    report['initial_child_records'][initial.name]=dict(sha256=digest(initial),bytes=initial.stat().st_size)
    save()
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
    assert review['peer_reviewer']=='worker_c' and review['baseline_commit']==BASE and review['execution_gate']==GATE
    assert review['runner_sha256']==digest(Path(__file__)) and review['plan_sha256']==digest(PLAN)
    assert review['source_seal_sha256']==digest(SEAL)
    assert plan['baseline_commit']==seal['baseline_commit']==BASE and head_commit()==BASE
    assert plan['execution_gate']==GATE and plan['status']=='FROZEN' and plan['automatic_retry'] is False
    assert plan['children']==commands('<stamp>') and len(plan['children'])==8
    assert all(item['kind'] in ('HDL_COMPILE','HDL_SIMULATION') for item in plan['children'])
    assert seal['plan_sha256']==digest(PLAN) and seal['runner_sha256']==digest(Path(__file__))
    sources=plan['source_sha256'];tools=plan['tools_sha256'];evidence=plan['original_evidence_sha256']
    assert sources==seal['source_sha256'] and tools==seal['tools_sha256'] and evidence==seal['original_evidence_sha256']
    assert len(sources)==22 and len(tools)==25 and len(evidence)==67
    assert tools[str(Path(sys.executable))]==digest(Path(sys.executable))
    assert plan['original_receipt_sha256']==digest(ORIGINAL)==ORIGINAL_SHA
    prior=load(ORIGINAL)
    assert prior['status']=='FAIL_STOP' and not prior['suite_complete'] and prior['inputs_unchanged']
    assert len(prior['children'])==8 and prior['preparation_children']==4
    assert [x['status'] for x in prior['children']]==['PASS']*7+['FAIL']
    assert prior['children'][-1]['name']=='compile_core_min' and prior['children'][-1]['exit_code']==10
    assert not prior['active_child'] and not prior['active_helper'] and not prior['active_helpers']
    for name,value in prior['source_sha256'].items():assert sources[name]==value
    for name,value in prior['vectors'].items():assert evidence[(PACKAGE/name).relative_to(ROOT).as_posix()]==value
    # Structural parsing is not a numerical oracle. Reject every trailing token
    # before HDL, without modifying or regenerating the four prior fixtures.
    for name,capacity,tags,iq,cases in PROFILES:
        lines=(PACKAGE/'reports/20261106T165359661187Z'/name/'vectors.txt').read_text(encoding='ascii').splitlines()
        assert int(lines[0])==cases
        position=1
        for index in range(cases):
            header=lines[position].split();assert len(header)==13
            fields=[int(value,16) for value in header];position+=1
            count=fields[3];assert 0<=count<=capacity
            for row in range(count):
                tokens=lines[position].split();assert len(tokens)==3
                assert all(int(value,16)>=0 for value in tokens)
                position+=1
        assert position==len(lines),'Trailing fixture token or row'
    original_tb=PACKAGE/'sim/tb_spectral_shape_change.sv'
    repaired_tb=FOLLOWUP/'sim/tb_spectral_shape_change.sv'
    old_bytes=original_tb.read_bytes()
    assert len(re.findall(rb'\bbins\b',old_bytes))==5
    assert repaired_tb.read_bytes()==re.sub(rb'\bbins\b',b'command_bins',old_bytes)
    assert plan['path_prefix']==[str(BIN),str(BIN.parent/'lib')]
    controls={name:digest(path) for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]}
    def current_inputs():
        assert head_commit()==BASE and digest(ORIGINAL)==ORIGINAL_SHA
        for name,value in sources.items():assert digest(ROOT/name)==value,name
        for name,value in tools.items():assert digest(Path(name))==value,name
        for name,value in evidence.items():assert digest(ROOT/name)==value,name
        for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:assert digest(path)==controls[name]
    current_inputs()
    assert not GUARD.exists() and not (FOLLOWUP/'reports').exists()
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline_commit=BASE,execution_gate=GATE,
        original_receipt_sha256=ORIGINAL_SHA,automatic_retry=False,**controls),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=FOLLOWUP/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (FOLLOWUP/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='b48-shape-followup01-results-v1',status='INCOMPLETE',baseline_commit=BASE,
        execution_gate=GATE,automatic_retry=False,suite_complete=False,archive_complete=False,
        children=[],child_records={},initial_child_records={},validated_records={},active_child=None,
        active_helpers=[],active_helper=None,source_sha256=sources,tools_sha256=tools,
        original_evidence_sha256=evidence,original_receipt_sha256=ORIGINAL_SHA,archived_sources={},archived_original_evidence={},
        profiles=prior['profiles'],reused_vectors=prior['vectors'],images={},execution_images={},
        preparation_children=0,model_calls=0,runner_oracle_imports=0,**controls)
    def save():durable(out/'results.json',report)
    def invariant():
        current_inputs()
        for name,value in controls.items():assert digest(out/(name+'.json'))==value
        assert set(report['archived_sources'])==set(sources)
        assert set(report['archived_original_evidence'])==set(evidence)
        for name,value in sources.items():assert digest(FOLLOWUP/report['archived_sources'][name])==value
        for name,value in evidence.items():assert digest(FOLLOWUP/report['archived_original_evidence'][name])==value
        for name,value in report['images'].items():assert digest(FOLLOWUP/name)==value
        for group in ('initial_child_records','child_records','validated_records'):
            for name,item in report[group].items():assert digest(out/name)==item['sha256'] and (out/name).stat().st_size==item['bytes']
        for child in report['children']:
            if child.get('process_evidence_saved'):
                for stream in ('stdout','stderr'):
                    item=child[stream];assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
    save()
    try:
        for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:copy_new(out/(name+'.json'),path.read_bytes())
        for name,value in sources.items():
            target=out/'executed_inputs'/name
            if target.name=='.gitattributes':target=target.with_name('.gitattributes.executed.txt')
            copy_new(target,(ROOT/name).read_bytes());assert digest(target)==value
            report['archived_sources'][name]=target.relative_to(FOLLOWUP).as_posix()
        for name,value in evidence.items():
            target=out/'original_evidence'/name;copy_new(target,(ROOT/name).read_bytes());assert digest(target)==value
            report['archived_original_evidence'][name]=target.relative_to(FOLLOWUP).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1',PATH=os.pathsep.join(plan['path_prefix']+[os.environ.get('PATH','')]))
        for spec in commands(stamp):
            invariant();launch=dict(spec)
            if spec['kind']=='HDL_SIMULATION':
                image=Path(spec['argv'][1]);value=digest(image)
                assert value==report['images'][image.relative_to(FOLLOWUP).as_posix()]
                launch.update(execution_image_sha256=value,execution_image_prechecked=True)
                report['execution_images'][spec['name']]=dict(path=image.relative_to(FOLLOWUP).as_posix(),sha256=value);save()
            record=execute(launch,env,out,report,save)
            assert record['status']=='PASS' and record['exit_code']==0 and record['process_exited']
            assert record['process_evidence_saved'] and record['output_capture_complete'] and not record['cleanup']
            assert 0<=record['execution_seconds']<20
            initial=load(out/(spec['name']+'.initial.json'))
            assert initial['status']=='STARTING' and initial['pid'] is None
            if spec['kind']=='HDL_COMPILE':
                image=Path(spec['argv'][spec['argv'].index('-o')+1]);value=digest(image)
                record['compiled_image_sha256']=value;report['images'][image.relative_to(FOLLOWUP).as_posix()]=value
            else:
                assert record['stderr']['bytes']==0 and digest(Path(spec['argv'][1]))==record['execution_image_sha256']
                assert initial['execution_image_prechecked'] is True and initial['execution_image_sha256']==record['execution_image_sha256']
                stdout=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[line for line in stdout.splitlines() if line.startswith(spec['marker'])]
                assert len(lines)==1 and '$finish called' in stdout and not re.search(r'(?i)\b(fatal|error|fail)\b',stdout)
                observed={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                assert set(observed)==set(spec['expected'])|{'continuous'}
                assert all(observed.get(key)==value for key,value in spec['expected'].items())
                name=spec['name'][len('simulate_'):]
                assert spec['expected']==prior['profiles'][name]['expected']
                capacity=next(item[1] for item in PROFILES if item[0]==name)
                assert observed['continuous']>=int(capacity>1)
                record.update(observed=observed,expected=spec['expected'])
            record['metadata_validated']=True
            validated=out/(spec['name']+'.validated.json');durable(validated,record,True)
            report['validated_records'][validated.name]=dict(sha256=digest(validated),bytes=validated.stat().st_size)
            save();invariant();print(spec['name']+' PASS',flush=True)
        assert len(report['children'])==len(report['child_records'])==len(report['initial_child_records'])==len(report['validated_records'])==8
        assert len(report['images'])==4 and len(report['execution_images'])==4
        assert report['preparation_children']==report['model_calls']==report['runner_oracle_imports']==0
        assert not report['active_child'] and not report['active_helper'] and not report['active_helpers']
        report.update(status='PASS',suite_complete=True)
    except BaseException:report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except BaseException:unchanged=False
        report['inputs_unchanged']=unchanged
        report['exact_plan_executed']=[item['name'] for item in report['children']]==[item['name'] for item in commands(stamp)]
        if not unchanged:report.update(status='FAIL_STOP',suite_complete=False)
        save();print(json.dumps(dict(status=report['status'],receipt=str(out/'results.json'))))
    return 0 if report['suite_complete'] else 1
if __name__=='__main__':raise SystemExit(main())
