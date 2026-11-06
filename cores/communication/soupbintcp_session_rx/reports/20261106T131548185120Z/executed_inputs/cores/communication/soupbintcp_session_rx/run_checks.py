"""B45 source-reviewed finite execution; no numerical planning side effects."""
from pathlib import Path
import argparse, datetime, hashlib, json, os, re, subprocess, sys, time, traceback
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
BASELINE='a0602fb2dac20db7c524297371a19f5f580980df'
BIN=REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN=ROOT/'FINITE_PLAN.json'
SEAL=ROOT/'SOURCE_SEAL.json'
APPROVAL=ROOT/'SOURCE_REVIEW.json'
GUARD=REPO/'.git/anscore-b45-soup-session-rx-once.json'
PROFILES=[dict(label='d32_t1',parameters=[32,1]),dict(label='d128_t8',parameters=[128,8]),
          dict(label='d4096_t32',parameters=[4096,32])]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_bytes())


def commands(stamp,python):
    out=ROOT/'reports'/stamp
    archive=out/'executed_inputs'/ROOT.relative_to(REPO)
    work=ROOT/'.work'/stamp
    checks=[]
    def add(name,argv,kind='HDL',marker=None):
        checks.append(dict(name=name,argv=list(map(str,argv)),cwd=str(archive),kind=kind,
            marker=marker,hard_seconds=20,tree_kill_seconds=5,drain_seconds=2))
    add('prepare_vectors',[python,'-I','-B',archive/'prepare_vectors.py','--output',out/'vectors'],
        'PREPARATION','B45_A_PREP_PASS profiles=3 oracle_imports=1 oracle_preparations=1')
    for profile in PROFILES:
        depth,tag=profile['parameters']
        add('syntax_'+profile['label'],[BIN/'iverilog.exe','-g2012','-Wall','-tnull','-s',
            'soupbintcp_session_rx',f'-Psoupbintcp_session_rx.FIFO_DEPTH={depth}',
            f'-Psoupbintcp_session_rx.TAG_W={tag}','-f','files.f'])
    for profile in PROFILES:
        depth,tag=profile['parameters'];label=profile['label'];image=work/(label+'.vvp')
        add('compile_'+label,[BIN/'iverilog.exe','-g2012','-Wall','-s','tb_soupbintcp_session_rx',
            f'-Ptb_soupbintcp_session_rx.D={depth}',f'-Ptb_soupbintcp_session_rx.T={tag}',
            '-o',image,'-f','files.f','sim/tb_soupbintcp_session_rx.sv'])
        add('sim_'+label,[BIN/'vvp.exe',image,'+vectors='+(out/'vectors'/(label+'.txt')).as_posix()],
            marker='B45_A_SOUP_PASS ')
    return checks


def expected(profile):
    depth,tag=profile['parameters'];counts=profile['counts']
    assert counts['cases']==48 and counts['future']==2 and counts['vector_resets']==31
    assert counts['payload']==depth+38
    checks=counts['cases']+counts['future']+6
    return dict(D=depth,T=tag,cases=48,checks=checks,bytes=counts['bytes']+3*counts['future']+211,
        payload=depth+38,future=2,vector_resets=31,resets=40,cancelled=4,recoveries=4,
        holds=3*counts['payload']+6*checks)


def save_record(out, record):
    with (out/(record['name']+'.json')).open('w',encoding='utf-8',newline='\n') as stream:
        json.dump(record,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())


def execute(spec, env, out, report, save):
    start = time.monotonic()
    child = None
    record = dict(spec,status='STARTING',pid=None,exit_code=None,cleanup=[],
                  output_capture_complete=False,process_exited=False,process_evidence_saved=False)
    (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(record)
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
                child.wait(timeout=max(0.001,20-(time.monotonic()-start)))
                elapsed = time.monotonic()-start
                record['execution_seconds'] = round(elapsed,6)
                record['status'] = 'TIMEOUT' if elapsed>=20 else ('PASS' if child.returncode==0 else 'FAIL')
            except subprocess.TimeoutExpired:
                record['status'] = 'TIMEOUT'
        except Exception:
            record.update(status='SPAWN_FAILED' if child is None else 'HARNESS_FAILED',exception=traceback.format_exc())
        finally:
            if child is not None and child.poll() is None:
                entry = dict(kind='TREE_TERMINATION',hard_seconds=5,status='STARTING')
                record['cleanup'].append(entry)
                helper = None
                helper_start = time.monotonic()
                try:
                    try:
                        save()
                    except Exception as exc:
                        entry['record_error'] = repr(exc)
                    helper_stdout = out/(spec['name']+'.taskkill.stdout.raw')
                    helper_stderr = out/(spec['name']+'.taskkill.stderr.raw')
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
                            helper.wait(timeout=max(0.001,5-(time.monotonic()-helper_start)))
                            entry['status'] = 'EXITED'
                        except subprocess.TimeoutExpired:
                            entry['status'] = 'TIMEOUT'
                            helper.kill()  # Nonwaiting; never use Popen context exit or communicate.
                        entry['exit_code'] = helper.poll()
                        ko.flush();ke.flush();os.fsync(ko.fileno());os.fsync(ke.fileno())
                    for stream,path in [('stdout',helper_stdout),('stderr',helper_stderr)]:
                        entry[stream] = dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
                except Exception as exc:
                    entry['error'] = repr(exc)
                    if helper is not None and helper.poll() is None:
                        try:
                            helper.kill()
                        except Exception as kill_error:
                            entry['helper_kill_error'] = repr(kill_error)
                # Always attempt direct parent termination after the tree helper,
                # including helper spawn, record, archive and timeout failures.
                if child.poll() is None:
                    try:
                        child.kill()
                        entry['direct_parent_kill'] = 'ISSUED'
                    except Exception as exc:
                        entry['direct_parent_kill'] = repr(exc)
                try:
                    child.wait(timeout=2)  # Sole target exit/drain interval after termination.
                except subprocess.TimeoutExpired:
                    entry['target_termination'] = 'UNCONFIRMED'
                except Exception as exc:
                    entry['target_wait_error'] = repr(exc)
            stdout.flush();stderr.flush();os.fsync(stdout.fileno());os.fsync(stderr.fileno())
    code = child.poll() if child is not None else None
    record.update(exit_code=code,process_exited=child is not None and code is not None,
                  output_capture_complete=child is not None and code is not None,
                  seconds=round(time.monotonic()-start,6))
    for stream,path in [('stdout',stdout_path),('stderr',stderr_path)]:
        record[stream] = dict(path=path.name,sha256=digest(path),bytes=path.stat().st_size)
    if child is not None and code is None:
        record['status'] = 'TERMINATION_UNCONFIRMED'
        report['active_child'] = dict(name=spec['name'],pid=child.pid,status='TERMINATION_UNCONFIRMED')
    else:
        report['active_child'] = None
    record['process_evidence_saved'] = True
    save_record(out,record);save()  # Exit/raw SHA/time is durable before marker/receipt/image parsing.
    return record


def run():
    assert os.name == 'nt', 'This fixed finite plan uses the reviewed Windows toolchain.'
    plan,seal,approval = load(PLAN),load(SEAL),load(APPROVAL)
    assert plan['baseline_commit'] == seal['baseline_commit'] == approval['baseline_commit'] == BASELINE
    assert plan['status'] == 'SOURCE_REVIEW_PENDING_NOT_EXECUTED'
    assert plan['source_seal_sha256'] == digest(SEAL) == approval['source_seal_sha256']
    assert approval['plan_sha256'] == digest(PLAN)
    assert approval['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER'
    assert approval['explicit_unique_execution_gate'] is True
    assert approval['execution_gate']=='B45_SOUP_SESSION_RX_ONCE'
    assert approval['root_review']['verdict'] == approval['peer_review']['verdict'] == 'NO_BLOCKER'
    assert approval['root_review']['reviewer'] == 'root' and approval['peer_review']['reviewer'] != 'root'
    assert plan['profiles'] == PROFILES and plan['checks'] == commands('<stamp>',Path(sys.executable))
    assert plan['expected_preparation_children'] == 1 and plan['expected_hdl_children'] == 9
    assert plan['automatic_retry'] is False and plan['fail_stop'] is True
    assert plan['source_sha256'] == {item['path']:item['sha256'] for item in seal['files']}
    for item in seal['files']:
        path = REPO/item['path']
        assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
    for item in plan['tools']:
        path = Path(item['path'])
        assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    with GUARD.open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(dict(schema='anscore-b45-soup-session-rx-once-v1',status='ATTEMPT_STARTED',
            baseline_commit=BASELINE,run_id=stamp,plan_sha256=digest(PLAN),
            source_seal_sha256=digest(SEAL),approval_sha256=digest(APPROVAL),automatic_retry=False),stream,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    out = ROOT/'reports'/stamp
    out.mkdir(parents=True,exist_ok=False)
    (ROOT/'.work'/stamp).mkdir(parents=True,exist_ok=False)
    report = dict(schema='anscore-b45-soup-session-rx-results-v1',status='INCOMPLETE',
        baseline_commit=BASELINE,run_id=stamp,guard=GUARD.relative_to(REPO).as_posix(),guard_sha256=digest(GUARD),
        plan_sha256=digest(PLAN),source_seal_sha256=digest(SEAL),approval_sha256=digest(APPROVAL),
        sources=[],tools=plan['tools'],profiles=[],preparations=[],checks=[],active_child=None,
        archive_complete=False,automatic_retry=False,suite_complete=False,numerical_planning_calls=0,
        oracle_imports=0,oracle_preparations=0,preparation_children=0,
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',ppa='NOT_RUN',hardware='HW_UNVERIFIED')
    def save():
        temporary = out/'results.json.tmp'
        with temporary.open('w',encoding='utf-8',newline='\n') as stream:
            json.dump(report,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        temporary.replace(out/'results.json')
    def invariant():
        assert report['archive_complete']
        for item in report['sources']:
            assert digest(REPO/item['path']) == item['sha256'] == digest(out/item['archive'])
        for name,value in [('plan.json',report['plan_sha256']),('source_seal.json',report['source_seal_sha256']),('source_review.json',report['approval_sha256'])]:
            current = {'plan.json':PLAN,'source_seal.json':SEAL,'source_review.json':APPROVAL}[name]
            assert digest(current) == value == digest(out/name)
        assert digest(GUARD) == report['guard_sha256']
        for item in report['tools']:
            assert digest(Path(item['path'])) == item['sha256']
        for profile in report['profiles']:
            vector = out/'vectors'/profile['path']
            assert digest(vector) == profile['sha256'] and vector.stat().st_size == profile['bytes']
        if 'vector_receipt' in report:
            item = report['vector_receipt']
            assert digest(out/item['path']) == item['sha256']
        for record in report['preparations']+report['checks']:
            for stream in ('stdout','stderr'):
                item = record[stream]
                path = out/item['path']
                assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
            assert load(out/(record['name']+'.json')) == record
        for record in report['checks']:
            if 'image' in record:
                assert digest(REPO/record['image']) == record['image_sha256']
    save()
    try:
        for source,name in [(PLAN,'plan.json'),(SEAL,'source_seal.json'),(APPROVAL,'source_review.json')]:
            (out/name).write_bytes(source.read_bytes())
        for item in seal['files']:
            destination = out/'executed_inputs'/item['path']
            if destination.name == '.gitattributes':
                destination = destination.with_name('.gitattributes.executed.txt')
            destination.parent.mkdir(parents=True,exist_ok=True)
            destination.write_bytes((REPO/item['path']).read_bytes())
            report['sources'].append(dict(item,archive=destination.relative_to(out).as_posix()))
        report['archive_complete'] = True;save()
        env = dict(os.environ,PATH=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+os.environ.get('PATH',''),PYTHONDONTWRITEBYTECODE='1')
        report['environment'] = dict(PATH=env['PATH'],PYTHONDONTWRITEBYTECODE='1')
        for spec in commands(stamp,Path(sys.executable)):
            invariant()
            record = execute(spec,env,out,report,save)
            if record['status']=='PASS' and spec['marker']:
                raw = (out/record['stdout']['path']).read_bytes()
                if sum(line.startswith(spec['marker'].encode()) for line in raw.splitlines())!=1:
                    record['status']='FAIL_MARKER'
            if record['status'] == 'PASS' and spec['kind'] == 'PREPARATION':
                receipt = out/'vectors/receipt.json'
                prepared = load(receipt)
                assert prepared['oracle_imports'] == prepared['oracle_preparations'] == 1
                assert [{key:item[key] for key in ('label','parameters')} for item in prepared['profiles']] == PROFILES
                for profile in prepared['profiles']:
                    expected(profile)
                report['profiles'] = prepared['profiles']
                report['vector_receipt'] = dict(path=receipt.relative_to(out).as_posix(),sha256=digest(receipt))
                report['oracle_imports'] = report['oracle_preparations'] = report['preparation_children'] = 1
            if record['status'] == 'PASS' and spec['name'].startswith('compile_'):
                image = Path(spec['argv'][spec['argv'].index('-o')+1])
                record.update(image=image.relative_to(REPO).as_posix(),image_sha256=digest(image))
            if spec['name'].startswith('sim_'):
                record['execution_image_sha256'] = digest(Path(spec['argv'][1]))
                if record['status'] == 'PASS':
                    assert record['stderr']['bytes'] == 0
                    raw = (out/record['stdout']['path']).read_bytes()
                    line = next(line for line in raw.splitlines() if line.startswith(spec['marker'].encode()))
                    record['observed'] = {key.decode():int(value) for key,value in re.findall(rb'\b(\w+)=(-?\d+)',line)}
                    profile = next(profile for profile in report['profiles'] if spec['name']=='sim_'+profile['label'])
                    if record['observed'] != expected(profile):
                        record['status'] = 'FAIL_COVERAGE'
            save_record(out,record)
            save();invariant();print(spec['name'],record['status'],flush=True)
            if record['status'] != 'PASS':
                report['status'] = 'FAIL_STOP';break
        else:
            report['status'] = 'PASS'
    except Exception:
        report.update(status='RUNNER_FAILED',exception=traceback.format_exc())
    finally:
        try:
            invariant();unchanged = True
        except Exception:
            unchanged = False
        sequence = [item['name'] for item in report['preparations']+report['checks']] == [item['name'] for item in commands(stamp,Path(sys.executable))]
        complete = report['status']=='PASS' and unchanged and sequence and len(report['profiles'])==3
        if report['status']=='PASS' and not complete:
            report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        report.update(inputs_unchanged=unchanged,exact_plan_executed=sequence,suite_complete=complete,
            maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if complete else ['RTL_CANDIDATE','HW_UNVERIFIED'])
        save();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete'] else 1


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--execute',action='store_true',required=True)
    parser.parse_args()
    raise SystemExit(run())
