"""B47 independently gated bounded static launcher.
Execution requires frozen controls and the exact independent root/peer gate.
"""
from pathlib import Path
import datetime,hashlib,json,os,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent.parent
HERE=ROOT/'docs/snapshots/b47'
PLAN=ROOT/'.git/anscore-b47-static-plan.json'
REVIEW=ROOT/'.git/anscore-b47-static-review.json'
HELPER=ROOT/'.git/anscore-b47-static-audit.py'
GUARD=ROOT/'.git/anscore-b47-static-launch-once.json'
OUT=ROOT/'.git/anscore-b47-static-launch'
KILL_EXE=Path(os.environ['SystemRoot'])/'System32/taskkill.exe'
BASE='d32ea87e268c5957b7203560a5b46864e282a6e1'
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def durable(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        json.dump(value,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())

def archive(path,data):
    with path.open('xb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
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
    assert Path(__file__).resolve()==ROOT/'.git/anscore-b47-static-launch.py','Draft launcher must not execute'
    plan=json.loads(PLAN.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert plan['status']=='FROZEN' and not plan['pending_inputs']
    assert plan['schema']=='anscore-b47-static-plan-v1' and plan['baseline_commit']==BASE and plan['automatic_retry'] is False
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['peer_reviewer'] in ('worker_a','worker_c') and review['execution_gate']=='B47_STATIC_ONCE_01'
    assert plan['execution_gate']==review['execution_gate']
    assert review['plan_sha256']==digest(PLAN) and review['helper_sha256']==digest(HELPER)
    assert review['launcher_sha256']==digest(Path(__file__))
    assert (ROOT/plan['helper']).resolve()==HELPER and (ROOT/plan['launcher']).resolve()==Path(__file__).resolve()
    assert plan['outputs']==['source.json','structure.json','audit_once.json','failure.json']
    assert plan['expected_structure']==dict(packages=188,source_files=411,module_declarations=413,
        unresolved_module_collisions=0,new_canonical_sources=8,inherited_canonical_sources=403)
    assert plan['new_dependency_bridges']==[] and plan['baseline_tree_paths']==35892
    pins={name:digest(current) for name,current in [('plan',PLAN),('review',REVIEW),('helper',HELPER)]}
    inputs,tools=plan['input_sha256'],plan['tool_sha256']
    assert tools[str(Path(sys.executable))]==digest(Path(sys.executable))
    assert tools[str(KILL_EXE)]==digest(KILL_EXE)
    spec=dict(name='static_audit',kind='STATIC',argv=[sys.executable,'-I','-B',str(HELPER),'--execute-approved-plan'],
        cwd=str(ROOT),marker='B47_STATIC_PASS ',hard_seconds=20,tree_kill_seconds=5,drain_seconds=2)
    assert spec==plan['child']
    def invariant():
        for name,current in [('plan',PLAN),('review',REVIEW),('helper',HELPER)]:assert digest(current)==pins[name]
        assert digest(Path(__file__))==review['launcher_sha256']
        for name,value in inputs.items():assert digest(ROOT/name)==value,name
        for name,value in tools.items():assert digest(Path(name))==value,name
    invariant()
    assert not GUARD.exists() and not OUT.exists() and not HERE.exists()
    durable(GUARD,dict(schema='anscore-b47-static-launch-once-v1',status='ATTEMPT_STARTED',
        plan_sha256=pins['plan'],review_sha256=pins['review'],helper_sha256=pins['helper'],
        launcher_sha256=review['launcher_sha256'],automatic_retry=False),True)
    OUT.mkdir(exist_ok=False);HERE.mkdir(exist_ok=False)
    report=dict(schema='anscore-b47-static-launch-v1',status='INCOMPLETE',children=[],child_records={},active_child=None,
        active_helpers=[],active_helper=None,input_sha256=inputs,tools_sha256=tools,plan_sha256=pins['plan'],
        review_sha256=pins['review'],helper_sha256=pins['helper'],launcher_sha256=review['launcher_sha256'],
        automatic_retry=False,suite_complete=False,inputs_unchanged=False,exact_plan_executed=False,archive_complete=False)
    def save():durable(OUT/'results.json',report)
    save()
    try:
        controls=[('plan.json',PLAN),('root_review.json',REVIEW),('audit_source.py',HELPER),('launcher.py',Path(__file__))]
        for name,current in controls:
            data=current.read_bytes();archive(OUT/name,data);archive(HERE/name,data)
        report['archive_complete']=True;save()
        invariant()
        record=execute(spec,dict(os.environ,PYTHONDONTWRITEBYTECODE='1'),OUT,report,save)
        assert record['status']=='PASS' and record['exit_code']==0 and record['process_exited'] and record['output_capture_complete']
        assert record['process_evidence_saved'] and not record['cleanup']
        invariant()
        for name,current in controls:
            expected=digest(current)
            assert digest(OUT/name)==expected and digest(HERE/name)==expected
        for name,item in report['child_records'].items():assert digest(OUT/name)==item['sha256'] and (OUT/name).stat().st_size==item['bytes']
        for stream in ('stdout','stderr'):
            item=record[stream];assert digest(OUT/item['path'])==item['sha256'] and (OUT/item['path']).stat().st_size==item['bytes']
        raw=(OUT/record['stdout']['path']).read_bytes()
        assert sum(line.startswith(b'B47_STATIC_PASS ') for line in raw.splitlines())==1 and record['stderr']['bytes']==0
        structure=json.loads((HERE/'structure.json').read_bytes())
        source=json.loads((HERE/'source.json').read_bytes())
        assert structure['status']=='PASS' and structure['packages']==len(source['packages'])==188
        assert structure['source_files']==411 and structure['module_declarations']==413 and not structure['unresolved_module_collisions']
        assert structure['actual_finite_counts']==source['batch_actual_counts']==plan['expected_counts']
        assert len(structure['retained_images'])==plan['expected_images']==18
        assert len(structure['evidence_receipts'])==5 and sum(x['helper_raw_streams'] for x in structure['evidence_receipts'])==2
        assert sum(x['timed_out_simulation'] for x in structure['retained_images'].values())==1
        assert sum(x['successful_simulation'] for x in structure['retained_images'].values())==17
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS',suite_complete=True,inputs_unchanged=True,exact_plan_executed=True,
            outputs_sha256={name:digest(HERE/name) for name in ('source.json','structure.json','audit_once.json')})
    except BaseException:
        report.update(status='FAIL_STOP',exception=traceback.format_exc())
    finally:
        save();print(json.dumps(dict(status=report['status'],suite_complete=report['suite_complete'],receipt=str(OUT/'results.json'))))
    return 0 if report['suite_complete'] else 1


if __name__=='__main__':raise SystemExit(main())