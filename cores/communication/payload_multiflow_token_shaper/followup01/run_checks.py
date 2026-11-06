"""SPDX-License-Identifier: Apache-2.0. B48 independent payload scalar-scan followup; zero preparation.
No project import or numerical/HDL execution outside the approved child plan.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent
PACKAGE=ROOT.parent
REPO=PACKAGE.parents[2]
ORIGINAL=PACKAGE/'reports/20261106T165455695092Z'
PREREQUISITES=ROOT/'PREREQUISITES.json'
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=ROOT/'FINITE_PLAN.json';SEAL=ROOT/'SOURCE_SEAL.json';REVIEW=ROOT/'SOURCE_REVIEW.json'
GUARD=ROOT/'RUN_ONCE.json'
BASE='3a58c99bda6f6f62a34d1c20247d3b42d8d89006'
GATE='B48_PAYLOAD_MULTIFLOW_TOKEN_SHAPER_FOLLOWUP01_ONCE_01'
PROFILES={'singleton':(1,8,1,1,1,1),'ragged':(3,16,5,4,3,3),'maximum':(8,64,512,24,16,1024)}
SOURCES=('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
 'manifest.json','files.f','example/files.f','rtl/payload_multiflow_token_shaper.sv',
 'example/four_class_payload_tx.sv','reference_model.py','sim/tb_payload_multiflow_token_shaper.sv',
 'sim/tb_four_class_payload_tx.sv','run_checks.py',
 '../../system/multiflow_token_shaper/rtl/multiflow_token_shaper.sv',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../../system/common_scaffold/memory/src/cip_sync_fifo.v',
 'followup01/README.md','followup01/tb_payload_multiflow_token_shaper.sv',
 'followup01/PREREQUISITES.json','followup01/run_checks.py')
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def load(path):return json.loads(path.read_bytes())
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def raw_new(path,data):
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
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
    out=ROOT/'reports'/stamp;cwd=out/'executed_inputs'/PACKAGE.relative_to(REPO)
    work=ROOT/'.work'/stamp;result=[]
    def add(name,kind,argv,**extra):
        result.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(cwd),
            hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    for label,values in [*PROFILES.items(),('example',None)]:
        top='tb_four_class_payload_tx' if values is None else 'tb_payload_multiflow_token_shaper'
        params=[] if values is None else ['-P%s.%s=%d'%(top,k,v) for k,v in zip(('F','D','B','T','G','Q'),values)]
        image=work/(label+'.vvp')
        tb='sim/tb_four_class_payload_tx.sv' if values is None else 'followup01/tb_payload_multiflow_token_shaper.sv'
        add('compile_'+label,'HDL_COMPILE',[BIN/'iverilog.exe','-g2012','-Wall','-s',top,*params,
            '-o',image,'-f','example/files.f' if values is None else 'files.f',tb],profile=label,image=str(image))
        args=[] if values is None else ['+vectors='+(ORIGINAL/'vectors'/label/'packets.txt').as_posix()]
        add('simulate_'+label,'HDL_SIMULATION',[BIN/'vvp.exe',image,*args],profile=label,image=str(image),
            marker='B48_A_EXAMPLE_PASS ' if values is None else 'B48_A_CORE_PASS ')
    return result

def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    record=dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
        process_exited=False,output_capture_complete=False,process_evidence_saved=False)
    initial_record=out/(spec['name']+'.started.json')
    durable(initial_record,record,True)
    report['initial_child_records'][initial_record.name]=dict(sha256=digest(initial_record),bytes=initial_record.stat().st_size)
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
    terminal_record=out/(spec['name']+'.terminal.json')
    durable(terminal_record,record,True)
    report['child_records'][terminal_record.name]=dict(sha256=digest(terminal_record),bytes=terminal_record.stat().st_size)
    save() # Before any receipt, image or marker parsing.
    return record

def main():
    assert os.name=='nt' and sys.argv[1:]==['--execute-approved-plan']
    plan,seal,review=load(PLAN),load(SEAL),load(REVIEW)
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['baseline_commit']==BASE and review['execution_gate']==GATE
    assert review['runner_sha256']==digest(Path(__file__)) and review['plan_sha256']==digest(PLAN)
    assert review['source_seal_sha256']==digest(SEAL)
    assert plan['baseline_commit']==seal['baseline_commit']==BASE and head_commit()==BASE
    assert seal['plan_sha256']==digest(PLAN) and plan['execution_gate']==GATE
    assert plan['automatic_retry'] is False and len(plan['children'])==8
    assert all(c['kind']!='PREPARATION' for c in plan['children'])
    prerequisites=load(PREREQUISITES)
    assert digest(PREREQUISITES)==plan['prerequisites_sha256']
    original=load(REPO/prerequisites['original_receipt'])
    assert digest(REPO/prerequisites['original_receipt'])==prerequisites['original_receipt_sha256']
    assert original['status']=='FAIL_STOP' and not original['suite_complete'] and len(original['children'])==8
    assert original['children'][-1]['name']=='simulate_singleton' and original['children'][-1]['status']=='FAIL'
    assert original['children'][-1]['exit_code']==1 and len(original['profiles'])==3
    assert original['active_child'] is None and original['active_helper'] is None and not original['active_helpers']
    assert plan['children']==commands('<stamp>')
    sources=plan['source_sha256'];pins=plan['tools_sha256']
    assert sources==seal['source_sha256'] and pins==seal['tools_sha256']
    assert set(sources)=={(PACKAGE/name).resolve().relative_to(REPO).as_posix() for name in SOURCES}
    assert pins[str(Path(sys.executable))]==digest(Path(sys.executable))
    controls={name:digest(path) for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]}
    def current_inputs():
        for name,value in sources.items():assert digest(REPO/name)==value,name
        for name,value in pins.items():assert digest(Path(name))==value,name
        for name,value in prerequisites['files_sha256'].items():assert digest(REPO/name)==value,name
        for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:assert digest(path)==controls[name]
    current_inputs()
    assert not GUARD.exists() and not (ROOT/'reports').exists()
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline_commit=BASE,execution_gate=GATE,
        automatic_retry=False,**controls),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='b48-payload-followup01-results-v1',status='INCOMPLETE',baseline_commit=BASE,
        execution_gate=GATE,automatic_retry=False,suite_complete=False,archive_complete=False,
        children=[],child_records={},initial_child_records={},validated_records={},active_child=None,
        active_helpers=[],active_helper=None,source_sha256=sources,tools_sha256=pins,
        archived_sources={},profiles={},images={},execution_images={},runner_oracle_imports=0,
        preparation_children=0,prerequisites_sha256=digest(PREREQUISITES),
        original_receipt=prerequisites['original_receipt'],original_receipt_sha256=prerequisites['original_receipt_sha256'],
        reused_vectors={label:dict(path=(ORIGINAL/'vectors'/label/'packets.txt').relative_to(REPO).as_posix(),sha256=digest(ORIGINAL/'vectors'/label/'packets.txt')) for label in PROFILES},**controls)
    def save():durable(out/'results.json',report)
    def invariant():
        current_inputs()
        for name,value in controls.items():assert digest(out/(name+'.json'))==value
        assert set(report['archived_sources'])==set(sources)
        for name,value in sources.items():assert digest(ROOT/report['archived_sources'][name])==value
        for name,value in report['images'].items():assert digest(ROOT/name)==value
        for group in ['initial_child_records','child_records','validated_records']:
            for name,item in report[group].items():assert digest(out/name)==item['sha256'] and (out/name).stat().st_size==item['bytes']
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for stream in ['stdout','stderr']:
                    item=record[stream];assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
        for profile in report['profiles'].values():
            for item in profile['files']:
                assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
    save()
    try:
        for name,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:raw_new(out/(name+'.json'),path.read_bytes())
        for name,value in sources.items():
            target=out/'executed_inputs'/name
            if target.name=='.gitattributes':target=target.with_name('.gitattributes.executed.txt')
            target.parent.mkdir(parents=True,exist_ok=True);raw_new(target,(REPO/name).read_bytes())
            assert digest(target)==value;report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
        env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
        for spec in commands(stamp):
            invariant()
            if spec['kind']=='HDL_SIMULATION':
                image=Path(spec['image']);value=digest(image)
                assert value==report['images'][image.relative_to(ROOT).as_posix()]
                spec.update(execution_image_sha256=value,execution_image_prechecked=True)
                report['execution_images'][spec['name']]=dict(path=image.relative_to(ROOT).as_posix(),sha256=value);save()
            record=execute(spec,env,out,report,save)
            assert record['status']=='PASS' and record['exit_code']==0 and record['process_exited']
            assert record['process_evidence_saved'] and record['output_capture_complete'] and not record['cleanup']
            label=spec.get('profile')
            if spec['kind']=='HDL_COMPILE':
                image=Path(spec['image']);report['images'][image.relative_to(ROOT).as_posix()]=digest(image)
                record['compiled_image_sha256']=digest(image)
            elif spec['kind']=='HDL_SIMULATION':
                assert record['stderr']['bytes']==0 and digest(Path(spec['image']))==record['execution_image_sha256']
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'])]
                assert len(lines)==1 and '$finish called' in raw
                assert not re.search(r'(?i)\b(fatal|error|fail)\b',raw)
                counters={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                if label=='example':expected=dict(configurations=4,admissions=5,frames=3,output_beats=4,resets=2)
                else:
                    expected=original['profiles'][label]['expected']
                    assert counters['blocked']>0 and counters['ledger_checks']>0 and counters['sop_charges']>0
                    if label!='singleton':assert counters['concurrent_rw']>0
                assert all(counters[k]==v for k,v in expected.items()) and counters['holds']>0
                record.update(observed=counters,expected=expected)
            record['metadata_validated']=True
            validated=out/(spec['name']+'.validated.json');durable(validated,record,True)
            report['validated_records'][validated.name]=dict(sha256=digest(validated),bytes=validated.stat().st_size)
            save();invariant();print(spec['name']+' PASS',flush=True)
        assert len(report['children'])==8 and len(report['profiles'])==0 and len(report['images'])==4
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS',suite_complete=True)
    except BaseException:report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except BaseException:unchanged=False
        report['inputs_unchanged']=unchanged
        report['exact_plan_executed']=[c['name'] for c in report['children']]==[s['name'] for s in commands(stamp)]
        if not unchanged:report.update(status='FAIL_STOP',suite_complete=False)
        save();print(json.dumps(dict(status=report['status'],receipt=(out/'results.json').relative_to(REPO).as_posix())))
    return 0 if report['suite_complete'] else 1
if __name__=='__main__':raise SystemExit(main())
