"""One-shot sealed B25 evidence. All167 frozen compiler/simulator children <=20s."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
MATRIX_SHA = 'dd2d65612db8bac22f51a5d9a5e1786712acebea7c64a70ed03fc300e21c169b'
PLAN_SHA = '69e48886c45cb5c7e39cdc4e3626e861a929e6f487bfeb8d15d596292681e082'


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads((ROOT / path).read_text(encoding='utf-8'))


def write(path, value):
    (ROOT / path).write_text(json.dumps(value, indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='\n')


def source_map():
    return {p.relative_to(ROOT).as_posix(): digest(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and 'failure_archive' not in p.parts and p.name not in ('SOURCE_SEAL.json', 'verification.json')}


def inventory():
    paths = {p.relative_to(REPO).as_posix(): digest(p) for p in sorted(ROOT.rglob('*')) if p.is_file()}
    (REPO / '.git/anscore-b25-c-owned.json').write_text(json.dumps(
        dict(schema=1, owner='C', stage='IMPLEMENTATION_SEALED', files_sha256=paths), indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='\n')


def frozen():
    assert digest(ROOT / 'MATRIX.json') == MATRIX_SHA
    assert digest(ROOT / 'TEST_PLAN.json') == PLAN_SHA
    matrix, plan = read('MATRIX.json'), read('TEST_PLAN.json')
    assert plan['matrix_sha256'] == MATRIX_SHA
    assert matrix['timeout_seconds'] == plan['timeout_seconds'] == 20
    assert matrix['timeout_terminal'] and matrix['no_adaptation']
    assert len(plan['commands']) == len(set(c[0] for c in plan['commands'])) == 167
    assert [c[0] for c in plan['commands']] == matrix['children']
    assert len(matrix['jobs']) == 78
    for path, expected in plan['source_sha256'].items():
        assert digest(ROOT / path) == expected, 'frozen fixture source changed: ' + path
    assert len(plan['source_sha256']) == 162
    return matrix, plan


def seal():
    assert not (ROOT / 'SOURCE_SEAL.json').exists() and not (ROOT / 'verification.json').exists(), 'one-shot seal'
    matrix, plan = frozen()
    paths = source_map()
    for path in paths:
        raw = (ROOT / path).read_bytes()
        raw.decode('utf-8')
        assert b'\r' not in raw and not raw.startswith(b'\xef\xbb\xbf'), path
    assert all((ROOT / path).is_file() for path in matrix['deferred_hdl_files'])
    write('SOURCE_SEAL.json', dict(stage='ALL_IMPLEMENTATION_SOURCES_BEFORE_FIRST_HDL',
          baseline=matrix['baseline'], matrix_sha256=MATRIX_SHA, plan_sha256=PLAN_SHA,
          timeout_seconds=20, children=matrix['children'], source_sha256=paths,
          fixture_review_record='.git/anscore-b25-root-c-fixture-review.json',
          fixture_review_sha256=digest(REPO / '.git/anscore-b25-root-c-fixture-review.json'),
          no_hdl_executed_before_seal=True,
          approval='Root read-only source preflight and approval of this exact seal required before --run.'))
    inventory()
    print('SOURCE_SEALED', digest(ROOT / 'SOURCE_SEAL.json'), len(paths), 'sources; no HDL executed')


def expected_job(job):
    blocks = read(job['certificate'])['blocks']
    completed = [b for b in blocks if b['reset_target'] is None]
    owners = [b for b in blocks if b['reset_target'] is not None]
    expected = dict(W=job['w'], H=job['h'], C=job['c'], T=job['t'],
                    frames=len(completed) if not owners else 0, fresh=len(owners), resets=len(owners),
                    queued=job['queued_main_transitions'], latencies=len(completed),
                    bytes=sum(b['public_bytes'] for b in completed),
                    ownerbytes=sum(b['reset_target']['retired_bytes'] for b in owners),
                    capturewrites=job['w'] * job['h'] * len(completed) + sum(b['reset_target']['capture_limit'] for b in owners),
                    reads=sum(b['work']['raw_reads'] for b in completed) + sum(b['reset_target']['raw_reads'] for b in owners),
                    hreads=sum(b['work']['history_reads'] for b in completed) + sum(b['reset_target']['history_reads'] for b in owners),
                    hwrites=sum(b['work']['history_writes'] for b in completed) + sum(b['reset_target']['history_writes'] for b in owners),
                    outputholds=sum(b['output_holds'] * (b['public_bytes'] + 1) for b in completed) + sum(b['reset_target']['held_cycles'] for b in owners),
                    max_tail=max(b['work']['tail'] for b in completed),
                    resetmask=sum(1 << b['reset_id'] for b in owners))
    codes = dict(INDEX=0, DIFF=1, LUMA=2, RUN=3, RGB=4, RGBA=5)
    opcode_mask = 0
    for b in completed:
        for kind in b['work']['opcodes']:
            opcode_mask |= 1 << codes[kind]
    return expected, owners, opcode_mask


def marker(record, job):
    lines = [x for x in record['stdout'].splitlines() if x.startswith('PASS ')]
    assert len(lines) == 1, 'one exact PASS marker required'
    got = {k: int(v, 16 if k in ('states', 'opcodes', 'resetmask') else 10)
           for k, v in re.findall(r'(\w+)=([0-9a-f]+)', lines[0])}
    expected, owners, opcode_mask = expected_job(job)
    for key, value in expected.items():
        assert got.get(key) == value, (job['name'], key, got.get(key), value)
    assert got['cycles'] <= job['cycle_limit'] and got['opcodes'] & opcode_mask == opcode_mask
    if got['queued']:
        assert got['sourceholds'] > 0
    observations = [x for x in record['stdout'].splitlines() if x.startswith('OBS ')]
    assert len(observations) == len(owners)
    for line, block in zip(observations, owners):
        obs = {k: int(v) for k, v in re.findall(r'(\w+)=(-?\d+)', line)}
        t = block['reset_target']
        assert obs == dict(id=block['reset_id'], state=t['state'], capture=t['capture_limit'],
                           prefix=t['retired_bytes'], reads=t['raw_reads'], hreads=t['history_reads'],
                           hwrites=t['history_writes'], held=t['held_cycles'],
                           trace=-1 if t['trace_index'] is None else t['trace_index']), obs
    return got


def verify_seal():
    matrix, plan = frozen()
    sealed = read('SOURCE_SEAL.json')
    assert sealed['source_sha256'] == source_map(), 'sealed source mismatch'
    assert sealed['matrix_sha256'] == MATRIX_SHA and sealed['plan_sha256'] == PLAN_SHA
    assert sealed['children'] == matrix['children'] and sealed['timeout_seconds'] == 20
    return matrix, plan, sealed


def archive(receipt):
    target = ROOT / 'failure_archive/attempt_01'
    assert not target.exists(), 'never overwrite original evidence'
    # Snapshot paths before creating the archive, so it cannot copy itself.
    originals = [p for p in sorted(ROOT.rglob('*')) if p.is_file() and 'failure_archive' not in p.parts]
    target.mkdir(parents=True)
    for path in originals:
        dest = target / path.relative_to(ROOT)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(path.read_bytes())
    (target / 'receipt.json').write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n', encoding='utf-8', newline='\n')
    (target / 'NOT_RUN.json').write_text(json.dumps(receipt['not_run'], indent=2) + '\n', encoding='utf-8', newline='\n')
    inventory()


def child(argv, env):
    flags = subprocess.CREATE_NO_WINDOW | subprocess.CREATE_NEW_PROCESS_GROUP if os.name == 'nt' else 0
    process = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               creationflags=flags, start_new_session=os.name != 'nt')
    try:
        stdout, stderr = process.communicate(timeout=20)
        return process.returncode, stdout.decode('utf-8', 'replace'), stderr.decode('utf-8', 'replace'), False, ''
    except subprocess.TimeoutExpired as original:
        termination = ''
        try:
            if os.name == 'nt':
                cleanup = subprocess.run(['taskkill', '/PID', str(process.pid), '/T', '/F'], capture_output=True, timeout=5)
                termination = cleanup.stdout.decode('utf-8', 'replace') + cleanup.stderr.decode('utf-8', 'replace')
            else:
                os.killpg(process.pid, signal.SIGKILL)
                termination = 'SIGKILL process group'
        except Exception as error:
            termination = 'tree cancellation diagnostic: ' + str(error)
            process.kill()
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            stdout, stderr = original.stdout or b'', original.stderr or b''
            termination += '; post-cancellation collection deadline'
        return None, stdout.decode('utf-8', 'replace'), stderr.decode('utf-8', 'replace'), True, termination


def run(authorized_seal):
    matrix, plan, sealed = verify_seal()
    seal_sha = digest(ROOT / 'SOURCE_SEAL.json')
    assert authorized_seal == seal_sha, 'pass the exact root-approved source seal hash'
    assert not (ROOT / 'verification.json').exists(), 'existing receipt prohibits every automatic rerun'
    tool = REPO / 'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe'
    compiler = str(tool) if tool.is_file() else shutil.which('iverilog')
    vvp = str(tool.with_name('vvp.exe')) if tool.is_file() else shutil.which('vvp')
    assert compiler and vvp, 'missing compiler/simulator; no children executed'
    env = os.environ.copy()
    binary = Path(compiler).parent
    env['PATH'] = str(binary) + os.pathsep + str(binary.parent / 'lib') + os.pathsep + env.get('PATH', '')
    receipt = dict(status='RUNNING', baseline=matrix['baseline'], hardware='HW_UNVERIFIED',
                   matrix_sha256=MATRIX_SHA, plan_sha256=PLAN_SHA, seal_sha256=seal_sha,
                   source_sha256=sealed['source_sha256'], records=[], jobs=[],
                   terminal_timeout=False, not_run=matrix['children'].copy())
    write('verification.json', receipt)
    with tempfile.TemporaryDirectory(prefix='anscore_b25_qoi_') as temporary:
        substitutions = {'@IVERILOG@': compiler, '@VVP@': vvp, '@TEMP@': temporary}
        receipt['substitutions'] = substitutions
        receipt['tools'] = {name: dict(path=path, sha256=digest(Path(path))) for name, path in (('compiler', compiler), ('vvp', vvp))}
        for name, template, negative in plan['commands']:
            argv = []
            for token in template:
                for key, value in substitutions.items():
                    token = token.replace(key, value)
                argv.append(token)
            record = dict(name=name, argv=argv, timeout_seconds=20)
            start = time.monotonic()
            try:
                code, stdout, stderr, timeout, termination = child(argv, env)
                record.update(exit_code=code, stdout=stdout, stderr=stderr,
                              elapsed_seconds=round(time.monotonic() - start, 3))
                if timeout or record['elapsed_seconds'] >= 20:
                    record.update(status='TIMEOUT', termination=termination)
                    receipt['terminal_timeout'] = True
                else:
                    okay = (code != 0 and 'qoi_encoder_invalid_configuration' in stderr) if negative else code == 0
                    if name != 'version' and not negative:
                        okay = okay and stderr == ''
                    record['status'] = 'PASS' if okay else 'FAIL'
                    if okay and name.endswith('_simulate'):
                        job = next(j for j in matrix['jobs'] if name == j['name'] + '_simulate')
                        receipt['jobs'].append(dict(job, observed=marker(record, job)))
            except Exception as error:
                record.update(status='FAIL', exception=str(error), elapsed_seconds=round(time.monotonic() - start, 3))
            receipt['records'].append(record)
            receipt['not_run'].remove(name)
            print(name, record['status'], record['elapsed_seconds'], flush=True)
            if record['status'] != 'PASS':
                receipt['status'] = record['status']
                write('verification.json', receipt)
                archive(receipt)
                raise SystemExit('terminal failure: complete sources/receipt/NOT_RUN archived; root precise repair scope required')
        receipt['status'] = 'UNIT_SIM_PASS'
        keys = ('frames', 'fresh', 'resets', 'queued', 'latencies', 'bytes', 'ownerbytes',
                'capturewrites', 'reads', 'hreads', 'hwrites', 'sourceholds', 'outputholds')
        receipt['totals'] = {k: sum(j['observed'][k] for j in receipt['jobs']) for k in keys}
        write('verification.json', receipt)
    inventory()
    audit()


def audit():
    matrix, plan, sealed = verify_seal()
    receipt = read('verification.json')
    assert receipt['status'] == 'UNIT_SIM_PASS' and not receipt['terminal_timeout'] and not receipt['not_run']
    assert receipt['source_sha256'] == sealed['source_sha256']
    assert receipt['seal_sha256'] == digest(ROOT / 'SOURCE_SEAL.json')
    assert receipt['matrix_sha256'] == MATRIX_SHA and receipt['plan_sha256'] == PLAN_SHA
    assert [r['name'] for r in receipt['records']] == matrix['children']
    for record, (_, template, negative) in zip(receipt['records'], plan['commands']):
        argv = []
        for token in template:
            for key, value in receipt['substitutions'].items():
                token = token.replace(key, value)
            argv.append(token)
        assert record['argv'] == argv
        assert record['status'] == 'PASS' and record['timeout_seconds'] == 20 and record['elapsed_seconds'] < 20
        assert (record['exit_code'] != 0) == negative
        if record['name'] != 'version' and not negative:
            assert record['stderr'] == ''
    for job in matrix['jobs']:
        record = next(r for r in receipt['records'] if r['name'] == job['name'] + '_simulate')
        assert marker(record, job) == next(j['observed'] for j in receipt['jobs'] if j['name'] == job['name'])
    for profile in matrix['profiles']:
        observations = [j['observed'] for j in receipt['jobs'] if
                        (j['w'], j['h'], j['c'], j['t']) == tuple(profile[k] for k in ('w', 'h', 'c', 't'))]
        states = resets = 0
        for observed in observations:
            states |= observed['states']
            resets |= observed['resetmask']
        assert states == 8191 and resets == sum(1 << i for i in profile['reset_ids'])
    print('OFFLINE_AUDIT_PASS', len(receipt['records']), 'children', len(sealed['source_sha256']), 'sealed sources')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--seal', action='store_true')
    group.add_argument('--run', action='store_true')
    group.add_argument('--audit', action='store_true')
    parser.add_argument('--authorized-seal')
    args = parser.parse_args()
    if args.authorized_seal and not args.run:
        parser.error('--authorized-seal is only valid with --run')
    if args.seal:
        seal()
    elif args.run:
        run(args.authorized_seal)
    else:
        audit()
