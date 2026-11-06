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
                helper = subprocess.Popen(helper_record['argv'], cwd=ROOT, env=environment, stdout=out, stderr=err,
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
        process = subprocess.Popen(spec['argv'], cwd=spec['cwd'], env=environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        record['pid'] = process.pid
        record['active_child'] = process.pid
        record['status'] = 'STARTED'
        write(record_path, record)
        for stream in ('stdout','stderr'):
            reader = threading.Thread(target=read_pipe, args=(getattr(process, stream), stream), daemon=True)
            readers.append(reader); reader.start()
        try:
            process.wait(timeout=max(0,20-(time.monotonic()-began)))
        except subprocess.TimeoutExpired:
            record['timed_out'] = True
        if time.monotonic()-began >= 20:
            record['timed_out'] = True
        record['status'] = 'PASS' if process.poll() == 0 and not record['timed_out'] else 'FAIL'
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
            helper_record['status'] = 'PASS' if helper_record['returncode'] == 0 and not helper_record['timed_out'] and not any(
                key in helper_record for key in ('exception','persist_exception','poll_exception')) and helper_record['output_capture_complete'] else 'FAIL'
        record['output_capture_complete'] = record['exit_confirmed'] and all(not reader.is_alive() for reader in readers) and not errors and all(
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
    parser = argparse.ArgumentParser(); parser.add_argument('--execute', action='store_true'); args = parser.parse_args()
    if not args.execute:
        raise SystemExit('No planning or execution mode: explicit --execute and independent review proof required')
    plan_path, seal_path, proof_path = (PACKAGE / name for name in ('PRECHECK_PLAN.json','SOURCE_SEAL.json','REVIEW_CURRENT.json'))
    plan, seal, proof = load(plan_path), load(seal_path), load(proof_path)
    assert proof['status'] == 'NO_BLOCKER_ROOT'
    assert proof['execution_gate'] == 'B45_PERSPECTIVE_UV_ONCE_01'
    assert proof['plan_sha256'] == digest(plan_path) and proof['seal_sha256'] == digest(seal_path)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    with (PACKAGE / 'EXECUTION_LOCK.json').open('x', encoding='utf-8') as stream:
        json.dump(dict(schema='anscore-b45-c-once-v1', stamp=stamp, status='ATTEMPT_STARTED',
            plan_sha256=digest(plan_path), seal_sha256=digest(seal_path), review_sha256=digest(proof_path),
            execution_gate=proof['execution_gate'], automatic_retry=False), stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    report_dir, build_dir = PACKAGE / 'reports' / stamp, PACKAGE / '.build' / stamp
    report_dir.mkdir(parents=True, exist_ok=False); build_dir.mkdir(parents=True, exist_ok=False)
    report = dict(schema='anscore-b45-c-finite-result-v1', status='FAIL_STOP', baseline=plan['baseline'],
        plan_sha256=digest(plan_path), source_seal_sha256=digest(seal_path), review_sha256=digest(proof_path),
        source_sha256=seal['source_sha256'], archived_sources={}, tools=seal['tools'], profiles=[],
        preparations=[], checks=[], vectors={}, images={}, child_records={}, raw_evidence={},
        automatic_retry=False, active_child=None,
        preparation_attempts=0, numerical_preparations=0, oracle_definition_loads=0, runner_oracle_imports=0,
        failure=None, suite_complete=False)
    environment = dict(os.environ)
    environment['PATH'] = os.pathsep.join(plan['path_prefix'] + [environment.get('PATH','')])
    environment['PYTHONDONTWRITEBYTECODE'] = '1'
    frozen = dict(seal['source_sha256'])

    def invariants():
        assert digest(plan_path) == report['plan_sha256'] == digest(report_dir/'PRECHECK_PLAN.json')
        assert digest(seal_path) == report['source_seal_sha256'] == digest(report_dir/'SOURCE_SEAL.json')
        assert digest(proof_path) == report['review_sha256'] == digest(report_dir/'REVIEW_CURRENT.json')
        for source,value in frozen.items():
            assert digest(ROOT / source) == value == digest(PACKAGE / report['archived_sources'][source])
        for path,value in seal['tools'].items(): assert digest(Path(path)) == value
        for path,value in report['vectors'].items(): assert digest(PACKAGE / path) == value
        for path,value in report['images'].items(): assert digest(PACKAGE / path) == value
        for path,value in report['child_records'].items(): assert digest(PACKAGE / path) == value
        for path,value in report['raw_evidence'].items():
            assert digest(PACKAGE/path) == value['sha256'] and (PACKAGE/path).stat().st_size == value['bytes']

    try:
        assert plan['baseline'] == 'a0602fb2dac20db7c524297371a19f5f580980df'
        assert seal['plan_sha256'] == report['plan_sha256']
        assert all(seal['source_sha256'][name] == value for name,value in plan['source_sha256'].items())
        for source,value in frozen.items():
            assert digest(ROOT / source) == value
            destination = report_dir / 'source' / source
            destination.parent.mkdir(parents=True, exist_ok=True); write_raw(destination,(ROOT/source).read_bytes())
            report['archived_sources'][source] = str(destination.relative_to(PACKAGE))
        for source,name in ((plan_path,'PRECHECK_PLAN.json'),(seal_path,'SOURCE_SEAL.json'),(proof_path,'REVIEW_CURRENT.json')):
            write_raw(report_dir/name,source.read_bytes())
        for index,item in enumerate(plan['children']):
            invariants()
            spec = {key: [value.replace('<stamp>',stamp) for value in item[key]] if key=='argv'
                else item[key].replace('<stamp>',stamp) if isinstance(item[key],str) else item[key] for key in item}
            if spec['kind']=='PREPARATION': report['preparation_attempts'] += 1
            record = run_child(spec, report_dir, environment, plan['taskkill'])
            (report['preparations'] if spec['kind']=='PREPARATION' else report['checks']).append(record)
            report['active_child'] = record['active_child']
            for item in [record] + record['cleanup']:
                for stream in ('stdout','stderr'):
                    if stream in item:
                        entry=item[stream]
                        report['raw_evidence'][entry['path']]=dict(sha256=entry['sha256'],bytes=entry['bytes'])
            # Record first, including failures and the exact original execution image.
            if spec['kind']=='HDL_SIMULATION':
                image = Path(spec['argv'][1]); record['execution_image_sha256'] = digest(image)
            if '-o' in spec['argv']:
                image = Path(spec['argv'][spec['argv'].index('-o')+1])
                if image.exists():
                    record['compiled_image_sha256'] = digest(image)
                    report['images'][str(image.relative_to(PACKAGE))] = digest(image)
            child_record=report_dir/(spec['name']+'.json')
            write(child_record, record)
            report['child_records'][str(child_record.relative_to(PACKAGE))]=digest(child_record)
            write(report_dir/'results.json',report)
            assert record['status']=='PASS', ('child fail-stop',spec['name'],record['status'])
            if spec['kind']=='PREPARATION':
                profile = plan['profiles'][len(report['profiles'])]
                directory = report_dir/profile['name']; prepared = load(directory/'preparation.json')
                assert all(prepared['expected_counters'][key]==value for key,value in profile['expected_counters'].items())
                assert 1 <= prepared['expected_counters']['outputs'] <= profile['output_bound']
                assert record['observed']==prepared['expected_counters']
                assert prepared['oracle_definition_loads']==prepared['numerical_preparations']==1
                for name,entry in prepared['files'].items():
                    path=directory/name; assert digest(path)==entry['sha256'] and path.stat().st_size==entry['bytes']
                    report['vectors'][str(path.relative_to(PACKAGE))]=entry['sha256']
                report['vectors'][str((directory/'preparation.json').relative_to(PACKAGE))]=digest(directory/'preparation.json')
                report['profiles'].append(dict(profile, actual_expected_counters=prepared['expected_counters'], preparation=str((directory/'preparation.json').relative_to(report_dir)), preparation_sha256=digest(directory/'preparation.json')))
                report['numerical_preparations']+=1; report['oracle_definition_loads']+=1
            elif spec['kind']=='HDL_SIMULATION':
                profile=next(profile for profile in plan['profiles'] if spec['name']=='sim_'+profile['name'])
                assert all(record['observed'][key]==value for key,value in profile['expected_counters'].items())
                assert all(record['observed'][key]>0 for key in (('holds','done_holds','management_holds') if profile['wrap'] else ('holds','config_holds')))
                prepared_profile=next(item for item in report['profiles'] if item['name']==profile['name'])
                assert all(record['observed'][key]==value for key,value in prepared_profile['actual_expected_counters'].items())
            invariants(); write(report_dir/'results.json',report)
        assert len(report['checks'])==10 and len(report['preparations'])==4 and len(report['images'])==4
        report['suite_complete']=True; report['status']='PASS'
    except BaseException as error:
        report['failure']=dict(type=type(error).__name__,message=str(error))
        raise
    finally:
        write(report_dir/'results.json',report)
        print(json.dumps(dict(status=report['status'],receipt=str((report_dir/'results.json').relative_to(ROOT)),
            preparations=len(report['preparations']),hdl_children=len(report['checks']),automatic_retry=False)))


if __name__=='__main__':
    main()
