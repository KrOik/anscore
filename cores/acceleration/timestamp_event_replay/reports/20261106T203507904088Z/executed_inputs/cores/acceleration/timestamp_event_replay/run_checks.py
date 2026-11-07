"""B50 timestamp replay one-attempt qualification; no project/model imports.

Lifecycle source adapted from the fully read tone-fit/B49 lineage. Preparation,
fixture parsing and output validation are local and independently reviewable.
This file is authored source only until exact root plus worker_b review.
"""
from pathlib import Path
import datetime,hashlib,json,os,re,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PYTHON_EXE=Path('C:/Program Files/Python312/python.exe')
KILL_EXE=Path('C:/WINDOWS/System32/taskkill.exe')
GUARD=REPO/'.git/anscore-b50-timestamp-event-replay-once.json'
PLAN=ROOT/'FINITE_PLAN.json';SEAL=ROOT/'SOURCE_SEAL.json';REVIEW=ROOT/'SOURCE_REVIEW.json'
BASE='c9117a22459e954d496dfa66dd94d6f67188c862'
GATE='B50_TIMESTAMP_EVENT_REPLAY_ONCE_01'
PROFILES={'tiny':(1,1,1,12),'ragged':(9,37,5,12),
 'wide':(64,577,8,14),'payload_max':(64,1024,32,14)}
FIELDS=('rst run_enable abort_run c_valid c_count c_step_q16 c_tag '
 's_valid s_time s_data m_ready d_ready '
 'c_ready s_ready m_valid m_time m_data m_tag '
 'd_valid d_status d_received d_emitted d_anchor d_elapsed_q16 d_tag active epoch_flush').split()
SOURCES=('.gitattributes','LICENSE','README.md','SOURCES.md','manifest.json','PRECHECK_PLAN.json',
 'files.f','example/files.f','rtl/timestamp_event_replay.sv','example/paced_dual_itch_replay.sv',
 'prepare_vectors.py','sim/tb_timestamp_event_replay.sv','sim/tb_paced_dual_itch_replay.sv','run_checks.py',
 '../../system/common_scaffold/memory/src/cip_sync_sp_ram.v',
 '../../storage/ram_deadline_scheduler/rtl/ram_deadline_scheduler.sv',
 '../../communication/moldudp64_itch_rx/rtl/moldudp64_itch_rx.sv',
 '../../storage/watermark_event_merge/rtl/watermark_event_merge.sv',
 '../../storage/watermark_event_merge/example/dual_itch_time_merge.sv')

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
def raw_new(path,data):
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
def head_commit():
    value=(REPO/'.git/HEAD').read_text(encoding='ascii').strip()
    if not value.startswith('ref: '):return value
    ref=value[5:];candidate=(REPO/'.git'/ref).resolve()
    assert ref.startswith('refs/') and candidate.is_relative_to((REPO/'.git').resolve())
    if candidate.is_file():return candidate.read_text(encoding='ascii').strip()
    for line in (REPO/'.git/packed-refs').read_text(encoding='ascii').splitlines():
        if line and not line.startswith(('#','^')):
            oid,name=line.split(' ',1)
            if name==ref:return oid
    raise RuntimeError('Cannot read baseline reference')
def commands(stamp):
    out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp
    specs=[];iv=str(BIN/'iverilog.exe');vvp=str(BIN/'vvp.exe')
    def add(name,kind,argv,**extra):
        specs.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(ROOT),
            hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    oracle=out/'executed_inputs'/ROOT.relative_to(REPO)/'prepare_vectors.py'
    fixtures=out/'fixtures'
    add('prepare_once','PREPARATION',[PYTHON_EXE,'-I','-B',oracle,'--out',fixtures])
    add('syntax_core','HDL',[iv,'-g2012','-Wall','-tnull','-s','timestamp_event_replay','-f','files.f'])
    add('syntax_wrapper','HDL',[iv,'-g2012','-Wall','-tnull','-s','paced_dual_itch_replay','-f','example/files.f'])
    for label,(tw,dw,gw,_) in PROFILES.items():
        image=work/(label+'.vvp')
        params=['-Ptb_timestamp_event_replay.TIME_W='+str(tw),
            '-Ptb_timestamp_event_replay.DATA_W='+str(dw),'-Ptb_timestamp_event_replay.TAG_W='+str(gw)]
        add('compile_'+label,'HDL',[iv,'-g2012','-Wall','-s','tb_timestamp_event_replay',*params,
            '-o',image,'-f','files.f','sim/tb_timestamp_event_replay.sv'],profile=label,image=str(image))
        add('simulate_'+label,'HDL',[vvp,image,'+VECTORS='+(fixtures/(label+'.txt')).as_posix()],
            profile=label,image=str(image),marker='PASS timestamp_event_replay ')
    image=work/'wrapper.vvp'
    add('compile_wrapper','HDL',[iv,'-g2012','-Wall','-s','tb_paced_dual_itch_replay',
        '-o',image,'-f','example/files.f','sim/tb_paced_dual_itch_replay.sv'],image=str(image))
    add('simulate_wrapper','HDL',[vvp,image,'+FEED0='+(fixtures/'feed0.hex').as_posix(),
        '+FEED1='+(fixtures/'feed1.hex').as_posix()],image=str(image),marker='PASS paced_dual_itch_replay:')
    for parameter,value in [('TIME_W',0),('TIME_W',65),('DATA_W',0),('DATA_W',1025),('TAG_W',0),('TAG_W',33)]:
        add('reject_'+parameter.lower()+'_'+str(value),'HDL_EXPECTED_REJECTION',
            [iv,'-g2012','-Wall','-tnull','-s','timestamp_event_replay',
             '-Ptimestamp_event_replay.'+parameter+'='+str(value),'-f','files.f'],
            rejection_marker='timestamp_event_replay_invalid_parameters__see_README')
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
                            helper=subprocess.Popen([str(KILL_EXE),
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
    durable(terminal_record,record,True)
    report['child_records'][terminal_record.name]=dict(sha256=digest(terminal_record),bytes=terminal_record.stat().st_size)
    save() # Before any receipt, image or marker parsing.
    return record



def expected_cases(label):
    result=[('zero_count',1),('zero_step',1),('minimum_step_equal_ties',0),('fractional_quarter',0),
        ('abort_before_anchor',4),('abort_held_flush',4),('reset_held_flush','RESET_CANCELLED'),
        ('recovery_after_reset',0)]
    if label=='tiny':
        result += [('final_retirement_precedes_tick_overflow',0),
            ('overflow_before_offer_full_step_high_bits',3),('overflow_retains_held_output',3),
            ('abort_overrides_overflow_hold',4)]
    else:
        result += [('unsigned_max_anchor',0),('backwards_terminal',2),
            ('clock_runs_while_source_absent',0),('pause_and_held_output',0)]
        if label in ('wide','payload_max'):
            result += [('unsigned_sign_boundary',0),('maximum_step_without_narrowing',0)]
    return result

def parse_vectors(path,tw,dw,gw):
    lines=path.read_text(encoding='ascii').splitlines()
    assert lines and re.fullmatch('[0-9]+',lines[0])
    count=int(lines[0]);assert 0<count<=65536 and len(lines)==count+1
    widths=(1,1,1,1,32,48,gw,1,tw,dw,1,1,1,1,1,tw,dw,gw,1,3,32,32,tw,tw+16,gw,1,1)
    stats=dict(command=0,accepted=0,emitted=0,responses=0,held_output=0,held_done=0,paused=0,flush=0)
    for line in lines[1:]:
        words=line.split();assert len(words)==27 and all(re.fullmatch('[0-9a-f]+',word) for word in words)
        values=[int(word,16) for word in words]
        assert all(0<=value<1<<width for value,width in zip(values,widths))
        stats['command']+=int(values[3] and values[12]);stats['accepted']+=int(values[7] and values[13])
        stats['emitted']+=int(values[14] and values[10]);stats['responses']+=int(values[18] and values[11])
        stats['held_output']+=int(values[14] and not values[10]);stats['held_done']+=int(values[18] and not values[11])
        stats['paused']+=int(values[25] and not values[1]);stats['flush']+=values[26]
    return count,stats

def validate_preparation(out,record,report):
    assert record['stderr']['bytes']==0
    raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
    stdout=json.loads(raw);assert isinstance(stdout,dict)
    fixtures=out/'fixtures';receipt=fixtures/'manifest.json'
    manifest=json.loads(receipt.read_bytes())
    assert manifest['schema']=='timestamp-event-replay-fixtures-v1' and manifest['status']=='PREPARED_ONLY'
    assert manifest['fields']==FIELDS and manifest['max_case_cycles']==2048 and manifest['max_profile_rows']==65536
    assert [p['name'] for p in manifest['profiles']]==list(PROFILES)
    expected_names={label+'.txt' for label in PROFILES}|{'feed0.hex','feed1.hex'}
    assert set(manifest['files'])==expected_names and {p.name for p in fixtures.iterdir()}==expected_names|{'manifest.json'}
    for name,value in manifest['files'].items():assert digest(fixtures/name)==value
    total_rows=0
    for item in manifest['profiles']:
        label=item['name'];tw,dw,gw,case_count=PROFILES[label]
        assert (item['time_w'],item['data_w'],item['tag_w'])==(tw,dw,gw)
        rows,stats=parse_vectors(fixtures/(label+'.txt'),tw,dw,gw)
        assert rows==item['rows'] and len(item['cases'])==case_count
        assert [(c['label'],c.get('result',c.get('status'))) for c in item['cases']]==expected_cases(label)
        for case in item['cases']:
            assert 0<=case['start']<case['end']<=rows and case['end']-case['start']<=2049
        assert all(stats[key]==item['coverage'][key] for key in stats if key!='responses')
        assert stats['responses']==case_count-1 and stats['command']==case_count
        assert stats['emitted']>0 and stats['held_output']>0 and stats['flush']>0
        vector=fixtures/(label+'.txt')
        report['profiles'][label]=dict(summary=item,expected_tb=stats,
            files=[dict(path=vector.relative_to(out).as_posix(),sha256=digest(vector),bytes=vector.stat().st_size)])
        total_rows+=rows
    for feed in (0,1):
        words=(fixtures/('feed'+str(feed)+'.hex')).read_text(encoding='ascii').splitlines()
        assert len(words)==96 and all(re.fullmatch('[0-9a-f]{2}',word) for word in words)
    assert stdout==dict(status='PREPARED_ONLY',profiles=4,rows=total_rows,payload_files=6)
    report['preparation_files']=[dict(path=p.relative_to(out).as_posix(),sha256=digest(p),bytes=p.stat().st_size)
        for p in sorted(fixtures.iterdir())]
    assert len(report['preparation_files'])==7
    return dict(prepared_only=True,profiles=4,vector_rows=total_rows,fixture_files=7)

def main():
    assert os.name=='nt' and sys.argv[1:]==['--execute-approved-plan']
    assert Path(sys.executable)==PYTHON_EXE and sys.flags.optimize==0
    assert Path(__file__).resolve()==REPO/'cores/acceleration/timestamp_event_replay/run_checks.py'
    plan=json.loads(PLAN.read_bytes());seal=json.loads(SEAL.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert plan['status']=='FROZEN' and not plan['pending_inputs']
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['peer_reviewer']=='worker_b'
    assert review['execution_gate']==plan['execution_gate']==GATE
    assert review['plan_sha256']==digest(PLAN)==seal['plan_sha256']
    assert review['seal_sha256']==digest(SEAL) and review['runner_sha256']==digest(Path(__file__))
    assert plan['schema']=='anscore-b50-timestamp-replay-plan-v1' and plan['baseline']==seal['baseline']==BASE
    assert review['baseline_commit']==BASE and head_commit()==BASE and review['automatic_retry'] is False
    assert plan['automatic_retry'] is False and plan['children']==commands('<stamp>') and len(plan['children'])==19
    expected_names={(ROOT/name).resolve().relative_to(REPO).as_posix() for name in SOURCES}
    assert set(plan['source_sha256'])==expected_names and plan['source_sha256']==seal['source_sha256']
    assert plan['tools_sha256']==seal['tools_sha256']
    required_tools=(PYTHON_EXE,KILL_EXE,BIN/'iverilog.exe',BIN/'vvp.exe')
    assert all(tool in {Path(name) for name in plan['tools_sha256']} for tool in required_tools)
    inherited=os.environ.get('PATH','')
    effective=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+inherited
    environment=dict(inherited_path_sha256=hashlib.sha256(inherited.encode('utf-8')).hexdigest(),
        effective_path_sha256=hashlib.sha256(effective.encode('utf-8')).hexdigest())
    assert environment==plan['environment']
    def current_inputs():
        assert head_commit()==BASE
        assert hashlib.sha256(os.environ.get('PATH','').encode('utf-8')).hexdigest()==environment['inherited_path_sha256']
        for name,value in plan['source_sha256'].items():assert digest(REPO/name)==value,name
        for name,value in plan['tools_sha256'].items():assert digest(Path(name))==value,name
    current_inputs()
    assert not GUARD.exists() and not (ROOT/'reports').exists() and not (ROOT/'.work').exists()
    pins={'plan':digest(PLAN),'seal':digest(SEAL),'review':digest(REVIEW)}
    durable(GUARD,dict(status='ATTEMPT_STARTED',baseline=BASE,automatic_retry=False,**pins),True)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b50-timestamp-replay-finite-v1',status='INCOMPLETE',baseline=BASE,
        children=[],child_records={},initial_records={},validated_records={},
        active_child=None,active_helpers=[],active_helper=None,
        source_sha256=plan['source_sha256'],tools_sha256=plan['tools_sha256'],archived_sources={},
        profiles={},preparation_files=[],images={},execution_images={},archive_complete=False,suite_complete=False,
        automatic_retry=False,runner_oracle_imports=0,baseline_observed=BASE,environment=environment,**pins)
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
        for item in report['preparation_files']:
            assert digest(out/item['path'])==item['sha256'] and (out/item['path']).stat().st_size==item['bytes']
    save()
    try:
        for key,path in [('plan',PLAN),('seal',SEAL),('review',REVIEW)]:raw_new(out/(key+'.json'),path.read_bytes())
        for name,value in plan['source_sha256'].items():
            target=out/'executed_inputs'/name;target.parent.mkdir(parents=True,exist_ok=True)
            raw_new(target,(REPO/name).read_bytes());assert digest(target)==value
            report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PYTHONDONTWRITEBYTECODE='1');env['PATH']=effective
        assert hashlib.sha256(env['PATH'].encode('utf-8')).hexdigest()==environment['effective_path_sha256']
        for spec in commands(stamp):
            invariant();image_hash=None
            if spec['name'].startswith('simulate_'):
                image=Path(spec['image']);image_hash=digest(image)
                assert image_hash==report['images'][image.relative_to(ROOT).as_posix()]
                report['execution_images'][spec['name']]=dict(path=image.relative_to(ROOT).as_posix(),sha256=image_hash);save()
            record=execute(spec,env,out,report,save);checked=dict(record)
            if spec['name'].startswith('compile_') and Path(spec['image']).is_file():
                image=Path(spec['image']);compiled_hash=digest(image)
                checked['compiled_image_sha256']=compiled_hash
                report['images'][image.relative_to(ROOT).as_posix()]=compiled_hash;save()
            assert record['process_exited'] and record['output_capture_complete'] and record['process_evidence_saved']
            assert not record['cleanup']
            if spec['kind']=='HDL_EXPECTED_REJECTION':
                assert record['status']=='FAIL' and record['exit_code'] not in (None,0)
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')+(out/record['stderr']['path']).read_text(encoding='utf-8')
                assert spec['rejection_marker'] in raw and 'Unknown module type' in raw
                checked.update(expected_rejection_validated=True,actual_nonzero_exit=record['exit_code'])
            else:
                assert record['status']=='PASS' and record['exit_code']==0
            if spec['kind']=='PREPARATION':
                checked.update(validate_preparation(out,record,report))
            elif spec['name'].startswith('simulate_'):
                assert record['execution_image_prechecked'] and record['execution_image_sha256']==image_hash
                initial=out/(spec['name']+'.initial.json');initial_record=json.loads(initial.read_bytes())
                assert initial_record['status']=='STARTING' and initial_record['pid'] is None
                assert initial_record['execution_image_prechecked'] and initial_record['execution_image_sha256']==image_hash
                assert record['stderr']['bytes']==0 and digest(Path(spec['image']))==image_hash
                raw=(out/record['stdout']['path']).read_text(encoding='utf-8')
                lines=[line for line in raw.splitlines() if line.startswith(spec['marker'])]
                assert len(lines)==1 and '$finish called' in raw
                if spec['name']=='simulate_wrapper':
                    assert lines[0]=='PASS paced_dual_itch_replay: four timed actual decoded events, held output, source poison, epoch abort'
                    checked['actual_composition_marker_validated']=True
                else:
                    label=spec['profile'];tw,dw,gw,_=PROFILES[label]
                    matched=re.fullmatch(r'PASS timestamp_event_replay T(\d+) D(\d+) G(\d+) rows=(\d+) emitted=(\d+) responses=(\d+) held=(\d+) flush=(\d+)',lines[0])
                    assert matched is not None
                    observed=list(map(int,matched.groups()));item=report['profiles'][label]
                    expected=[tw,dw,gw,item['summary']['rows'],item['expected_tb']['emitted'],
                        item['expected_tb']['responses'],item['expected_tb']['held_output'],item['expected_tb']['flush']]
                    assert observed==expected
                    checked['observed']=observed;checked['expected']=expected
            checked['metadata_validated']=True
            validation=out/(spec['name']+'.validated.json');durable(validation,checked,True)
            report['validated_records'][validation.name]=dict(sha256=digest(validation),bytes=validation.stat().st_size)
            save();invariant();print(spec['name']+' VALIDATED',flush=True)
        assert len(report['profiles'])==4 and len(report['images'])==5 and len(report['children'])==19
        assert len(report['initial_records'])==len(report['child_records'])==len(report['validated_records'])==19
        assert sum(record['kind']=='PREPARATION' for record in report['children'])==1
        assert sum(record['kind']=='HDL_EXPECTED_REJECTION' for record in report['children'])==6
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
