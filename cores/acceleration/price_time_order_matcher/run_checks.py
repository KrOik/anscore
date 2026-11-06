"""SPDX-License-Identifier: Apache-2.0. B49 bounded price-time matcher fixed finite runner.
No numerical model import, project import, AST, Git or unsolicited execution.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
PACKAGE=Path(__file__).resolve().parent
REPO=PACKAGE.parents[2]
ROOT=PACKAGE
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
BASE='05b9614c3962e9d4ae934c4b9c7bd315cc01aed4'
GATE='B49_PRICE_TIME_ORDER_MATCHER_ONCE_01'
PLAN=PACKAGE/'FINITE_PLAN.json';SEAL=PACKAGE/'SOURCE_SEAL.json';REVIEW=PACKAGE/'SOURCE_REVIEW.json'
GUARD=PACKAGE/'RUN_ONCE.json'
PROFILES={'singleton':(1,1,1,1),'ragged':(5,9,7,4),'maximum':(32,32,32,32)}
EXPECTED={'singleton':dict(commands=43,fills=0),'ragged':dict(commands=116,fills=9),'maximum':dict(commands=413,fills=36)}
SOURCES=('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
 'DEPENDENCY_PROOFS.json','TOOLCHAIN.json','manifest.json','files.f','example/files.f',
 'rtl/price_time_order_matcher.sv','example/two_client_limit_matcher.sv','reference_model.py',
 'sim/tb_price_time_order_matcher.sv','sim/tb_two_client_limit_matcher.sv','run_checks.py',
 '../../storage/ram_hash_table/rtl/ram_hash_table.sv',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v')
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
    out=PACKAGE/'reports'/stamp;cwd=out/'executed_inputs'/PACKAGE.relative_to(REPO)
    work=PACKAGE/'.work'/stamp;result=[]
    def add(name,kind,argv,**extra):
        result.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(cwd),
            hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    for label in PROFILES:
        add('prepare_'+label,'PREPARATION',[Path(sys.executable),'-I','-B',cwd/'reference_model.py',
            '--profile',label,'--out',out/'vectors'/label],profile=label,marker='B49_ORDER_PREP_PASS ',expected=EXPECTED[label])
    for label,top,params,fl in [('default','price_time_order_matcher',[], 'files.f'),
        ('maximum','price_time_order_matcher',['-Pprice_time_order_matcher.ORDERS=32','-Pprice_time_order_matcher.TAG_W=32'],'files.f'),
        ('example','two_client_limit_matcher',[],'example/files.f')]:
        add('syntax_'+label,'HDL_SYNTAX',[BIN/'iverilog.exe','-g2012','-Wall','-tnull','-s',top,*params,'-f',fl])
    for label,values in [*PROFILES.items(),('example',None)]:
        top='tb_two_client_limit_matcher' if values is None else 'tb_price_time_order_matcher'
        params=[] if values is None else ['-P%s.%s=%d'%(top,k,v) for k,v in zip(('N','P','Q','T'),values)]
        image=work/(label+'.vvp');tb='sim/tb_two_client_limit_matcher.sv' if values is None else 'sim/tb_price_time_order_matcher.sv'
        add('compile_'+label,'HDL_COMPILE',[BIN/'iverilog.exe','-g2012','-Wall','-s',top,*params,'-o',image,'-f','example/files.f' if values is None else 'files.f',tb],profile=label,image=str(image))
        expected=dict(commands=9,fills=4,simultaneous=1,resets=2) if values is None else dict(**EXPECTED[label],reset_probes=6)
        args=[] if values is None else ['+vectors='+(out/'vectors'/label/'vectors.txt').as_posix()]
        add('simulate_'+label,'HDL_SIMULATION',[BIN/'vvp.exe',image,*args],profile=label,image=str(image),
            marker='B49_ORDER_EXAMPLE_PASS ' if values is None else 'B49_ORDER_SIM_PASS ',expected=expected)
    return result

def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    if spec['kind']=='HDL_SIMULATION':
        spec=dict(spec)
        image=Path(spec['image']);image_sha=digest(image)
        assert report['images'][image.relative_to(PACKAGE).as_posix()]==image_sha
        spec.update(execution_image_sha256=image_sha,execution_image_prechecked=True)
        report['execution_images'][spec['name']]=dict(path=image.relative_to(PACKAGE).as_posix(),sha256=image_sha)
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
    assert review['baseline_commit']==BASE and review['execution_gate']==GATE and not review['automatic_retry']
    assert review['runner_sha256']==digest(Path(__file__)) and review['plan_sha256']==digest(PLAN)
    assert review['source_seal_sha256']==digest(SEAL)
    assert plan['baseline_commit']==seal['baseline_commit']==BASE and head_commit()==BASE
    assert seal['plan_sha256']==digest(PLAN) and plan['execution_gate']==GATE and not plan['automatic_retry']
    assert plan['children']==commands('<stamp>') and len(plan['children'])==14
    sources,pins=plan['source_sha256'],plan['tools_sha256']
    assert sources==seal['source_sha256'] and pins==seal['tools_sha256']
    assert set(sources)=={(PACKAGE/n).resolve().relative_to(REPO).as_posix() for n in SOURCES}
    assert pins[str(Path(sys.executable))]==digest(Path(sys.executable))
    toolchain=load(PACKAGE/'TOOLCHAIN.json')
    inherited=os.environ.get('PATH','');effective=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+inherited
    assert hashlib.sha256(inherited.encode()).hexdigest()==toolchain['inherited_path_sha256']
    assert hashlib.sha256(effective.encode()).hexdigest()==toolchain['effective_path_sha256']
    controls={k:digest(v) for k,v in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]}
    def current_inputs():
        for n,h in sources.items():assert digest(REPO/n)==h,n
        for n,h in pins.items():assert digest(Path(n))==h,n
        for k,p in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:assert digest(p)==controls[k]
    current_inputs()
    assert not GUARD.exists() and not (PACKAGE/'reports').exists() and not (PACKAGE/'.work').exists()
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline_commit=BASE,execution_gate=GATE,automatic_retry=False,**controls),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=PACKAGE/'reports'/stamp;out.mkdir(parents=True,exist_ok=False);(PACKAGE/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='b49-price-time-order-results-v1',status='INCOMPLETE',baseline_commit=BASE,
        execution_gate=GATE,automatic_retry=False,suite_complete=False,archive_complete=False,
        children=[],child_records={},initial_child_records={},validated_records={},active_child=None,
        active_helpers=[],active_helper=None,source_sha256=sources,tools_sha256=pins,
        archived_sources={},profiles={},images={},execution_images={},runner_oracle_imports=0,**controls)
    def save():durable(out/'results.json',report)
    def invariant():
        current_inputs()
        for k,h in controls.items():assert digest(out/(k+'.json'))==h
        assert set(report['archived_sources'])==set(sources)
        for n,h in sources.items():assert digest(PACKAGE/report['archived_sources'][n])==h
        for n,h in report['images'].items():assert digest(PACKAGE/n)==h
        for group in ['initial_child_records','child_records','validated_records']:
            for n,x in report[group].items():assert digest(out/n)==x['sha256'] and (out/n).stat().st_size==x['bytes']
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for stream in ['stdout','stderr']:
                    x=record[stream];assert digest(out/x['path'])==x['sha256'] and (out/x['path']).stat().st_size==x['bytes']
        for profile in report['profiles'].values():
            for x in profile['files']:
                assert digest(out/x['path'])==x['sha256'] and (out/x['path']).stat().st_size==x['bytes']
    save()
    try:
        for k,p in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:raw_new(out/(k+'.json'),p.read_bytes())
        for n,h in sources.items():
            target=out/'executed_inputs'/n
            if target.name=='.gitattributes':target=target.with_name('.gitattributes.executed.txt')
            target.parent.mkdir(parents=True,exist_ok=True);raw_new(target,(REPO/n).read_bytes())
            assert digest(target)==h;report['archived_sources'][n]=target.relative_to(PACKAGE).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1');env['PATH']=effective
        for spec in commands(stamp):
            invariant()
            record=execute(spec,env,out,report,save)
            # Record every produced compiler image, including a failed partial image.
            if spec['kind']=='HDL_COMPILE' and Path(spec['image']).is_file():
                image=Path(spec['image']);report['images'][image.relative_to(PACKAGE).as_posix()]=digest(image);save()
            assert record['status']=='PASS' and record['exit_code']==0 and record['process_exited']
            assert record['process_evidence_saved'] and record['output_capture_complete'] and not record['cleanup']
            label=spec.get('profile')
            if spec.get('marker'):
                assert record['stderr']['bytes']==0
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[s for s in raw.splitlines() if s.startswith(spec['marker'])]
                assert len(lines)==1 and not re.search(r'(?i)\b(fatal|error|fail)\b',raw)
                counters={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                assert all(counters[k]==v for k,v in spec['expected'].items())
                record.update(observed=counters,expected=spec['expected'])
                if spec['kind']=='PREPARATION':
                    directory=out/'vectors'/label;metadata=load(directory/'preparation.json')
                    assert metadata['commands']==counters['commands'] and metadata['fills']==counters['fills'] and metadata['profile']==label
                    assert metadata['vectors_sha256']==digest(directory/'vectors.txt') and metadata['final_live']==0
                    report['profiles'][label]=dict(expected=spec['expected'],files=[dict(path=p.relative_to(out).as_posix(),sha256=digest(p),bytes=p.stat().st_size) for p in [directory/'vectors.txt',directory/'preparation.json']])
                else:
                    assert '$finish called' in raw and counters['holds']>0
                    if label!='example':assert counters['blocked']>0
                    assert digest(Path(spec['image']))==record['execution_image_sha256']
            record['metadata_validated']=True
            target=out/(spec['name']+'.validated.json');durable(target,record,True)
            report['validated_records'][target.name]=dict(sha256=digest(target),bytes=target.stat().st_size)
            save();invariant();print(spec['name']+' PASS',flush=True)
        assert len(report['children'])==14 and len(report['profiles'])==3 and len(report['images'])==4
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS',suite_complete=True)
    except BaseException:report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except BaseException:unchanged=False
        report['inputs_unchanged']=unchanged
        report['exact_plan_executed']=[c['name'] for c in report['children']]==[x['name'] for x in commands(stamp)]
        if not unchanged:report.update(status='FAIL_STOP',suite_complete=False)
        save();print(json.dumps(dict(status=report['status'],receipt=(out/'results.json').relative_to(REPO).as_posix())))
    return 0 if report['suite_complete'] else 1
if __name__=='__main__':raise SystemExit(main())
