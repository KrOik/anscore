"""B46 one-shot bounded SE qualification; no project imports or inherited execution."""
from pathlib import Path
import datetime, hashlib, json, os, re, shutil, subprocess, sys, time, traceback
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=ROOT/'FINITE_PLAN.json'
SEAL=ROOT/'SOURCE_SEAL.json'
REVIEW=ROOT/'SOURCE_REVIEW.json'
GUARD=REPO/'.git/anscore-b46-squeeze-excite-once.json'
KILL_EXE=Path(os.environ['SystemRoot'])/'System32/taskkill.exe'
BASE='50b8d36a3ce65cae5c4b3ab4604fa24f3567204b'
PROFILES={'tiny':(1,1,1,1,0),'odd':(9,3,7,8,0),
          'limits':(64,32,4096,32,0),'example':(3,1,7,8,1)}
SOURCES=('.gitattributes','.gitignore','LICENSE','README.md','ARCHITECTURE.md','SOURCES.md',
 'manifest.json','files.f','example/files.f','rtl/int4_squeeze_excite_frame.sv',
 'example/rgb_channel_excitation.sv','model/build_vectors.py','sim/tb_int4_squeeze_excite_frame.sv','run_checks.py',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v','../int4_weight_matvec/rtl/int4_weight_matvec.sv',
 '../integer_divider/rtl/integer_divider.v','../signed8_global_average_pool/rtl/signed8_global_average_pool.sv')


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def commands(stamp):
    out=ROOT/'reports'/stamp
    iv,vvp=str(BIN/'iverilog.exe'),str(BIN/'vvp.exe')
    specs=[]
    def add(name,kind,argv,**extra):
        specs.append(dict(name=name,kind=kind,argv=list(map(str,argv)),cwd=str(ROOT),
                          hard_seconds=20,tree_kill_seconds=5,drain_seconds=2,**extra))
    model=out/'executed_inputs'/ROOT.relative_to(REPO)/'model/build_vectors.py'
    for label in PROFILES:
        add('prepare_'+label,'PREPARATION',[sys.executable,'-I','-B',model,'--profile',label,'--out',out/(label+'.txt')],profile=label)
    add('syntax_default','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_squeeze_excite_frame','-f','files.f'])
    maximum=dict(MAX_CHANNELS=64,MAX_HIDDEN=32,MAX_PIXELS=4096,TAG_W=32)
    add('syntax_maximum','HDL',[iv,'-g2012','-Wall','-tnull','-s','int4_squeeze_excite_frame',
        *['-Pint4_squeeze_excite_frame.%s=%d'%(k,v) for k,v in maximum.items()],'-f','files.f'])
    add('syntax_example','HDL',[iv,'-g2012','-Wall','-tnull','-s','rgb_channel_excitation','-f','example/files.f'])
    for label,values in PROFILES.items():
        image=ROOT/'.work'/stamp/(label+'.vvp')
        add('compile_'+label,'HDL',[iv,'-g2012','-Wall','-s','tb_int4_squeeze_excite_frame',
            *['-Ptb_int4_squeeze_excite_frame.%s=%d'%(k,v) for k,v in zip(('MC','MH','MP','TW','EX'),values)],
            '-o',image,'-f','example/files.f','sim/tb_int4_squeeze_excite_frame.sv'],profile=label,image=str(image))
        add('simulate_'+label,'HDL',[vvp,image,'+VECTORS='+(out/(label+'.txt')).as_posix()],profile=label,image=str(image))
    return specs


def save_record(out, record):
    with (out/(record['name']+'.json')).open('w',encoding='utf-8',newline='\n') as stream:
        json.dump(record,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())


def child(spec, out, env, report, save):
    start = time.monotonic()
    child = None
    record = dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
                  output_capture_complete=False,process_exited=False,process_evidence_saved=False)
    report['children'].append(record)
    report['active_child'] = dict(name=spec['name'],pid=None,status='STARTING')
    save()
    stdout_path = out/(spec['name']+'.stdout.raw')
    stderr_path = out/(spec['name']+'.stderr.raw')
    with stdout_path.open('xb',buffering=0) as stdout, stderr_path.open('xb',buffering=0) as stderr:
        try:
            child = subprocess.Popen(spec['argv'],cwd=spec['cwd'],env=env,stdin=subprocess.DEVNULL,
                stdout=stdout,stderr=stderr,creationflags=subprocess.CREATE_NO_WINDOW)
            record.update(pid=child.pid,status='RUNNING')
            report['active_child'] = dict(name=spec['name'],pid=child.pid,status='RUNNING')
            save()  # A durable acquired PID precedes any wait or result parsing.
            try:
                remaining=20-(time.monotonic()-start)
                if remaining<=0:raise subprocess.TimeoutExpired(spec['argv'],20)
                child.wait(timeout=remaining)
                elapsed = time.monotonic()-start
                record['execution_seconds'] = round(elapsed,6)
                record['status'] = 'TIMEOUT' if elapsed>=20 else ('PASS' if child.returncode==0 else 'FAIL')
            except subprocess.TimeoutExpired:
                record['status'] = 'TIMEOUT'
        except Exception:
            record.update(status='SPAWN_FAILED' if child is None else 'HARNESS_FAILED',exception=traceback.format_exc())
        finally:
            cleanup_needed=False
            if child is not None:
                try:cleanup_needed=child.poll() is None
                except Exception as exc:
                    cleanup_needed=True;record['cleanup_poll_error']=repr(exc)
            if cleanup_needed:
                entry = dict(kind='TREE_TERMINATION',hard_seconds=5,status='STARTING')
                record['cleanup'].append(entry)
                helper = None
                helper_start = time.monotonic()
                helper_stdout = out/(spec['name']+'.taskkill.stdout.raw')
                helper_stderr = out/(spec['name']+'.taskkill.stderr.raw')
                try:
                    try:
                        save()
                    except Exception as exc:
                        entry['record_error'] = repr(exc)
                    with helper_stdout.open('xb',buffering=0) as ko, helper_stderr.open('xb',buffering=0) as ke:
                        helper = subprocess.Popen([str(Path(os.environ['SystemRoot'])/'System32/taskkill.exe'),
                            '/PID',str(child.pid),'/T','/F'],stdin=subprocess.DEVNULL,stdout=ko,stderr=ke,
                            creationflags=subprocess.CREATE_NO_WINDOW)
                        entry.update(pid=helper.pid,status='RUNNING')
                        try:
                            save()
                        except Exception as exc:
                            entry['pid_record_error'] = repr(exc)
                        try:
                            remaining = 5-(time.monotonic()-helper_start)
                            if remaining<=0:
                                raise subprocess.TimeoutExpired('taskkill',5)
                            helper.wait(timeout=remaining)
                            entry['status'] = 'TIMEOUT' if time.monotonic()-helper_start>=5 else 'EXITED'
                        except subprocess.TimeoutExpired:
                            entry['status'] = 'TIMEOUT'
                        ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                except Exception as exc:
                    entry['error'] = repr(exc)
                # Nonwaiting cleanup cannot be bypassed by open/spawn/wait/persist/raw failures.
                helper_alive=False
                if helper is not None:
                    try:helper_alive=helper.poll() is None
                    except Exception as exc:
                        helper_alive=True;entry['helper_poll_error']=repr(exc)
                if helper_alive:
                    try:
                        helper.kill();entry['helper_direct_kill']='ISSUED'
                    except Exception as exc:entry['helper_kill_error']=repr(exc)
                entry['helper_seconds'] = round(time.monotonic()-helper_start,6)
                if time.monotonic()-helper_start>=5:
                    entry['status'] = 'TIMEOUT'
                try:target_alive=child.poll() is None
                except Exception as exc:
                    target_alive=True;entry['target_poll_error']=repr(exc)
                if target_alive:
                    try:child.kill();entry['direct_parent_kill']='ISSUED'
                    except Exception as exc:entry['direct_parent_kill']=repr(exc)
                try:
                    child.wait(timeout=2)  # Sole target exit/drain interval after termination.
                except subprocess.TimeoutExpired:
                    entry['target_termination'] = 'UNCONFIRMED'
                except Exception as exc:
                    entry['target_wait_error'] = repr(exc)
                # No second helper wait: one final nonwaiting observation after the sole target interval.
                try:
                    entry['exit_code'] = None if helper is None else helper.poll()
                    entry['process_exited'] = helper is not None and entry['exit_code'] is not None
                    entry['active_helper'] = helper.pid if helper is not None and entry['exit_code'] is None else None
                except Exception as exc:
                    entry['terminal_poll_error'] = repr(exc)
                    entry.update(exit_code=None,process_exited=False,active_helper=helper.pid if helper is not None else None)
                entry['capture_errors'] = []
                for stream,path in [('stdout',helper_stdout),('stderr',helper_stderr)]:
                    try:
                        if not path.exists():
                            raise FileNotFoundError(str(path))
                        with path.open('ab',buffering=0) as terminal_raw:
                            terminal_raw.flush();os.fsync(terminal_raw.fileno())
                        entry[stream] = dict(path=path.name,sha256=sha(path),bytes=path.stat().st_size)
                    except Exception as exc:
                        entry['capture_errors'].append(dict(stream=stream,error=repr(exc)))
                entry['output_capture_complete'] = entry['process_exited'] and not entry['capture_errors']
            stdout.flush();stderr.flush();os.fsync(stdout.fileno());os.fsync(stderr.fileno())
    try:
        code = child.poll() if child is not None else None
    except Exception as exc:
        code=None;record.update(status='TERMINATION_UNCONFIRMED',terminal_poll_error=repr(exc))
    record.update(exit_code=code,process_exited=child is not None and code is not None,
                  output_capture_complete=child is not None and code is not None and
                      all(entry.get('output_capture_complete',False) for entry in record['cleanup']),
                  seconds=round(time.monotonic()-start,6))
    for stream,path in [('stdout',stdout_path),('stderr',stderr_path)]:
        record[stream] = dict(path=path.name,sha256=sha(path),bytes=path.stat().st_size)
    if child is not None and code is None:
        record['status'] = 'TERMINATION_UNCONFIRMED'
        report['active_child'] = dict(name=spec['name'],pid=child.pid,status='TERMINATION_UNCONFIRMED')
    else:
        report['active_child'] = None
    if any(entry.get('active_helper') is not None for entry in record['cleanup']):
        record['status'] = 'HELPER_TERMINATION_UNCONFIRMED'
    record['process_evidence_saved'] = True
    save_record(out,record);save()  # Exit/raw SHA/time is durable before marker/receipt/image parsing.
    report['child_records'][record['name']+'.json']=sha(out/(record['name']+'.json'))
    save()
    return record,lambda:save_record(out,record)





def run():
    assert os.name=='nt' and sys.argv[1:]==['--execute-approved-plan']
    plan=json.loads(PLAN.read_bytes());seal=json.loads(SEAL.read_bytes());review=json.loads(REVIEW.read_bytes())
    assert plan['baseline_commit']==seal['baseline_commit']==BASE
    assert plan['schema']=='anscore-b46-squeeze-excite-plan-v1'
    assert review['root']==review['peer']=='NO_BLOCKER' and review['peer_reviewer']=='worker_a'
    assert review['execution_gate']=='B46_SQUEEZE_EXCITE_FINITE_ONCE'
    assert review['plan_sha256']==seal['plan_sha256']==sha(PLAN)
    assert review['runner_sha256']==seal['runner_sha256']==sha(Path(__file__))
    assert review['source_seal_sha256']==sha(SEAL)
    assert plan['source_inputs_sha256']==seal['source_inputs_sha256']==review['source_inputs_sha256']
    assert set(plan['source_inputs_sha256'])==set(SOURCES)
    assert plan['children']==commands('<stamp>')
    assert (plan['preparation_children'],plan['hdl_children'],plan['successful_simulations_if_pass'])==(4,11,4)
    assert plan['planning_numerical_calls']==0 and plan['automatic_retry'] is False
    required_tools={str(Path(sys.executable)),str(BIN/'iverilog.exe'),str(BIN/'vvp.exe'),str(KILL_EXE)}
    assert required_tools <= set(plan['tools_sha256'])
    for name,digest in plan['source_inputs_sha256'].items():assert sha(ROOT/name)==digest
    for name,digest in plan['tools_sha256'].items():assert sha(Path(name))==digest
    assert not GUARD.exists() and not (ROOT/'reports').exists() and not (ROOT/'.work').exists()
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    with GUARD.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(dict(schema='anscore-b46-squeeze-excite-once-v1',plan_sha256=sha(PLAN),review_sha256=sha(REVIEW),
                       source_seal_sha256=sha(SEAL),runner_sha256=sha(Path(__file__)),stamp=stamp,automatic_retry=False),stream,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    out=ROOT/'reports'/stamp;work=ROOT/'.work'/stamp
    out.mkdir(parents=True,exist_ok=False);work.mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b46-squeeze-excite-evidence-v1',baseline_commit=BASE,status='INCOMPLETE',
      plan_sha256=sha(PLAN),source_seal_sha256=sha(SEAL),review_sha256=sha(REVIEW),runner_sha256=sha(Path(__file__)),
      children=[],child_records={},active_child=None,active_helper=None,archive_complete=False,
      suite_complete=False,automatic_retry=False,planning_numerical_calls=0,
      source_inputs_sha256=plan['source_inputs_sha256'],tools_sha256=plan['tools_sha256'],archived_inputs={},profiles={},images={},
      hardware='HW_UNVERIFIED',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',
      combined_compile='NOT_RUN',inherited_regression='NOT_RUN')
    def save():
        with (out/'results.json').open('w',encoding='utf-8',newline='\n') as stream:
            json.dump(report,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    def invariant():
        for source,name,key in ((PLAN,'plan.json','plan_sha256'),(SEAL,'source_seal.json','source_seal_sha256'),(REVIEW,'review.json','review_sha256')):
            assert sha(source)==report[key]==sha(out/name)
        for name,digest in report['source_inputs_sha256'].items():assert sha(ROOT/name)==digest==sha(ROOT/report['archived_inputs'][name])
        for name,digest in report['tools_sha256'].items():assert sha(Path(name))==digest
        for label,summary in report['profiles'].items():assert sha(out/(label+'.txt'))==summary['sha256']
        for name,digest in report['images'].items():assert sha(ROOT/name)==digest
        for name,digest in report['child_records'].items():assert sha(out/name)==digest
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for key in ('stdout','stderr'):assert sha(out/record[key]['path'])==record[key]['sha256']
                for entry in record['cleanup']:
                    for key in ('stdout','stderr'):
                        if key in entry:assert sha(out/entry[key]['path'])==entry[key]['sha256']
    save()
    try:
        for source,name in ((PLAN,'plan.json'),(SEAL,'source_seal.json'),(REVIEW,'review.json')):shutil.copyfile(source,out/name)
        for name,digest in report['source_inputs_sha256'].items():
            source=(ROOT/name).resolve();assert source.is_relative_to(REPO)
            target=out/'executed_inputs'/source.relative_to(REPO)
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,target)
            assert sha(target)==digest;report['archived_inputs'][name]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;save();invariant()
        env=dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
        for spec in commands(stamp):
            invariant()
            image_before=sha(Path(spec['image'])) if spec['name'].startswith('simulate_') else None
            record,_=child(spec,out,env,report,save)
            report['active_helper']=next((entry['active_helper'] for entry in record['cleanup']
                                          if entry.get('active_helper') is not None),None)
            def persist():
                save_record(out,record);report['child_records'][record['name']+'.json']=sha(out/(record['name']+'.json'));save()
            # child() has already durably saved terminal PID/exit/raw hashes before this parsing.
            if image_before is not None:record['execution_image_sha256']=image_before
            if 'image' in spec and Path(spec['image']).is_file():
                image=Path(spec['image']);digest=sha(image)
                record.update(image=image.relative_to(ROOT).as_posix(),image_sha256=digest)
                report['images'].setdefault(image.relative_to(ROOT).as_posix(),digest)
            if record['status']=='PASS':
                try:
                    assert record['exit_code']==0 and record['process_exited'] and record['output_capture_complete'] and not record['cleanup']
                    if spec['kind']=='PREPARATION':
                        assert record['stderr']['bytes']==0
                        summary=json.loads((out/record['stdout']['path']).read_bytes())
                        label=spec['profile'];vector=out/(label+'.txt')
                        assert summary['profile']==label and summary['file']==str(vector)
                        assert summary['sha256']==sha(vector) and summary['bytes']==vector.stat().st_size
                        assert summary['frames']==(14 if label=='example' else 40 if label=='limits' else 38)
                        assert summary['oracle_frames']==(11 if label=='example' else 24 if label=='limits' else 22)
                        assert summary['resets']==(6 if label=='example' else 7)
                        report['profiles'][label]=summary
                    elif spec['name'].startswith('compile_'):
                        assert 'image_sha256' in record
                    elif spec['name'].startswith('simulate_'):
                        assert record['stderr']['bytes']==0 and sha(Path(spec['image']))==image_before
                        text=(out/record['stdout']['path']).read_text(encoding='utf-8')
                        lines=[line for line in text.splitlines() if line.startswith('PASS SE ')]
                        assert len(lines)==1 and '$finish called' in text
                        observed={k:int(v) for k,v in re.findall(r'\b([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)',lines[0])}
                        label=spec['profile'];summary=report['profiles'][label]
                        assert tuple(observed[k] for k in ('MC','MH','MP','TW','EX'))==PROFILES[label]
                        assert observed['frames']==summary['frames'] and observed['resets']==summary['resets']
                        assert observed['configs']==summary['configs']+(0 if label=='example' else summary['oracle_frames'])
                        assert observed['outputs']>0 and observed['holds']==2*observed['outputs']
                        assert observed['rsp_holds']==3*observed['frames'] and observed['cfg_holds']==2*summary['configs']
                        record['observed']=observed
                    record['metadata_validated']=True
                except Exception:record.update(status='FAIL_METADATA',metadata_exception=traceback.format_exc())
            persist();print(spec['name'],record['status'],flush=True)
            if record['status']!='PASS':report['status']='FAIL_STOP';break
        else:report['status']='PASS'
    except Exception:report.update(status='HARNESS_FAILED',exception=traceback.format_exc())
    finally:
        try:invariant();unchanged=True
        except Exception:unchanged=False
        exact=[r['name'] for r in report['children']]==[s['name'] for s in commands(stamp)]
        ok=report['status']=='PASS' and exact and unchanged and report['archive_complete'] and report['active_child'] is None and report['active_helper'] is None
        report.update(inputs_unchanged=unchanged,exact_plan_executed=exact,suite_complete=ok,
          preparation_children=sum(r['kind']=='PREPARATION' for r in report['children']),
          hdl_children=sum(r['kind']=='HDL' for r in report['children']),
          successful_simulations=sum(r['name'].startswith('simulate_') and r['status']=='PASS' for r in report['children']),
          independent_oracle_frames=sum(p['oracle_frames'] for p in report['profiles'].values()),
          maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED'])
        if report['status']=='PASS' and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        save();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1


if __name__=='__main__':raise SystemExit(run())
