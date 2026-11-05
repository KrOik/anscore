"""Execute the single frozen finite matrix once; hash-only audit thereafter."""
import argparse
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
SEAL = ROOT/'SOURCE_SEAL.json'
RECEIPT = ROOT/'verification.json'
EXCLUDED = {'SOURCE_SEAL.json', 'verification.json'}


def digest(raw):
    return sha256(raw).hexdigest()


def read(name):
    return json.loads((ROOT/name).read_bytes())


def write(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix():digest(p.read_bytes())
            for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.relative_to(ROOT).parts[0] not in ('artifacts', 'reports')
            and p.name not in EXCLUDED}


def fixture_checks():
    plan = read('TEST_PLAN.json')
    assert digest((ROOT/'prepare.py').read_bytes()) == plan['preparation_sha256']
    assert read('fixture_audit.json')['status'] == 'PASS'
    assert read('fixture_audit.json')['plan_sha256'] == digest((ROOT/'TEST_PLAN.json').read_bytes())
    assert all(c['timeout_seconds'] == 20 for c in plan['commands'])
    for p in plan['profiles']:
        for job in p['main']+p['resets']:
            for kind in ('json', 'text'):
                assert digest((ROOT/job[kind]).read_bytes()) == job[kind+'_sha256']
    return plan


def freeze():
    assert not SEAL.exists() and not RECEIPT.exists(), 'already sealed/executed'
    plan = fixture_checks()
    mapping = sources()
    assert all(b'\r' not in (ROOT/name).read_bytes() and not (ROOT/name).read_bytes().startswith(b'\xef\xbb\xbf')
               for name in mapping), 'LF/UTF-8 without BOM required'
    tool_bin = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'
    tools = {name:dict(path=str(tool_bin/(name+'.exe')),
                      sha256=digest((tool_bin/(name+'.exe')).read_bytes()))
             for name in ('iverilog', 'vvp')}
    write(SEAL, dict(schema=1, baseline=plan['baseline'], files_sha256=mapping,
         files_map_sha256=digest(json.dumps(mapping, sort_keys=True, separators=(',', ':')).encode()),
         test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()), tools=tools,
         argv_substitution='argv[0]=sealed executable absolute path; {TMP}=absolute own artifacts directory',
         children=len(plan['commands']), HDL_calls_before_seal=0))
    print(json.dumps(dict(status='SEALED', files=len(mapping), seal_sha256=digest(SEAL.read_bytes()))))


def expected_items(job):
    data = read(job['json'])
    if data['kind'] == 'main': return data['items'], []
    return [item for unit in data['units'] for sequence in (unit['setup'], unit['fresh']) for item in sequence], data['units']


def parse_summary(command, stdout):
    plan = read('TEST_PLAN.json')
    jobs = {j['name']:(p, j) for p in plan['profiles'] for j in p['main']+p['resets']}
    if command['name'] not in jobs: return None
    p, job = jobs[command['name']]
    items, reset_units = expected_items(job)
    lines = stdout.decode('utf-8', errors='strict').splitlines()
    summaries = [json.loads(line[5:]) for line in lines if line.startswith('PASS ')]
    assert len(summaries) == 1, 'one exact PASS summary'
    result = summaries[0]
    assert result['mode'] == int(bool(reset_units))
    assert result['completed'] == result['first_checks'] == len(items)
    assert result['cancelled'] == result['reset_checks'] == len(reset_units)
    assert result['accepted'] == len(items)+sum(u['id'] != 0 for u in reset_units)
    assert result['physical_rows'] == sum(len(item['after']) for item in items)
    assert result['held'] >= 3*len(items) and result['blocked'] > 0
    assert result['max_latency'] <= p['first_valid_bound']
    rows = [line.split()[1:] for line in lines if line.startswith('R ')]
    assert len(rows) == len(items), 'exact retired records'
    for row, item in zip(rows, items):
        assert len(row) >= 12
        expected = item['expected']
        keys = ('op', 'tag', 'status', 'live_count', 'found', 'matches', 'match_count',
                'slot', 'pattern', 'care', 'action')
        actual = {name:int(row[i], 16 if i in (1, 5, 8, 9, 10) else 10) for i, name in enumerate(keys)}
        assert actual == expected, ('actual response', command['name'], item['command'])
        count = int(row[11]); assert count == len(item['after']) and len(row) == 12+2*count
        after = []
        for i in range(count):
            slot, packed = int(row[12+2*i]), int(row[13+2*i], 16)
            action = packed % 2**p['D']; packed //= 2**p['D']
            care = packed % 2**p['K']; pattern = packed // 2**p['K']
            after.append([slot, pattern, care, action])
        assert after == item['after'], ('actual physical image', command['name'])
    observations = [line.split()[1:] for line in lines if line.startswith('Z ')]
    assert len(observations) == len(reset_units)
    for words, unit in zip(observations, reset_units):
        assert len(words) == 7
        id_, state, op, scan, accepted = map(int, words[:5])
        assert id_ == unit['id'] and accepted == int(id_ != 0)
        assert 0 <= state < 7 and 0 <= scan < p['S']
        assert int(words[5], 16) < 2**p['S'] and int(words[6], 16) < 2**p['S']
    return result


def run():
    assert not RECEIPT.exists(), 'existing receipt: no automatic retry'
    seal = read('SOURCE_SEAL.json')
    assert sources() == seal['files_sha256'], 'source seal mismatch'
    plan = fixture_checks()
    assert digest((ROOT/'TEST_PLAN.json').read_bytes()) == seal['test_plan_sha256']
    for item in seal['tools'].values():
        assert digest(Path(item['path']).read_bytes()) == item['sha256'], 'tool changed'
    for name in ('artifacts', 'reports'):
        assert not (ROOT/name).exists(), 'previous outputs: no automatic retry'
        (ROOT/name).mkdir()
    env = os.environ.copy()
    suite = REPO/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH'] = os.pathsep.join([str(suite/'bin'), str(suite/'lib'), env.get('PATH', '')])
    receipt = dict(schema=1, baseline=plan['baseline'], status='RUNNING',
                   maturity=['RTL_CANDIDATE', 'HW_UNVERIFIED'],
                   source_seal_sha256=digest(SEAL.read_bytes()),
                   test_plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
                   records=[dict(command=c, status='NOT_RUN') for c in plan['commands']],
                   timeout_terminal=True, no_retry=True, excluded_checks=plan['excluded_checks'])
    write(RECEIPT, receipt)
    for index, record in enumerate(receipt['records']):
        command = record['command']
        argv = [x.replace('{TMP}', str((ROOT/'artifacts').resolve())) for x in command['argv']]
        argv[0] = seal['tools'][argv[0]]['path']
        record['executed_argv'] = argv
        start = time.monotonic(); out = err = b''; timed_out = False
        try:
            kwargs = dict(cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            if os.name == 'nt': kwargs['creationflags'] = subprocess.CREATE_NEW_PROCESS_GROUP
            child = subprocess.Popen(argv, **kwargs)
            try:
                out, err = child.communicate(timeout=20)
            except subprocess.TimeoutExpired:
                timed_out = True
                if os.name == 'nt':
                    subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                                   capture_output=True, timeout=5)
                else: child.kill()
                out, err = child.communicate(timeout=5)
            record['returncode'] = child.returncode
        except Exception as error:
            record['runner_error'] = '%s: %s' % (type(error).__name__, error)
            record['returncode'] = None
        record.update(elapsed_seconds=time.monotonic()-start, timeout=timed_out)
        for suffix, raw in (('stdout', out), ('stderr', err)):
            relative = 'reports/%03d_%s.%s' % (index, command['name'], suffix)
            (ROOT/relative).write_bytes(raw)
            record[suffix] = relative; record[suffix+'_sha256'] = digest(raw)
        if timed_out: record['status'] = 'TIMEOUT'
        elif 'runner_error' in record: record['status'] = 'FAIL'
        elif command['expected'] == 'EXPECTED_REJECT':
            marker = b'ram_ternary_rule_table_invalid_parameters__see_README'
            record['status'] = 'EXPECTED_REJECT' if child.returncode != 0 and marker in out+err else 'FAIL'
        elif child.returncode != 0: record['status'] = 'FAIL'
        else:
            record['status'] = 'PASS'
            try:
                summary = parse_summary(command, out)
                if summary is not None: record['summary'] = summary
            except Exception as error:
                record['status'] = 'FAIL'
                record['runner_error'] = '%s: %s' % (type(error).__name__, error)
        write(RECEIPT, receipt)
        print(json.dumps(dict(child=index, name=command['name'], status=record['status'],
                              seconds=round(record['elapsed_seconds'], 3))), flush=True)
        if record['status'] not in ('PASS', 'EXPECTED_REJECT'):
            receipt['status'] = record['status']; write(RECEIPT, receipt)
            return 1
    receipt.update(status='PASS', maturity=['LINT_PASS', 'UNIT_SIM_PASS', 'HW_UNVERIFIED'],
                   children=len(receipt['records']),
                   max_child_seconds=max(r['elapsed_seconds'] for r in receipt['records']),
                   completed_commands=sum(p['completed_commands'] for p in plan['profiles']),
                   reset_probes=sum(p['reset_count'] for p in plan['profiles']),
                   physical_live_rows=sum(r.get('summary', {}).get('physical_rows', 0) for r in receipt['records']))
    # Successful exact generated vvp paths only. Failures retain their artifacts.
    removed = []
    for p in plan['profiles']:
        artifact = (ROOT/'artifacts'/(p['name']+'.vvp')).resolve()
        assert artifact.parent == (ROOT/'artifacts').resolve()
        raw = artifact.read_bytes()
        removed.append(dict(path=artifact.relative_to(ROOT).as_posix(), sha256=digest(raw)))
        artifact.unlink()
    (ROOT/'artifacts').rmdir()
    receipt['successful_artifacts_removed'] = removed
    write(RECEIPT, receipt)
    print(json.dumps(dict(status='PASS', completed=receipt['completed_commands'], resets=receipt['reset_probes'])))
    return 0


def audit():
    seal = read('SOURCE_SEAL.json'); receipt = read('verification.json')
    assert sources() == seal['files_sha256']
    assert receipt['source_seal_sha256'] == digest(SEAL.read_bytes())
    assert receipt['test_plan_sha256'] == digest((ROOT/'TEST_PLAN.json').read_bytes())
    assert [r['command'] for r in receipt['records']] == read('TEST_PLAN.json')['commands']
    for record in receipt['records']:
        if record['status'] == 'NOT_RUN': continue
        for suffix in ('stdout', 'stderr'):
            assert digest((ROOT/record[suffix]).read_bytes()) == record[suffix+'_sha256']
        if 'summary' in record:
            assert parse_summary(record['command'], (ROOT/record['stdout']).read_bytes()) == record['summary']
    print(json.dumps(dict(status=receipt['status'], source_hashes='MATCH', read_only=True,
                          executed=sum(r['status'] != 'NOT_RUN' for r in receipt['records']))))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    for action in ('freeze', 'run', 'audit'): group.add_argument('--'+action, action='store_true')
    options = parser.parse_args()
    if options.freeze: freeze()
    elif options.audit: audit()
    else: raise SystemExit(run())
