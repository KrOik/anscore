"""Frozen finite attempt; 20 s process-tree deadlines, first failure stops, no retry.

--seal and --execute are separate approval stages. No numerical oracle is imported.
"""
from pathlib import Path
import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SEAL = ROOT/'SOURCE_FREEZE.json'
REPORT = ROOT/'verification.json'
LOGS = ROOT/'reports'
ARTIFACTS = ROOT/'artifacts'
RUNTIME = {'reports', 'artifacts', 'failure_archive'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p not in (SEAL, REPORT) and p.relative_to(ROOT).parts[0] not in RUNTIME}


def check_preparation():
    plan, prepared, preparation = read(ROOT/'TEST_PLAN.json'), read(ROOT/'PREPARED.json'), read(ROOT/'PREPARATION_PLAN.json')
    assert len(plan['children']) == 23 and plan['totals']['main_frames'] == 100
    assert prepared['preparation_plan_sha256'] == sha(ROOT/'PREPARATION_PLAN.json')
    assert prepared['test_plan_sha256'] == sha(ROOT/'TEST_PLAN.json') and prepared['hdl_executed'] == 0
    assert prepared['totals'] == plan['totals']
    assert all(sha(ROOT/p) == digest for p, digest in preparation['source_sha256'].items())
    expected = {}
    for p in prepared['profiles']:
        expected.update(p['files_sha256'])
    actual = {p.relative_to(ROOT).as_posix(): sha(p) for p in (ROOT/'fixtures').iterdir() if p.is_file()}
    assert actual == expected, 'preparation fixtures changed or expanded'


def freeze():
    assert not any(p.exists() for p in [SEAL, REPORT, LOGS, ARTIFACTS]), 'never replace a seal or attempt'
    check_preparation()
    plan = read(ROOT/'TEST_PLAN.json')
    tools = {c['argv'][0] for c in plan['children']}
    suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    tools.update(str(suite/p) for p in ['lib/ivl/ivl.exe', 'lib/ivl/ivlpp.exe', 'lib/ivl/vvp.tgt',
                                       'lib/ivl/vvp.conf', 'lib/ivl/system.vpi', 'lib/ivl/v2009.vpi'])
    tools.add(sys.executable)
    write(SEAL, dict(schema=1, baseline=plan['baseline'], test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),
                     prepared_sha256=sha(ROOT/'PREPARED.json'), files_sha256=sources(),
                     tools_sha256={p: sha(Path(p)) for p in sorted(tools)},
                     frozen_before_any_hdl=True, timeout_seconds=20, attempt=1))
    print('SEALED', sha(SEAL), flush=True)


def check():
    seal = read(SEAL)
    assert sources() == seal['files_sha256'], 'source set/hash changed'
    assert sha(ROOT/'TEST_PLAN.json') == seal['test_plan_sha256']
    assert sha(ROOT/'PREPARED.json') == seal['prepared_sha256']
    assert all(sha(Path(p)) == digest for p, digest in seal['tools_sha256'].items()), 'tool changed'
    if REPORT.exists():
        report, plan = read(REPORT), read(ROOT/'TEST_PLAN.json')
        assert report['status'] == 'UNIT_SIM_PASS' and not report['not_run'] and not report['terminal_timeout']
        assert report['source_freeze_sha256'] == sha(SEAL)
        assert report['source_sha256'] == dict(seal['files_sha256'], **{SEAL.name: sha(SEAL)})
        assert report['test_plan_sha256'] == sha(ROOT/'TEST_PLAN.json')
        assert report['baseline'] == plan['baseline'] and report['hardware'] == 'HW_UNVERIFIED'
        assert report['totals'] == plan['totals'] and report['attempt'] == 1
        assert report['timeout_seconds'] == 20 and report['integrity_error'] is None
        assert len(report['records']) == len(plan['children'])
        assert report['max_child_seconds'] == max(r['elapsed_seconds'] for r in report['records'])
        logs = set();actual_results = []
        for number, (record, command) in enumerate(zip(report['records'], plan['children'], strict=True)):
            assert record['status'] == command['expected']
            assert record['name'] == command['name'] and record['argv'] == command['argv']
            assert record['expected'] == command['expected'] and record['timeout_seconds'] == 20
            assert not record['timed_out'] and 0 <= record['elapsed_seconds'] < 20 and record['launch_error'] is None
            assert record['supervision']['contained_before_resume'] is True
            for stream in ['stdout', 'stderr']:
                path = record[stream+'_file'];logs.add(path)
                assert path == (LOGS/f"{number:03d}_{command['name']}.{stream}").relative_to(ROOT).as_posix()
                assert sha(ROOT/path) == record[stream+'_sha256']
            raw_out = (ROOT/record['stdout_file']).read_bytes()
            raw_err = (ROOT/record['stderr_file']).read_bytes()
            if command['expected'] == 'EXPECTED_REJECT':
                assert record['exit_code'] > 0 and command['marker'].encode() in raw_out+raw_err
            else:
                assert record['exit_code'] == 0
                assert not raw_err
                if command['kind'] != 'simulation':assert not raw_out
            result = validate(command, raw_out.decode('utf-8'))
            if result is not None:actual_results.append(result)
        assert logs == {p.relative_to(ROOT).as_posix() for p in LOGS.iterdir() if p.is_file()}
        assert actual_results == report['results']
    print('PASS read-only integrity; no oracle or HDL invocation', flush=True)


class WindowsJob:
    """Place a suspended child in a kill-on-close Job before any compiler code runs."""
    def __init__(self):
        from ctypes import wintypes as wt
        class Basic(ctypes.Structure):
            _fields_ = [('process_time', ctypes.c_int64), ('job_time', ctypes.c_int64),
                        ('flags', wt.DWORD), ('min_working_set', ctypes.c_size_t),
                        ('max_working_set', ctypes.c_size_t), ('active_limit', wt.DWORD),
                        ('affinity', ctypes.c_size_t), ('priority', wt.DWORD), ('scheduling', wt.DWORD)]
        class Io(ctypes.Structure):
            _fields_ = [(p, ctypes.c_uint64) for p in ['read_ops', 'write_ops', 'other_ops', 'read_bytes', 'write_bytes', 'other_bytes']]
        class Extended(ctypes.Structure):
            _fields_ = [('basic', Basic), ('io', Io), ('process_memory', ctypes.c_size_t),
                        ('job_memory', ctypes.c_size_t), ('peak_process', ctypes.c_size_t), ('peak_job', ctypes.c_size_t)]
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wt.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = wt.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [wt.HANDLE, ctypes.c_int, ctypes.c_void_p, wt.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [wt.HANDLE, wt.HANDLE]
        self.kernel.TerminateJobObject.argtypes = [wt.HANDLE, wt.UINT]
        self.kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        if not self.handle:
            raise ctypes.WinError(ctypes.get_last_error())
        limits = Extended();limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if not self.kernel.SetInformationJobObject(self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits)):
            error = ctypes.WinError(ctypes.get_last_error());self.close();raise error

    def assign_and_resume(self, child, deadline):
        if not self.kernel.AssignProcessToJobObject(self.handle, int(child._handle)):
            raise ctypes.WinError(ctypes.get_last_error())
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(child.args, 20)
        # Popen closes the primary thread handle. Resume the assigned suspended process
        # through the native system call; no external helper or uncontained child runs.
        native = ctypes.WinDLL('ntdll')
        native.NtResumeProcess.argtypes = [ctypes.c_void_p]
        native.NtResumeProcess.restype = ctypes.c_long
        status = native.NtResumeProcess(int(child._handle))
        if status != 0:
            raise OSError(f'NtResumeProcess status 0x{status & 0xffffffff:08x}')

    def terminate(self):
        return bool(self.kernel.TerminateJobObject(self.handle, 1))

    def close(self):
        if self.handle:
            self.kernel.CloseHandle(self.handle);self.handle = None


def run_child(command, env):
    start = time.monotonic();deadline = start+20.0
    job = None;child = None;raw_out = raw_err = b'';cleanup = {};timed_out = False;error = None
    try:
        kwargs = dict(cwd=command['cwd'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if os.name == 'nt':
            job = WindowsJob()
            kwargs['creationflags'] = 0x4 | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
        else:
            kwargs['start_new_session'] = True
        child = subprocess.Popen(command['argv'], **kwargs)
        cleanup['pid'] = child.pid
        if job:
            job.assign_and_resume(child, deadline);cleanup['contained_before_resume'] = True
        try:
            remaining = deadline-time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command['argv'], 20)
            raw_out, raw_err = child.communicate(timeout=remaining)
        except subprocess.TimeoutExpired as exc:
            timed_out = True;raw_out = exc.stdout or b'';raw_err = exc.stderr or b''
            cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
            if job:
                cleanup['terminate_job_sent'] = job.terminate();job.close()
            else:
                os.killpg(child.pid, signal.SIGKILL);cleanup['killpg_sent'] = True
            # Only drain already terminated processes; no extension of execution time.
            try:
                raw_out, raw_err = child.communicate(timeout=0.5)
            except subprocess.TimeoutExpired as drain:
                raw_out = drain.stdout or raw_out;raw_err = drain.stderr or raw_err
                cleanup['drain_incomplete'] = True
    except subprocess.TimeoutExpired as exc:
        timed_out = True;error = type(exc).__name__+': '+str(exc)
        cleanup['deadline_reached_seconds'] = round(time.monotonic()-start, 6)
    except Exception as exc:
        error = type(exc).__name__+': '+str(exc)
    finally:
        if job:
            job.close()  # Also kills descendants left after a normal parent exit.
        if child is not None and child.poll() is None:
            try:
                if os.name != 'nt': os.killpg(child.pid, signal.SIGKILL)
                child.kill()
                raw_out, raw_err = child.communicate(timeout=0.5)
            except Exception as exc:
                cleanup['fallback_error'] = type(exc).__name__+': '+str(exc)
    return dict(exit_code=None if child is None else child.returncode,
                elapsed_seconds=round(time.monotonic()-start, 6), timed_out=timed_out,
                supervision=cleanup, launch_error=error), raw_out, raw_err



REC = re.compile(r'REC id=(\d+) phase=(\d+) index=(\d+) numerator=([0-9a-f]+) denominator=(\d+) tag=([0-9a-f]+) last=(\d+)')
FRAME = re.compile(r'FRAME id=(\d+) phase=(\d+) count=(\d+)')
PROBE = re.compile(r'PROBE id=(\d+) mask=(\d+) state=(\d+) index=(\d+) prefix=(\d+) k=(\d+) round=(\d+) kept=(\d+) acc=(-?\d+) threshold=(-?\d+) active=([0-9a-f]+) read=(-?\d+) product=(-?\d+) offer=(\d+)')
SUMMARY_KEYS = 'mode N DATA_W TAG_W frame_begins samples completed canceled outputs prefix fresh resets next reset_offers source_holds output_holds input_gaps'.split()
SUMMARY = re.compile('PASS '+' '.join(key+r'=(\d+)' for key in SUMMARY_KEYS))


def rows(pattern, prefix, output, hex_fields=()):
    result = []
    for line in output.splitlines():
        if line.startswith(prefix):
            match = pattern.fullmatch(line)
            assert match, ('malformed raw record', line)
            result.append([int(v, 16 if i in hex_fields else 10) for i, v in enumerate(match.groups())])
    return result


def validate(command, output):
    if command['kind'] != 'simulation':
        return None
    fixture = read(ROOT/f"fixtures/{command['profile']}.json")
    n, mode = fixture['n'], command['mode']
    finish = re.escape(str(ROOT/'sim/tb.sv'))+r':\d+: \$finish called at \d+ \(1ps\)'
    finish_count = 0
    for line in output.splitlines():
        if line.startswith('REC '):assert REC.fullmatch(line), ('unexpected raw line', line)
        elif line.startswith('FRAME '):assert FRAME.fullmatch(line), ('unexpected raw line', line)
        elif line.startswith('PROBE '):assert PROBE.fullmatch(line), ('unexpected raw line', line)
        elif line.startswith('PASS mode='):assert SUMMARY.fullmatch(line), ('malformed raw summary', line)
        else:
            assert re.fullmatch(finish, line), ('unexpected raw line', line)
            finish_count += 1
    assert finish_count == 1, 'normal simulator finish required exactly once'
    summaries = [line for line in output.splitlines() if line.startswith('PASS mode=')]
    assert len(summaries) == 1, 'missing/duplicate final summary'
    match = SUMMARY.fullmatch(summaries[0]);assert match
    values = dict(zip(SUMMARY_KEYS,map(int,match.groups()),strict=True))
    assert (values['mode'], values['N'], values['DATA_W'], values['TAG_W']) == (mode, n, fixture['data_w'], fixture['tag_w'])
    expected, frames = [], []
    def append(c, identifier, phase, count):
        for index, num in enumerate(c['numerators'][:count]):
            expected.append([identifier, phase, index, num, c['denominator'], c['tag'], int(index == n-1)])
    gaps = (n+1)//3
    if mode < 2:
        cases = fixture['cases'];count = len(cases)
        for identifier, c in enumerate(cases):
            append(c, identifier, 0, n);frames.append([identifier, 0, n])
        assert values['frame_begins'] == values['completed'] == count and values['canceled'] == 0
        assert values['samples'] == values['outputs'] == count*n
        assert all(values[k] == 0 for k in ['prefix', 'fresh', 'resets', 'next', 'reset_offers'])
        assert values['source_holds'] > 0
        assert values['output_holds'] == (0 if mode == 0 else 3*len(expected))
        assert values['input_gaps'] == count*gaps
        assert rows(PROBE, 'PROBE ', output, (10,)) == []
    else:
        probes = fixture['probes'];count = len(probes)
        expected_probes = []
        for p in probes:
            e = p['predicate'];mask = e['mask']
            append(p['owner'], p['id'], 1, e['prefix'])
            append(p['fresh'], p['id'], 2, n);frames.append([p['id'], 2, n])
            expected_probes.append([p['id'], mask, e['state'], e['index'], e['prefix'],
                e.get('k', 0) if mask&1 else 0, e.get('round', 0) if mask&1 else 0,
                e.get('kept', 0) if mask&1 else 0, e.get('acc', 0) if mask&17 else 0,
                e.get('threshold', 0) if mask&1 else 0, e.get('active', 0) if mask&1 else 0,
                e.get('read', 0) if mask&2 else 0, e.get('product', 0) if mask&4 else 0,
                int(p['actual_next_offer'])])
        assert rows(PROBE, 'PROBE ', output, (10,)) == expected_probes, 'actual reset predicates differ from sealed live-state witnesses'
        prefix = sum(p['predicate']['prefix'] for p in probes)
        partial = sum(p['id'] == 0 for p in probes)
        held = sum(p['predicate']['state'] == 9 for p in probes)
        assert values['frame_begins'] == 2*count
        assert values['completed'] == values['canceled'] == values['resets'] == count
        assert values['samples'] == 2*count*n-partial*(n-1)
        assert values['outputs'] == prefix+count*n and values['prefix'] == prefix and values['fresh'] == count*n
        assert values['reset_offers'] == 3*count and values['next'] == 1 and values['source_holds'] >= 3
        assert values['output_holds'] >= 3*(prefix+count*n+held)
        assert values['input_gaps'] == (2*count-partial)*gaps
    assert rows(REC, 'REC ', output, (3, 5)) == expected, 'raw retired outputs differ from sorted-prefix/KKT certificates'
    assert rows(FRAME, 'FRAME ', output) == frames, 'missing/extra completed frame'
    return dict(profile=command['profile'], mode=mode, observed=values)


def archive_failure(report):
    archive = ROOT/'failure_archive/attempt_01'
    assert not archive.exists(), 'never replace failure history'
    for relative in [*report['source_sha256'], REPORT.name]:
        dest = archive/'sources'/relative;dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT/relative, dest)
    for source, category in [(LOGS, 'logs'), (ARTIFACTS, 'artifacts')]:
        for p in source.rglob('*'):
            if p.is_file():
                dest = archive/category/p.relative_to(source);dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(p, dest)
    write(archive/'ARCHIVE.json', dict(status=report['status'], original_receipt_sha256=sha(REPORT),
         files_sha256={p.relative_to(archive).as_posix(): sha(p) for p in sorted(archive.rglob('*')) if p.is_file()},
         no_automatic_retry=True))


def execute(approved):
    check()
    assert approved == sha(SEAL), 'exact separately root-approved source seal required'
    assert not any(p.exists() for p in [REPORT, LOGS, ARTIFACTS, ROOT/'failure_archive']), 'one finite attempt; never overwrite evidence'
    plan = read(ROOT/'TEST_PLAN.json');LOGS.mkdir();ARTIFACTS.mkdir()
    env = os.environ.copy();suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'), str(suite/'lib'), env.get('PATH', '')])
    records, results = [], []
    stopped = terminal_timeout = False
    for number, command in enumerate(plan['children']):
        record = dict(name=command['name'], argv=command['argv'], expected=command['expected'], timeout_seconds=20)
        if stopped:
            records.append(dict(record, status='NOT_RUN', exit_code=None, elapsed_seconds=0));continue
        metadata, raw_out, raw_err = run_child(command, env);record.update(metadata)
        out, err = raw_out.decode('utf-8', errors='replace'), raw_err.decode('utf-8', errors='replace')
        try:
            if metadata['timed_out']:
                terminal_timeout = True;raise TimeoutError('terminal 20 s process-tree deadline')
            assert metadata['launch_error'] is None, metadata['launch_error']
            if command['expected'] == 'EXPECTED_REJECT':
                assert record['exit_code'] is not None and record['exit_code'] > 0
                assert command['marker'] in out+err, 'missing named elaboration rejection'
            else:
                assert record['exit_code'] == 0, 'unexpected child failure'
                assert not raw_err, 'unexpected successful-child stderr'
                if command['kind'] != 'simulation':assert not raw_out, 'unexpected compiler stdout'
            result = validate(command, out)
            if result is not None:results.append(result)
            record['status'] = command['expected']
        except Exception as exc:
            stopped = True;record['status'] = 'TIMEOUT' if metadata['timed_out'] else 'FAIL'
            record['error'] = type(exc).__name__+': '+str(exc)
        for stream, raw in [('stdout', raw_out), ('stderr', raw_err)]:
            path = LOGS/f"{number:03d}_{command['name']}.{stream}";path.write_bytes(raw)
            record[stream+'_file'] = path.relative_to(ROOT).as_posix();record[stream+'_sha256'] = sha(path)
        records.append(record);print(command['name'], record['status'], record['elapsed_seconds'], flush=True)
    current, sealed = sources(), read(SEAL)['files_sha256']
    integrity_error = None if current == sealed else 'sealed source set/hash changed during execution'
    if integrity_error:stopped = True
    report = dict(status='TIMEOUT_TERMINAL' if terminal_timeout else 'FAIL_STOPPED' if stopped else 'UNIT_SIM_PASS',
        hardware='HW_UNVERIFIED', baseline=plan['baseline'], source_freeze_sha256=sha(SEAL),
        source_sha256=dict(sealed, **{SEAL.name: sha(SEAL)}), test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),
        attempt=1, timeout_seconds=20, terminal_timeout=terminal_timeout, integrity_error=integrity_error,
        records=records, results=results, totals=plan['totals'],
        max_child_seconds=max(r['elapsed_seconds'] for r in records),
        not_run=[r['name'] for r in records if r['status'] == 'NOT_RUN'])
    write(REPORT, report)
    if stopped:archive_failure(report)
    print(report['status'], sha(REPORT), flush=True)
    if stopped:raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--seal', action='store_true')
    action.add_argument('--check', action='store_true')
    action.add_argument('--execute', action='store_true')
    parser.add_argument('--approved-seal')
    args = parser.parse_args()
    if args.seal:freeze()
    elif args.check:check()
    else:execute(args.approved_seal)
