"""B50 Winograd single-attempt finite checks. Source-only until exact gate."""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
KILL_EXE=Path(os.environ['SystemRoot'])/'System32/taskkill.exe'
GUARD=REPO/'.git/anscore-b50-winograd-once.json'
PLAN=ROOT/'FINITE_PLAN.json';SEAL=ROOT/'SOURCE_SEAL.json';REVIEW=ROOT/'SOURCE_REVIEW.json'
BASE='c9117a22459e954d496dfa66dd94d6f67188c862'
PROFILES={'tiny':(1,1,0),'ragged':(3,17,0),'maximum':(64,32,0),'example':(8,32,1)}
SOURCES=('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
 'FINITE_PLAN_DRAFT.md','manifest.json','files.f','example/files.f',
 'rtl/int4_winograd_tile.sv','example/winograd_requantize.sv',
 'model/reference.py','sim/tb_winograd.sv','run_checks.py',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v')

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def raw_new(path,data):
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
def fixture_name(values):
    rows,tag,wrapped=values
    return f"{'wrapper' if wrapped else 'core'}_r{rows}_t{tag}.txt"
def commands(stamp):
    out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp
    specs=[];iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe')
    def add(name,kind,argv,**extra):
        specs.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(ROOT),
            hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    oracle=out/'executed_inputs'/ROOT.relative_to(REPO)/'model/reference.py'
    add('prepare_vectors','PREPARATION',[sys.executable,'-I','-B',oracle,'--out',out/'vectors'])
    for label,(rows,tag,wrapped) in PROFILES.items():
        top='winograd_requantize' if wrapped else 'int4_winograd_tile'
        add('syntax_'+label,'HDL',[iv,'-g2012','-Wall','-tnull','-s',top,
            f'-P{top}.MAX_ROWS={rows}',f'-P{top}.TAG_W={tag}',
            'rtl/int4_winograd_tile.sv','../int4_weight_matvec/rtl/deps/stream_requantize.v',
            'example/winograd_requantize.sv'],profile=label)
        image=work/(label+'.vvp')
        add('compile_'+label,'HDL',[iv,'-g2012','-Wall','-s','tb_winograd',
            f'-Ptb_winograd.MAX_ROWS={rows}',f'-Ptb_winograd.TAG_W={tag}',
            f'-Ptb_winograd.WRAPPED={wrapped}','-o',image,
            'rtl/int4_winograd_tile.sv','../int4_weight_matvec/rtl/deps/stream_requantize.v',
            'example/winograd_requantize.sv','sim/tb_winograd.sv'],profile=label,image=str(image))
        add('simulate_'+label,'HDL',[vvp,image,'+VECTORS='+(out/'vectors'/fixture_name((rows,tag,wrapped))).as_posix()],
            profile=label,image=str(image),marker='PASS winograd ')
    return specs

def execute(spec,env,out,report,save):
    # Start before spawn and PID persistence; wall time includes both operations.
    start=time.monotonic();child=None;helper=None
    record=dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
        process_exited=False,output_capture_complete=False,process_evidence_saved=False)
    if spec['name'].startswith('simulate_'):
        image=Path(spec['image'])
        pinned=report['images'][image.relative_to(ROOT).as_posix()]
        assert digest(image)==pinned
        record.update(execution_image_sha256=pinned,execution_image_prechecked=True)
    initial_path=out/(spec['name']+'.initial.json')
    durable(initial_path,record,True)  # Immutable and fsynced before Popen.
    report['initial_records'][initial_path.name]=dict(sha256=digest(initial_path),bytes=initial_path.stat().st_size)
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
    assert Path(__file__).resolve()==REPO/'cores/acceleration/int4_winograd_tile/run_checks.py'
    plan=json.loads(PLAN.read_bytes());seal=json.loads(SEAL.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert plan['status']=='FROZEN' and not plan['pending_inputs']
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['peer_reviewer'] in ('worker_a','worker_b','worker_c')
    assert review['execution_gate']==plan['execution_gate']=='B50_WINOGRAD_ONCE_01'
    assert review['plan_sha256']==digest(PLAN)==seal['plan_sha256']
    assert review['seal_sha256']==digest(SEAL) and review['runner_sha256']==digest(Path(__file__))
    assert plan['schema']=='anscore-b50-winograd-plan-v1' and plan['baseline']==BASE
    assert plan['automatic_retry'] is False and plan['children']==commands('<stamp>') and len(plan['children'])==13
    expected_names={(ROOT/name).resolve().relative_to(REPO).as_posix() for name in SOURCES}
    assert set(plan['source_sha256'])==expected_names and plan['source_sha256']==seal['source_sha256']
    assert plan['tools_sha256']==seal['tools_sha256']
    required_tools=(Path(sys.executable),KILL_EXE,BIN/'iverilog.exe',BIN/'vvp.exe')
    assert all(tool in {Path(name) for name in plan['tools_sha256']} for tool in required_tools)
    def current_inputs():
        for name,value in plan['source_sha256'].items():assert digest(REPO/name)==value,name
        for name,value in plan['tools_sha256'].items():assert digest(Path(name))==value,name
    current_inputs()
    assert not GUARD.exists() and not (ROOT/'reports').exists() and not (ROOT/'.work').exists()
    pins={'plan':digest(PLAN),'seal':digest(SEAL),'review':digest(REVIEW)}
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline=BASE,automatic_retry=False,**pins),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b50-winograd-finite-v1',status='INCOMPLETE',baseline=BASE,
        children=[],child_records={},initial_records={},validated_records={},
        active_child=None,active_helpers=[],active_helper=None,
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
        for domain in ('child_records','initial_records','validated_records'):
            for name,item in report[domain].items():
                assert digest(out/name)==item['sha256'] and (out/name).stat().st_size==item['bytes']
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for stream in ('stdout','stderr'):
                    item=record[stream];assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
        for profile in report['profiles'].values():
            for item in profile['files']:
                assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
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
        assert plan['environment']==dict(inherit=True,PYTHONDONTWRITEBYTECODE='1',
            PATH_prefix=[str(BIN),str(BIN.parent/'lib')],stdin='DEVNULL',creationflags='CREATE_NO_WINDOW')
        for spec in commands(stamp):
            invariant();image_hash=None
            if spec['name'].startswith('simulate_'):
                image=Path(spec['image']);image_hash=digest(image)
                assert image_hash==report['images'][image.relative_to(ROOT).as_posix()]
                report['execution_images'][spec['name']]=dict(path=image.relative_to(ROOT).as_posix(),sha256=image_hash)
                save()
            record=execute(spec,env,out,report,save)
            checked=dict(record)
            if spec['name'].startswith('compile_') and Path(spec['image']).is_file():
                image=Path(spec['image']);compiled_hash=digest(image)
                checked['compiled_image_sha256']=compiled_hash
                report['images'][image.relative_to(ROOT).as_posix()]=compiled_hash;save()
            assert record['status']=='PASS' and record['process_exited'] and record['exit_code']==0
            assert record['output_capture_complete'] and record['process_evidence_saved'] and not record['cleanup']
            label=spec.get('profile')
            if spec['kind']=='PREPARATION':
                assert record['stderr']['bytes']==0
                prepared=json.loads((out/record['stdout']['path']).read_bytes())
                manifest=json.loads((out/'vectors/vectors.json').read_bytes())
                assert prepared==manifest and manifest['schema']==1
                assert manifest['oracle']=='direct spatial integer sums' and len(manifest['fixtures'])==4
                expected_files={fixture_name(values) for values in PROFILES.values()}|{'vectors.json'}
                assert {p.name for p in (out/'vectors').iterdir()}==expected_files
                for label,values in PROFILES.items():
                    entry=next(item for item in manifest['fixtures'] if item['name']==fixture_name(values))
                    vector=out/'vectors'/entry['name']
                    assert digest(vector)==entry['sha256'] and vector.stat().st_size==entry['bytes']
                    assert (entry['max_rows'],entry['tag_w'],int(entry['wrapped']))==values
                    tokens=[list(map(int,line.split())) for line in vector.read_text(encoding='ascii').splitlines()]
                    assert tokens and all(len(parts)==12 and parts[0] in (0,1,2,3,4,5,9) for parts in tokens)
                    assert tokens[0][0]==4 and tokens[-1][0]==9
                    counts={op:sum(parts[0]==op for parts in tokens) for op in (0,1,2,3,4,5,9)}
                    assert counts[4]==counts[9]==1 and counts[5]==7+values[2]
                    assert counts[0]==entry['configuration_records'] and counts[1]==entry['commands']
                    assert counts[2]==entry['expected_outputs'] and counts[2]==4*entry['transform_identity_checks']
                    summary=dict(entry,records=len(tokens),resets=counts[5])
                    report['profiles'][label]=dict(summary=summary,files=[
                        dict(path=p.relative_to(out).as_posix(),sha256=digest(p),bytes=p.stat().st_size)
                        for p in (vector,out/'vectors/vectors.json')])
            elif spec['name'].startswith('simulate_'):
                assert record['execution_image_prechecked'] and record['execution_image_sha256']==image_hash
                initial_record=json.loads((out/(spec['name']+'.initial.json')).read_bytes())
                assert initial_record['status']=='STARTING' and initial_record['pid'] is None
                assert initial_record['execution_image_prechecked'] and initial_record['execution_image_sha256']==image_hash
                assert record['stderr']['bytes']==0 and digest(Path(spec['image']))==image_hash
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'])]
                assert len(lines)==1 and '$finish called' in raw
                counters={key:int(value) for key,value in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                summary=report['profiles'][label]['summary'];rows,tag,wrapped=PROFILES[label]
                expected=dict(MAX_ROWS=rows,TAG_W=tag,WRAPPED=wrapped,
                    commands=summary['commands']+1,outputs=summary['expected_outputs'],
                    resets=summary['resets'],configs=summary['configuration_records'])
                assert all(counters[key]==value for key,value in expected.items())
                assert 0<counters['cycles']<=200000
                checked['observed']=counters;checked['expected']=expected
            checked['metadata_validated']=True
            validation=out/(spec['name']+'.validated.json');durable(validation,checked,True)
            report['validated_records'][validation.name]=dict(sha256=digest(validation),bytes=validation.stat().st_size)
            save();invariant();print(spec['name']+' PASS',flush=True)
        assert len(report['profiles'])==4 and len(report['images'])==4 and len(report['children'])==13
        assert len(report['initial_records'])==len(report['child_records'])==len(report['validated_records'])==13
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS',suite_complete=True,inputs_unchanged=True,exact_plan_executed=True)
    except BaseException:
        report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except BaseException:unchanged=False
        report['inputs_unchanged']=unchanged
        report['exact_plan_executed']=[record['name'] for record in report['children']]==[spec['name'] for spec in commands(stamp)]
        if not unchanged:report.update(status='FAIL_STOP',suite_complete=False)
        save();print(json.dumps(dict(status=report['status'],receipt=(out/'results.json').relative_to(REPO).as_posix())))
    return 0 if report['suite_complete'] else 1

if __name__=='__main__':raise SystemExit(main())
