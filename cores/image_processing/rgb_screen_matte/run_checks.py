"""B50 matte finite source candidate; never runs without the exact root/A gate."""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import traceback

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BIN = REPO / 'tools/oss-cad-suite/oss-cad-suite/bin'
KILL_EXE = Path(os.environ['SystemRoot']) / 'System32/taskkill.exe'
GUARD = REPO / '.git/anscore-b50-matte-once.json'
PLAN = ROOT / 'FINITE_PLAN.json'
SEAL = ROOT / 'SOURCE_SEAL.json'
REVIEW = ROOT / 'SOURCE_REVIEW.json'
BASE = 'c9117a22459e954d496dfa66dd94d6f67188c862'
GATE = 'B50_MATTE_ONCE_01'
EXPECTED_ROWS = 1262
SOURCES = (
    '.gitattributes', 'ARCHITECTURE.md', 'files.f', 'LICENSE', 'manifest.json',
    'README.md', 'reference_model.py', 'references.json', 'SOURCE_ROOT_REVIEW.json',
    'SOURCES.md', 'VERIFY_PLAN.md', 'example/files.f', 'example/screen_matte_over.sv',
    'rtl/rgb_screen_matte.sv', 'sim/tb_rgb_screen_matte.sv',
    'sim/tb_screen_matte_over.sv', 'sim/vector_reader.svh',
    'tools/prepare_vectors.py', 'run_checks.py',
    '../rgba_porter_duff/rtl/rgba_porter_duff.sv', '../rgba_porter_duff/LICENSE',
)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def durable(path, value, exclusive=False):
    with path.open('x' if exclusive else 'w', encoding='utf-8', newline='\n') as stream:
        json.dump(value, stream, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())


def raw_new(path, data):
    with path.open('xb') as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def outer_target():
    return dict(
        name='finite_runner', kind='SUPERVISED_RUNNER',
        argv=[sys.executable, '-I', '-B', str(ROOT / 'run_checks.py'),
              '--execute-approved-plan'],
        cwd=str(ROOT), hard_seconds=20, tree_kill_seconds=5, drain_seconds=2,
    )


def commands(stamp):
    work = ROOT / 'work' / stamp
    specs = []

    def add(name, kind, argv, **extra):
        specs.append(dict(
            name=name, kind=kind, argv=list(map(str, argv)), cwd=str(ROOT),
            hard_seconds=20, tree_kill_seconds=5, drain_seconds=2, **extra,
        ))

    iv = str(BIN / 'iverilog.exe')
    vvp = str(BIN / 'vvp.exe')
    add('prepare_vectors', 'PREPARATION',
        [sys.executable, '-I', '-B', ROOT / 'tools/prepare_vectors.py',
         '--output-dir', work / 'preparation_once'],
        project_reads=['tools/prepare_vectors.py', 'reference_model.py'])
    add('syntax_core', 'HDL',
        [iv, '-g2012', '-Wall', '-tnull', '-s', 'rgb_screen_matte',
         '-Prgb_screen_matte.TAG_W=1', '-f', 'files.f'], profile='core_minimum')
    add('syntax_over', 'HDL',
        [iv, '-g2012', '-Wall', '-tnull', '-s', 'screen_matte_over',
         '-Pscreen_matte_over.TAG_W=1', '-f', 'example/files.f'], profile='over_minimum')
    for label, top, filelist, tag in (
        ('core', 'tb_rgb_screen_matte', 'files.f', 32),
        ('over', 'tb_screen_matte_over', 'example/files.f', 28),
    ):
        image = work / (label + '.vvp')
        add('compile_' + label, 'HDL',
            [iv, '-g2012', '-Wall', '-I', 'sim', '-s', top,
             '-P' + top + '.TAG_W=' + str(tag), '-o', image,
             '-f', filelist, 'sim/' + top + '.sv'],
            profile=label, image=str(image))
        add('simulate_' + label, 'HDL',
            [vvp, image, '+VECTORS=' + (work / 'preparation_once/vectors.txt').as_posix()],
            profile=label, image=str(image),
            marker='MATTE_' + label.upper() + '_PASS ')
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


def validate_preparation(out, record):
    assert record['stderr']['bytes'] == 0
    prepared = out / 'preparation_once'
    assert {path.name for path in prepared.iterdir()} == {'vectors.txt', 'preparation.json'}
    vector = prepared / 'vectors.txt'
    metadata = prepared / 'preparation.json'
    for path in (vector, metadata):
        with path.open('ab', buffering=0) as stream:
            stream.flush()
            os.fsync(stream.fileno())
    summary = json.loads(metadata.read_bytes())
    assert set(summary) == {
        'status', 'rows', 'alpha_values', 'invalid_windows', 'exact_half_cases',
        'vectors_sha256', 'seed_cases', 'seed_metadata',
    }
    assert summary['status'] == 'PREPARATION_ONLY'
    assert summary['rows'] == EXPECTED_ROWS and summary['alpha_values'] == 256
    assert summary['invalid_windows'] > 0 and summary['exact_half_cases'] >= 4
    assert summary['seed_cases'] == '0xB50C2026' and summary['seed_metadata'] == '0x50C0FFEE'
    assert summary['vectors_sha256'] == digest(vector)
    lines = vector.read_text(encoding='ascii').splitlines()
    assert int(lines[0]) == EXPECTED_ROWS and len(lines) == EXPECTED_ROWS + 1
    tokens = [list(map(lambda value: int(value, 16), line.split())) for line in lines[1:]]
    widths = (24, 24, 19, 19, 8, 1, 16, 16, 32, 1, 1, 1, 32, 32, 1, 32, 32, 3)
    assert all(len(parts) == len(widths) for parts in tokens)
    assert all(0 <= value < (1 << width)
               for parts in tokens for value, width in zip(parts, widths))
    assert {parts[13] & 255 for parts in tokens} == set(range(256))
    assert sum(parts[14] for parts in tokens) == summary['invalid_windows']
    ties = 0
    for parts in tokens:
        rgb, key, inner, outer = parts[:4]
        r, g, b = rgb >> 16, (rgb >> 8) & 255, rgb & 255
        kr, kg, kb = key >> 16, (key >> 8) & 255, key & 255
        metric = ((b - g) - (kb - kg)) ** 2 + ((r - g) - (kr - kg)) ** 2
        if inner < metric < outer:
            ties += int(2 * ((255 * (metric - inner)) % (outer - inner)) == outer - inner)
    assert ties == summary['exact_half_cases']
    raw_lines = (out / record['stdout']['path']).read_text(encoding='utf-8').splitlines()
    assert raw_lines == [
        'MATTE_PREP_PASS rows=' + str(summary['rows'])
        + ' alpha_values=' + str(summary['alpha_values'])
        + ' invalid=' + str(summary['invalid_windows'])
        + ' ties=' + str(summary['exact_half_cases'])
    ]
    return dict(summary=summary, files=[
        dict(path=path.relative_to(out).as_posix(), sha256=digest(path), bytes=path.stat().st_size)
        for path in (vector, metadata)
    ])


def validate_simulation(spec, record, out, image_hash):
    assert record['execution_image_prechecked']
    assert record['execution_image_sha256'] == image_hash == digest(Path(spec['image']))
    initial = json.loads((out / (spec['name'] + '.initial.json')).read_bytes())
    assert initial['status'] == 'STARTING' and initial['pid'] is None
    assert initial['execution_image_prechecked'] and initial['execution_image_sha256'] == image_hash
    assert record['stderr']['bytes'] == 0
    raw = (out / record['stdout']['path']).read_text(encoding='utf-8')
    markers = [line for line in raw.splitlines() if line.startswith(spec['marker'])]
    assert len(markers) == 1 and '$finish called' in raw
    parts = markers[0][len(spec['marker']):].split()
    assert all(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*=\d+', part) for part in parts)
    counters = dict(part.split('=', 1) for part in parts)
    assert len(counters) == len(parts)
    counters = {key: int(value) for key, value in counters.items()}
    expected = dict(rows=EXPECTED_ROWS, live_reset_probes=5,
                    TAG_W=32 if spec['profile'] == 'core' else 28)
    if spec['profile'] == 'over':
        expected['unmatched_reset_probes'] = 2
    assert set(counters) == set(expected) | {'holds'} and counters['holds'] > 0
    assert all(counters[key] == value for key, value in expected.items())
    return dict(observed=counters, expected=expected)


def main():
    if os.name != 'nt' or sys.flags.optimize or not sys.flags.isolated or not sys.dont_write_bytecode:
        raise RuntimeError('Use the exact Windows Python -I -B invocation without optimization')
    assert sys.argv[1:] == ['--execute-approved-plan']
    assert Path(__file__).resolve() == REPO / 'cores/image_processing/rgb_screen_matte/run_checks.py'
    plan = json.loads(PLAN.read_bytes())
    seal = json.loads(SEAL.read_bytes())
    review = json.loads(REVIEW.read_bytes())
    assert plan['status'] == 'FROZEN' and not plan['pending_inputs']
    assert plan['schema'] == 'anscore-b50-matte-plan-v1' and plan['baseline'] == BASE
    assert review['verdict'] == 'NO_BLOCKER_ROOT_AND_PEER'
    assert review['root'] == review['peer'] == 'NO_BLOCKER' and review['peer_reviewer'] == 'worker_a'
    assert review['execution_gate'] == plan['execution_gate'] == GATE
    assert review['outer_supervised'] is True and review['outer_target'] == plan['outer_target'] == outer_target()
    assert review['plan_sha256'] == digest(PLAN) == seal['plan_sha256']
    assert review['seal_sha256'] == digest(SEAL) and review['runner_sha256'] == digest(Path(__file__))
    assert plan['automatic_retry'] is False and plan['children'] == commands('<stamp>')
    assert len(plan['children']) == 7 and plan['expected_rows_from_source'] == EXPECTED_ROWS
    assert plan['preparation_execution'] == 'PINNED_ORIGINAL_WITH_ARCHIVED_IDENTICAL_SOURCES'
    expected_names = {(ROOT / name).resolve().relative_to(REPO).as_posix() for name in SOURCES}
    assert set(plan['source_sha256']) == expected_names and len(expected_names) == 21
    assert plan['source_sha256'] == seal['source_sha256']
    assert plan['tools_sha256'] == seal['tools_sha256']
    required_tools = (Path(sys.executable), KILL_EXE, BIN / 'iverilog.exe', BIN / 'vvp.exe')
    assert all(tool in {Path(name) for name in plan['tools_sha256']} for tool in required_tools)

    def current_inputs():
        for name, value in plan['source_sha256'].items():
            assert digest(REPO / name) == value, name
        for name, value in plan['tools_sha256'].items():
            assert digest(Path(name)) == value, name

    current_inputs()
    assert not GUARD.exists() and not (ROOT / 'work').exists()
    pins = dict(plan=digest(PLAN), seal=digest(SEAL), review=digest(REVIEW))
    durable(GUARD, dict(status='ATTEMPT_STARTED', baseline=BASE, automatic_retry=False, **pins), True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out = ROOT / 'work' / stamp
    out.mkdir(parents=True, exist_ok=False)
    report = dict(
        schema='anscore-b50-matte-finite-v1', status='INCOMPLETE', baseline=BASE,
        children=[], child_records={}, initial_records={}, validated_records={},
        active_child=None, active_helpers=[], active_helper=None,
        source_sha256=plan['source_sha256'], tools_sha256=plan['tools_sha256'],
        archived_sources={}, preparation={}, images={}, execution_images={},
        archive_complete=False, suite_complete=False, automatic_retry=False,
        runner_oracle_imports=0, **pins,
    )

    def save():
        durable(out / 'results.json', report)

    def invariant():
        current_inputs()
        for key, path in (('plan', PLAN), ('seal', SEAL), ('review', REVIEW)):
            assert digest(path) == pins[key] == digest(out / (key + '.json'))
        assert set(report['archived_sources']) == set(plan['source_sha256'])
        for name, value in plan['source_sha256'].items():
            assert digest(ROOT / report['archived_sources'][name]) == value
        for name, value in report['images'].items():
            assert digest(ROOT / name) == value
        for domain in ('child_records', 'initial_records', 'validated_records'):
            for name, item in report[domain].items():
                path = out / name
                assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
        for record in report['children']:
            if record.get('process_evidence_saved'):
                for stream in ('stdout', 'stderr'):
                    item = record[stream]
                    path = out / item['path']
                    assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']
        for item in report['preparation'].get('files', []):
            path = out / item['path']
            assert digest(path) == item['sha256'] and path.stat().st_size == item['bytes']

    save()
    try:
        for key, path in (('plan', PLAN), ('seal', SEAL), ('review', REVIEW)):
            raw_new(out / (key + '.json'), path.read_bytes())
        for name, value in plan['source_sha256'].items():
            target = out / 'executed_inputs' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            raw_new(target, (REPO / name).read_bytes())
            assert digest(target) == value
            report['archived_sources'][name] = target.relative_to(ROOT).as_posix()
        report['archive_complete'] = True
        save()
        invariant()
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
        env['PATH'] = str(BIN) + os.pathsep + str(BIN.parent / 'lib') + os.pathsep + env.get('PATH', '')
        assert plan['environment'] == dict(
            inherit=True, PYTHONDONTWRITEBYTECODE='1', PATH_prefix=[str(BIN), str(BIN.parent / 'lib')],
            stdin='DEVNULL', creationflags='CREATE_NO_WINDOW',
        )
        for spec in commands(stamp):
            invariant()
            image_hash = None
            if spec['name'].startswith('simulate_'):
                image = Path(spec['image'])
                image_hash = digest(image)
                assert image_hash == report['images'][image.relative_to(ROOT).as_posix()]
                report['execution_images'][spec['name']] = dict(
                    path=image.relative_to(ROOT).as_posix(), sha256=image_hash)
                save()
            record = execute(spec, env, out, report, save)
            assert record['status'] == 'PASS' and record['process_exited'] and record['exit_code'] == 0
            assert record['output_capture_complete'] and record['process_evidence_saved'] and not record['cleanup']
            checked = dict(record)
            if spec['name'].startswith('compile_'):
                image = Path(spec['image'])
                assert image.is_file() and image.stat().st_size > 0
                with image.open('ab', buffering=0) as stream:
                    stream.flush()
                    os.fsync(stream.fileno())
                image_hash = digest(image)
                report['images'][image.relative_to(ROOT).as_posix()] = image_hash
                checked['compiled_image_sha256'] = image_hash
            elif spec['kind'] == 'PREPARATION':
                report['preparation'] = validate_preparation(out, record)
                checked['preparation_summary'] = report['preparation']['summary']
            elif spec['name'].startswith('simulate_'):
                checked.update(validate_simulation(spec, record, out, image_hash))
            checked['metadata_validated'] = True
            validation = out / (spec['name'] + '.validated.json')
            durable(validation, checked, True)
            report['validated_records'][validation.name] = dict(
                sha256=digest(validation), bytes=validation.stat().st_size)
            save()
            invariant()
            print(spec['name'] + ' PASS', flush=True)
        assert len(report['images']) == len(report['execution_images']) == 2
        assert len(report['children']) == len(report['initial_records']) == 7
        assert len(report['child_records']) == len(report['validated_records']) == 7
        assert report['preparation']['summary']['rows'] == EXPECTED_ROWS
        assert report['active_child'] is None and report['active_helper'] is None and not report['active_helpers']
        report.update(status='PASS', suite_complete=True, inputs_unchanged=True, exact_plan_executed=True)
    except BaseException:
        report.update(status='FAIL_STOP', suite_complete=False, exception=traceback.format_exc())
    finally:
        try:
            invariant()
            unchanged = True
        except BaseException:
            unchanged = False
        report['inputs_unchanged'] = unchanged
        report['exact_plan_executed'] = (
            [record['name'] for record in report['children']] == [spec['name'] for spec in commands(stamp)])
        if not unchanged:
            report.update(status='FAIL_STOP', suite_complete=False)
        save()
        print(json.dumps(dict(status=report['status'], receipt=(out / 'results.json').relative_to(REPO).as_posix())))
    return 0 if report['suite_complete'] and report['status'] == 'PASS' else 1


if __name__ == '__main__':
    raise SystemExit(main())
