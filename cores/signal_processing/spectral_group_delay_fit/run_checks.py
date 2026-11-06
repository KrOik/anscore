"""SPDX-License-Identifier: Apache-2.0. Sealed, gated, one-attempt finite runner.

Does not import any project model/runner/auditor. Preparation is direct archived
Python execution. Every started process is recorded before any failure propagates.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[2]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_bytes())


def write(path, value):
    with path.open('wb') as stream:
        stream.write((json.dumps(value, indent=2) + '\n').encode('utf-8'))
        stream.flush()
        os.fsync(stream.fileno())


def write_raw(path, value):
    with path.open('wb') as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())


def run_child(spec, report_dir, environment, taskkill):
    record = dict(spec, status='NOT_STARTED', returncode=None, cleanup=[], active_child=None,
        timed_out=False, output_capture_complete=False, process_evidence_saved=False)
    record_path = report_dir / (spec['name'] + '.json')
    write(record_path, record)
    chunks, errors, readers = {name: [] for name in ('stdout','stderr')}, [], []
    process = helper = helper_record = None
    capture_started = False
    helper_paths = {}
    began = time.monotonic()

    def read_pipe(pipe, stream):
        try:
            while True:
                chunk = pipe.read(65536)
                if not chunk:
                    break
                chunks[stream].append(chunk)
        except BaseException as error:
            errors.append(type(error).__name__ + ': ' + str(error))

    def kill_nonwaiting(handle, entry, key):
        if handle is None:
            return
        try:
            alive = handle.poll() is None
        except BaseException as error:
            entry[key + '_poll_exception'] = type(error).__name__ + ': ' + str(error)
            alive = True
        if alive:
            entry[key] = dict(pid=handle.pid, waiting=False, attempted=True)
            try:
                handle.kill()
            except BaseException as error:
                entry[key]['exception'] = type(error).__name__ + ': ' + str(error)

    def observe(handle, entry, active_key):
        try:
            entry['returncode'] = handle.poll() if handle is not None else None
            entry[active_key] = handle.pid if handle is not None and entry['returncode'] is None else None
            entry['exit_confirmed'] = handle is not None and entry['returncode'] is not None
        except BaseException as error:
            entry['returncode'] = None
            entry[active_key] = handle.pid if handle is not None else None
            entry['exit_confirmed'] = False
            entry['poll_exception'] = type(error).__name__ + ': ' + str(error)

    def close_tree():
        nonlocal helper, helper_record, helper_paths
        helper_began = time.monotonic()
        deadline = helper_began + 5
        helper_record = dict(argv=[taskkill, '/PID', str(process.pid), '/T', '/F'],
            timeout_seconds=5, returncode=None, status='NOT_STARTED', timed_out=False,
            output_capture_complete=False, active_helper=None)
        record['cleanup'].append(helper_record)
        # Helper output is captured directly to binary files, never pipe-drained.
        helper_paths = {stream: report_dir / (spec['name'] + '.taskkill.' + stream + '.raw') for stream in ('stdout','stderr')}
        try:
            with helper_paths['stdout'].open('xb') as out, helper_paths['stderr'].open('xb') as err:
                helper = subprocess.Popen(helper_record['argv'], cwd=ROOT, env=environment, stdin=subprocess.DEVNULL, stdout=out, stderr=err,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
                helper_record['pid'] = helper.pid
                helper_record['status'] = 'STARTED'
                write(record_path, record)
                try:
                    remaining = deadline-time.monotonic()
                    if remaining <= 0:
                        helper_record['timed_out'] = True
                    else:
                        helper.wait(timeout=remaining)
                except subprocess.TimeoutExpired:
                    helper_record['timed_out'] = True
                if time.monotonic()-helper_began >= 5:
                    helper_record['timed_out'] = True
        except BaseException as error:
            helper_record['status'] = 'EXCEPTION'
            helper_record['exception'] = type(error).__name__ + ': ' + str(error)
        finally:
            # Persistence, spawn, wait and file exceptions cannot bypass this kill.
            kill_nonwaiting(helper, helper_record, 'helper_kill_fallback')
            observe(helper, helper_record, 'active_helper')
            helper_record['elapsed_seconds'] = round(time.monotonic()-helper_began, 6)
            if time.monotonic()-helper_began >= 5:
                helper_record['timed_out'] = True
            try:
                write(record_path, record)
            except BaseException as error:
                helper_record['persist_exception'] = type(error).__name__ + ': ' + str(error)

    try:
        process = subprocess.Popen(spec['argv'], cwd=spec['cwd'], env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        record['pid'] = process.pid
        record['active_child'] = process.pid
        record['status'] = 'STARTED'
        write(record_path, record)
        for stream in ('stdout','stderr'):
            reader = threading.Thread(target=read_pipe, args=(getattr(process, stream), stream), daemon=True)
            readers.append(reader); reader.start()
        capture_started = True
        try:
            process.wait(timeout=max(0,20-(time.monotonic()-began)))
        except subprocess.TimeoutExpired:
            record['timed_out'] = True
        if time.monotonic()-began >= 20:
            record['timed_out'] = True
        record['status'] = 'TIMEOUT' if record['timed_out'] else 'PASS' if process.poll() == 0 else 'FAIL'
    except BaseException as error:
        record['status'] = 'EXCEPTION'
        record['exception'] = type(error).__name__ + ': ' + str(error)
    finally:
        try:
            if process is not None and process.poll() is None:
                close_tree()
        except BaseException as error:
            record['cleanup_exception'] = type(error).__name__ + ': ' + str(error)
        finally:
            # Even an unexpected close_tree exception cannot skip either kill.
            kill_nonwaiting(helper, helper_record if helper_record is not None else record, 'helper_outer_kill_fallback')
            kill_nonwaiting(process, record, 'target_kill_fallback')
        deadline = time.monotonic() + 2
        try:
            if process is not None and process.poll() is None:
                process.wait(timeout=max(0, deadline-time.monotonic()))
        except subprocess.TimeoutExpired:
            record['target_exit_observation_timed_out'] = True
        except BaseException as error:
            record['target_exit_observation_exception'] = type(error).__name__ + ': ' + str(error)
        for reader in readers:
            try:
                reader.join(timeout=max(0, deadline-time.monotonic()))
            except BaseException as error:
                errors.append(type(error).__name__ + ': ' + str(error))
        observe(process, record, 'active_child')
        # No helper wait is added: poll after the sole shared exit/drain interval.
        if helper_record is not None:
            observe(helper, helper_record, 'active_helper')
            capture_errors = []
            for stream, path in helper_paths.items():
                try:
                    with path.open('ab') as raw_stream:
                        raw_stream.flush()
                        os.fsync(raw_stream.fileno())
                    helper_record[stream] = dict(path=str(path.relative_to(PACKAGE)), sha256=digest(path), bytes=path.stat().st_size)
                except BaseException as error:
                    capture_errors.append(type(error).__name__ + ': ' + str(error))
            helper_record['capture_errors'] = capture_errors
            helper_record['output_capture_complete'] = helper_record['exit_confirmed'] and not capture_errors and all(
                stream in helper_record for stream in ('stdout','stderr'))
            helper_record['status'] = 'TIMEOUT' if helper_record['timed_out'] else 'PASS' if helper_record['returncode'] == 0 and not any(
                key in helper_record for key in ('exception','persist_exception','poll_exception')) and helper_record['output_capture_complete'] else 'FAIL'
        record['output_capture_complete'] = record['exit_confirmed'] and capture_started and len(readers)==2 and all(not reader.is_alive() for reader in readers) and not errors and all(
            item['output_capture_complete'] for item in record['cleanup'])
        record['capture_errors'] = list(errors)
        if record['active_child'] is not None or not record['output_capture_complete'] or any(
                item.get('active_helper') is not None or not item['output_capture_complete'] or item['status']!='PASS' for item in record['cleanup']):
            record['status'] = 'FAIL_CAPTURE_OR_CLEANUP'
        try:
            for stream in ('stdout','stderr'):
                raw = b''.join(chunks[stream])
                path = report_dir / (spec['name'] + '.' + stream + '.raw')
                write_raw(path, raw)
                record[stream] = dict(path=str(path.relative_to(PACKAGE)), sha256=digest(path), bytes=len(raw))
            record['elapsed_seconds'] = round(time.monotonic()-began, 6)
            record['process_evidence_saved'] = True
            write(record_path, record)
            # Durable process/raw evidence precedes marker or other metadata parsing.
            if record['status'] == 'PASS' and spec.get('marker'):
                lines = [line for line in b''.join(chunks['stdout']).splitlines() if line.startswith(spec['marker'].encode())]
                if len(lines) == 1:
                    record['observed'] = {key.decode(): int(value) for key,value in re.findall(rb'\b(\w+)=(-?\d+)', lines[0])}
                else:
                    record['status'] = 'FAIL_MARKER'
            if spec['kind'] == 'HDL_SIMULATION' and b''.join(chunks['stderr']):
                record['status'] = 'FAIL_SIMULATION_STDERR'
        except BaseException as error:
            record['status'] = 'FAIL_FINALIZE'
            record['output_capture_complete'] = False
            record['finalize_exception'] = type(error).__name__ + ': ' + str(error)
        finally:
            record['elapsed_seconds'] = round(time.monotonic()-began, 6)
            try:
                write(record_path, record)
            except BaseException as error:
                record['status'] = 'FAIL_PERSIST'
                record['persist_exception'] = type(error).__name__ + ': ' + str(error)
    return record


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--execute-approved-plan',action='store_true')
    args=parser.parse_args()
    assert args.execute_approved_plan, 'Exact root/peer gate required'
    plan_path,seal_path,review_path=(PACKAGE/name for name in ('PRECHECK_PLAN.json','SOURCE_SEAL.json','ROOT_REVIEW.json'))
    plan,seal,review=load(plan_path),load(seal_path),load(review_path)
    assert os.name=='nt' and Path(sys.executable).resolve()==Path(plan['python']).resolve()
    assert review['verdict']=='NO_BLOCKER_ROOT_AND_PEER' and review['root']==review['peer']=='NO_BLOCKER'
    assert review['peer_reviewer'] in ('worker_a','worker_c')
    assert review['execution_gate']=='B46_SPECTRAL_GROUP_DELAY_FIT_ONCE_01'
    assert review['plan_sha256']==digest(plan_path) and review['seal_sha256']==digest(seal_path)
    assert seal['plan_sha256']==digest(plan_path) and plan['source_sha256']==seal['source_sha256']
    assert plan['baseline']=='50b8d36a3ce65cae5c4b3ab4604fa24f3567204b'
    assert plan['automatic_retry'] is False and len(plan['children'])==17
    for name,value in seal['source_sha256'].items():assert digest(ROOT/name)==value
    for name,value in seal['tools'].items():assert digest(Path(name))==value
    assert not (PACKAGE/'EXECUTION_LOCK.json').exists() and not (PACKAGE/'reports').exists()
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    with (PACKAGE/'EXECUTION_LOCK.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(dict(schema='anscore-b46-b-once-v1',stamp=stamp,status='ATTEMPT_STARTED',
            plan_sha256=digest(plan_path),seal_sha256=digest(seal_path),review_sha256=digest(review_path),
            execution_gate=review['execution_gate'],automatic_retry=False),stream,indent=2)
        stream.write('\n');stream.flush();os.fsync(stream.fileno())
    report_dir=PACKAGE/'reports'/stamp
    build_dir=PACKAGE/'.build'/stamp
    report_dir.mkdir(parents=True,exist_ok=False);build_dir.mkdir(parents=True,exist_ok=False)
    report=dict(schema='anscore-b46-b-finite-v1',status='INCOMPLETE',baseline=plan['baseline'],
        plan_sha256=digest(plan_path),source_seal_sha256=digest(seal_path),review_sha256=digest(review_path),
        source_sha256=seal['source_sha256'],archived_sources={},tools=seal['tools'],profiles=[],
        preparations=[],checks=[],vectors={},images={},child_records={},raw_evidence={},
        archive_complete=False,automatic_retry=False,active_child=None,active_helper=None,
        preparation_attempts=0,numerical_preparations=0,oracle_definition_loads=0,runner_oracle_imports=0,
        suite_complete=False,inputs_unchanged=False,exact_plan_executed=False,failure=None,
        synthesis=False,pnr=False,sta=False,board=False,ppa=False,hardware='HW_UNVERIFIED')
    write(report_dir/'results.json',report)
    environment=dict(os.environ,PYTHONDONTWRITEBYTECODE='1')
    environment['PATH']=os.pathsep.join(plan['path_prefix']+[environment.get('PATH','')])

    def invariants():
        for current,name,expected in ((plan_path,'PRECHECK_PLAN.json',report['plan_sha256']),
            (seal_path,'SOURCE_SEAL.json',report['source_seal_sha256']),
            (review_path,'ROOT_REVIEW.json',report['review_sha256'])):
            assert digest(current)==expected==digest(report_dir/name)
        assert set(report['archived_sources'])==set(seal['source_sha256'])
        for name,value in seal['source_sha256'].items():
            assert digest(ROOT/name)==value==digest(PACKAGE/report['archived_sources'][name])
        for name,value in seal['tools'].items():assert digest(Path(name))==value
        for mapping in ('vectors','images','child_records'):
            for name,value in report[mapping].items():assert digest(PACKAGE/name)==value
        for name,item in report['raw_evidence'].items():
            assert digest(PACKAGE/name)==item['sha256'] and (PACKAGE/name).stat().st_size==item['bytes']

    try:
        for name,value in seal['source_sha256'].items():
            target=report_dir/'source'/name;target.parent.mkdir(parents=True,exist_ok=True)
            write_raw(target,(ROOT/name).read_bytes());assert digest(target)==value
            report['archived_sources'][name]=str(target.relative_to(PACKAGE))
        for current,name in ((plan_path,'PRECHECK_PLAN.json'),(seal_path,'SOURCE_SEAL.json'),(review_path,'ROOT_REVIEW.json')):
            write_raw(report_dir/name,current.read_bytes())
        report['archive_complete']=True;write(report_dir/'results.json',report)
        for item in plan['children']:
            invariants()
            spec={key:[part.replace('<stamp>',stamp) for part in value] if key=='argv'
                else value.replace('<stamp>',stamp) if isinstance(value,str) else value for key,value in item.items()}
            execution_image=None
            if spec['kind']!='PREPARATION':
                assert len(report['profiles'])==5 and len(report['preparations'])==5 and len(report['vectors'])==10
            if spec['kind']=='HDL_SIMULATION':
                image=Path(spec['argv'][1]);execution_image=digest(image)
                assert report['images'][str(image.relative_to(PACKAGE))]==execution_image
                assert len(report['profiles'])==5 and len(report['preparations'])==5
            if spec['kind']=='PREPARATION':report['preparation_attempts']+=1
            report['active_child']=dict(name=spec['name'],pid_record=spec['name']+'.json')
            write(report_dir/'results.json',report)
            record=run_child(spec,report_dir,environment,plan['taskkill'])
            (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(record)
            report['active_child']=record['active_child']
            report['active_helper']=next((entry.get('active_helper') for entry in record['cleanup'] if entry.get('active_helper')),None)
            for entry in [record]+record['cleanup']:
                for stream in ('stdout','stderr'):
                    if stream in entry:
                        raw=entry[stream];report['raw_evidence'][raw['path']]=dict(sha256=raw['sha256'],bytes=raw['bytes'])
            if execution_image is not None:
                record['execution_image_sha256']=execution_image
                assert digest(Path(spec['argv'][1]))==execution_image
            if '-o' in spec['argv']:
                image=Path(spec['argv'][spec['argv'].index('-o')+1])
                if image.exists():
                    record['compiled_image_sha256']=digest(image)
                    report['images'][str(image.relative_to(PACKAGE))]=record['compiled_image_sha256']
            child_path=report_dir/(spec['name']+'.json')
            write(child_path,record)
            report['child_records'][str(child_path.relative_to(PACKAGE))]=digest(child_path)
            write(report_dir/'results.json',report)
            assert record['status']=='PASS' and record['exit_confirmed'] and record['output_capture_complete']
            assert not record['cleanup'] and record['process_evidence_saved']
            if spec['kind']=='PREPARATION':
                profile=next(entry for entry in plan['profiles'] if spec['name']=='prepare_'+entry['name'])
                directory=report_dir/profile['name'];prepared=load(directory/'preparation.json')
                assert prepared['profile']==profile['name'] and prepared['expected_counters']==profile['expected_counters']==record['observed']
                assert prepared['oracle_definition_loads']==prepared['numerical_preparations']==1
                assert prepared['cases']==profile['expected_counters']['cases'] and len(prepared['files'])==profile['epochs']
                for name,entry in prepared['files'].items():
                    vector=directory/name
                    assert digest(vector)==entry['sha256'] and vector.stat().st_size==entry['bytes']
                    lines=vector.read_text(encoding='ascii').splitlines()
                    assert entry['rows']==len(lines)-1 and int(lines[0])==profile['expected_counters']['cases']
                    report['vectors'][str(vector.relative_to(PACKAGE))]=entry['sha256']
                prep_path=directory/'preparation.json'
                report['vectors'][str(prep_path.relative_to(PACKAGE))]=digest(prep_path)
                report['profiles'].append(dict(profile,preparation=str(prep_path.relative_to(PACKAGE)),preparation_sha256=digest(prep_path)))
                report['numerical_preparations']+=1;report['oracle_definition_loads']+=1
            elif spec['kind']=='HDL_SIMULATION':
                profile=next(entry for entry in plan['profiles'] if spec['name']=='sim_'+entry['name'])
                assert record['observed']==profile['expected_counters']
                stdout=(PACKAGE/record['stdout']['path']).read_bytes()
                assert b'$finish called' in stdout and record['stderr']['bytes']==0
            invariants();write(report_dir/'results.json',report)
        assert len(report['preparations'])==5 and len(report['checks'])==12 and len(report['images'])==5
        assert report['active_child'] is None and report['active_helper'] is None
        report.update(status='PASS',suite_complete=True,inputs_unchanged=True,exact_plan_executed=True)
    except BaseException as error:
        report.update(status='FAIL_STOP',failure=dict(type=type(error).__name__,message=str(error)))
        raise
    finally:
        write(report_dir/'results.json',report)
        print(json.dumps(dict(status=report['status'],receipt=str((report_dir/'results.json').relative_to(ROOT)),
            preparations=len(report['preparations']),hdl_children=len(report['checks']),automatic_retry=False)))


if __name__=='__main__':
    main()


