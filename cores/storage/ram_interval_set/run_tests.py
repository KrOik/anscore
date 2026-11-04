"""Execute exactly the immutable pre-RTL matrix, once, with 20s HDL limits."""
import argparse
import ast
from hashlib import sha256
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
PLAN_SHA = '589322caca57f8e0992bbb38c379669c71e0af50d16d73f2c9e4e1d2547caa10'
PREP_SHA = '29df95850ae01703e4cce55e778557f934c5495ebbb0943d3423885d06a6f94d'
HELD_TARGETS = {16, 30, 31, 32, 34, 35, 36, 41, 42, 43, 44, 45}


def read(rel):
    return json.loads((ROOT / rel).read_text(encoding='utf-8'))


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def write(rel, data):
    (ROOT / rel).write_text(json.dumps(data, sort_keys=True, indent=2) + '\n',
                            encoding='utf-8', newline='\n')


def sources():
    return {p.relative_to(ROOT).as_posix(): digest(p)
            for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name not in {'SOURCE_FREEZE.json', 'verification.json'}
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def jobs(plan):
    result = {}
    for profile in plan['profiles']:
        for kind in ('main', 'resets'):
            for entry in profile[kind]:
                name = Path(entry['json']).stem
                result[name] = dict(profile=profile, kind=kind, entry=entry)
    return result


def oracle():
    spec = importlib.util.spec_from_file_location('interval_atoms_frozen', ROOT / 'prepare.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def matrix_audit(plan):
    assert digest(ROOT / 'TEST_PLAN.json') == PLAN_SHA
    assert digest(ROOT / 'prepare.py') == PREP_SHA == plan['preparation_sha256']
    assert plan['timeout_seconds'] == 20 and plan['frozen_before_any_rtl']
    assert plan['timeout_terminal'] and plan['no_adaptive_splits']
    assert len(plan['commands']) == len(plan['children']) == 268
    assert [x['name'] for x in plan['commands']] == plan['children']
    assert len(set(plan['children'])) == 268
    assert all(x['timeout_seconds'] == 20 for x in plan['commands'])
    model = oracle()
    for job in jobs(plan).values():
        entry, profile = job['entry'], job['profile']
        assert digest(ROOT / entry['json']) == entry['json_sha256']
        assert digest(ROOT / entry['text']) == entry['text_sha256']
        data = read(entry['json'])
        sequences = [data['items']] if job['kind'] == 'main' else [
            seq for unit in data['units'] for seq in (unit['setup'] + [unit['owner']], unit['fresh'])]
        for sequence in sequences:
            rebuilt, _ = model.evaluate(profile['N'], profile['A'],
                                         [x['command'] for x in sequence], [x['kind'] for x in sequence])
            assert rebuilt == sequence
    for p in ROOT.glob('*.py'):
        ast.parse(p.read_text(encoding='utf-8'))


def expected_job(job):
    data = read(job['entry']['json'])
    items, completed, cancelled, valid_ids = [], set(), {}, set()
    if job['kind'] == 'main':
        items = data['items']
        completed = set(range(len(items)))
        valid_ids = completed.copy()
        expected_queued = len(items) - 1
    else:
        expected_queued = 0
        for unit in data['units']:
            start = len(items)
            items += unit['setup']
            completed.update(range(start, len(items)))
            owner_id = len(items)
            items.append(unit['owner'])
            cancelled[owner_id] = unit
            if unit['id'] in HELD_TARGETS:
                valid_ids.add(owner_id)
            start = len(items)
            items += unit['fresh']
            completed.update(range(start, len(items)))
            expected_queued += len(unit['setup']) + len(unit['fresh']) - 2
        valid_ids.update(completed)
    return items, completed, cancelled, valid_ids, expected_queued


def parse_sim(stdout, job, finish_line):
    lines = [x.strip() for x in stdout.splitlines() if x.strip()]
    records, done, valids, cancellations = {}, {}, {}, []
    summary = None
    finish_pattern = re.compile(r'sim/tb_ram_interval_set\.sv:' + str(finish_line) + r': \$finish called at [0-9]+ \(1ps\)')
    assert lines and finish_pattern.fullmatch(lines[-1]), 'missing exact final Icarus finish notification'
    for line in lines[:-1]:
        parts = line.split()
        if parts[0] == 'REC':
            assert len(parts) == 16
            case, ordinal = map(int, parts[1:3])
            assert (case, ordinal) not in records
            records[case, ordinal] = dict(keep=int(parts[3]), first=int(parts[4]),
                last=int(parts[5]), index=int(parts[6]), base=int(parts[7], 16), bytes=int(parts[8], 16),
                status=int(parts[9]), count=int(parts[10]), total=int(parts[11], 16),
                covered=int(parts[12], 16), whole=int(parts[13]), op=int(parts[14]), tag=int(parts[15], 16))
        elif parts[0] == 'DONE':
            assert len(parts) == 4
            case, latency, count = map(int, parts[1:])
            assert case not in done
            done[case] = (latency, count)
        elif parts[0] == 'VALID':
            assert len(parts) == 3
            case, latency = map(int, parts[1:])
            assert case not in valids
            valids[case] = latency
        elif parts[0] == 'CANCEL':
            assert len(parts) == 5
            cancellations.append(tuple(map(int, parts[1:])))
        elif parts[0] == 'PASS':
            assert summary is None and line == lines[-2]
            summary = {k: int(v, 16) if k == 'state_mask' else int(v)
                       for k, v in (x.split('=') for x in parts[1:])}
        else:
            raise AssertionError('unexpected simulator output: ' + line)
    assert summary is not None
    items, completed, cancelled, valid_ids, queued = expected_job(job)
    assert set(done) == completed and set(valids) == valid_ids
    expected_records = {}
    for i, item in enumerate(items):
        if i in cancelled:
            count = cancelled[i]['owner_retired_prefix']
        else:
            count = len(item['expected']['records'])
        for ordinal, row in enumerate(item['expected']['records'][:count]):
            e = item['expected']
            expected_records[i, ordinal] = dict(row, **{k: e[k] for k in ('status', 'count', 'total', 'covered', 'whole')},
                                                 op=item['command'][0], tag=item['command'][3])
        if i in completed:
            assert done[i] == (valids[i], len(item['expected']['records']))
    assert records == expected_records, 'actual retired fields differ from frozen atom gold'
    expected_cancels = [(unit['id'], owner, unit['owner_retired_prefix']) for owner, unit in cancelled.items()]
    assert [(target, owner, prefix) for target, state, owner, prefix in cancellations] == expected_cancels
    for target, state, owner, prefix in cancellations:
        if target < 19:
            assert state == target
        elif target in range(19, 26):
            assert state == 4
        elif target in (26, 27):
            assert state == 5
        elif target in (28, 29):
            assert state == 13
        elif target == 33:
            assert state == 9
        elif target in (38, 39, 40):
            assert state == 6
        elif target == 37:
            assert state != 0
        else:
            assert state == 16
    assert all(0 <= x <= job['profile']['first_response_design_bound'] for x in valids.values())
    expected_accepts = len(items) - sum(unit['id'] == 0 for unit in cancelled.values())
    assert summary['completed'] == len(completed) and summary['resets'] == len(cancelled)
    assert summary['queued'] == queued and summary['accepts'] == expected_accepts
    assert summary['retired'] == len(records) and summary['valids'] == len(valids)
    assert summary['max_latency'] == max(valids.values())
    assert summary['source_holds'] > 0 and summary['output_holds'] >= 2 * sum(
        len(items[i]['expected']['records']) for i in completed)
    return dict(summary, job=Path(job['entry']['json']).stem,
                profile=job['profile']['name'], kind=job['kind'],
                cancelled_ids=[x[0] for x in cancellations], finish_notice=lines[-1])


def aggregate(plan, simulations):
    profiles = []
    for profile in plan['profiles']:
        actual = [x for x in simulations if x['profile'] == profile['name']]
        assert len(actual) == len(profile['main']) + len(profile['resets'])
        totals = {key: sum(x[key] for x in actual) for key in (
            'completed', 'resets', 'queued', 'accepts', 'retired', 'valids',
            'reads', 'writes', 'rows', 'source_holds', 'output_holds')}
        mask = 0
        for item in actual:
            mask |= item['state_mask']
        assert mask == (1 << 19) - 1
        assert totals['resets'] == profile['reset_count']
        assert totals['completed'] == profile['main_commands'] + profile['setup_commands'] + profile['fresh_commands']
        assert totals['retired'] == profile['main_outputs'] + profile['setup_outputs'] + profile['fresh_outputs'] + sum(
            1 if target == 31 else 2 if target == 32 else 0 for target in profile['reset_ids'])
        profiles.append(dict(profile=profile['name'], numeric_marker='INTERVAL_SET_' + profile['name'] + '_NUMERIC_PASS',
                             state_mask=mask, max_latency=max(x['max_latency'] for x in actual), **totals))
    return profiles


def archive(receipt, temporary):
    dest = ROOT / 'failure_archive' / 'attempt_01'
    assert not dest.exists()
    dest.mkdir(parents=True)
    rels = list(sources()) + ['SOURCE_FREEZE.json', 'verification.json']
    for rel in rels:
        target = dest / 'tested_source' / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes((ROOT / rel).read_bytes())
    (dest / 'NOT_RUN.json').write_bytes((json.dumps(receipt['not_run'], indent=2) + '\n').encode())
    for source in temporary.glob('*.vvp'):
        (dest / 'artifacts').mkdir(exist_ok=True)
        shutil.copyfile(source, dest / 'artifacts' / source.name)
    files = {p.relative_to(dest).as_posix(): digest(p) for p in sorted(dest.rglob('*')) if p.is_file()}
    (dest / 'archive.json').write_bytes((json.dumps(dict(status=receipt['status'], files_sha256=files,
                  plan_sha256=PLAN_SHA, root_repair_authorization_required=True), sort_keys=True, indent=2) + '\n').encode())


def seal():
    assert not (ROOT / 'SOURCE_FREEZE.json').exists() and not (ROOT / 'verification.json').exists()
    plan = read('TEST_PLAN.json')
    matrix_audit(plan)
    source_map = sources()
    for rel in source_map:
        raw = (ROOT / rel).read_bytes()
        raw.decode('utf-8')
        assert b'\r' not in raw and raw.endswith(b'\n')
    lines = (ROOT / 'sim/tb_ram_interval_set.sv').read_text().splitlines()
    finish = [i + 1 for i, line in enumerate(lines) if line.strip() == '$finish;']
    assert len(finish) == 1
    write('SOURCE_FREEZE.json', dict(schema=1, before_first_hdl_tool=True,
          baseline=plan['baseline'], plan_sha256=PLAN_SHA, source_sha256=source_map,
          commands=plan['commands'], timeout_seconds=20, finish_notice_line=finish[0]))
    print('SOURCE_FROZEN', digest(ROOT / 'SOURCE_FREEZE.json'), len(source_map), 'sources')


def run():
    assert not (ROOT / 'verification.json').exists(), 'existing receipt forbids retry'
    plan, frozen = read('TEST_PLAN.json'), read('SOURCE_FREEZE.json')
    matrix_audit(plan)
    assert frozen['source_sha256'] == sources() and frozen['commands'] == plan['commands']
    binary = REPO / 'tools/oss-cad-suite/oss-cad-suite/bin'
    env = os.environ.copy()
    env['PATH'] = str(binary) + os.pathsep + str(binary.parent / 'lib') + os.pathsep + env.get('PATH', '')
    assert (binary / 'iverilog.exe').is_file() and (binary / 'vvp.exe').is_file()
    receipt = dict(schema=1, status='RUNNING', hardware='HW_UNVERIFIED', baseline=plan['baseline'],
        plan_sha256=PLAN_SHA, source_freeze_sha256=digest(ROOT / 'SOURCE_FREEZE.json'),
        source_sha256=sources(), children=[], simulations=[], profiles=[],
        not_run=plan['children'].copy(), excluded_checks=plan['excluded_checks'], timeout_occurred=False)
    byname = jobs(plan)
    with tempfile.TemporaryDirectory(prefix='anscore_b25_interval_set_') as temp:
        temporary = Path(temp)
        write('verification.json', receipt)
        for command in frozen['commands']:
            name = command['name']
            argv = [str(binary / (command['argv'][0] + '.exe'))] + [x.replace('{TMP}', str(temporary)) for x in command['argv'][1:]]
            record = dict(command, actual_argv=argv)
            start = time.monotonic()
            try:
                child = subprocess.run(argv, cwd=ROOT, env=env, capture_output=True, text=True, encoding='utf-8', timeout=20)
                record.update(returncode=child.returncode, stdout=child.stdout, stderr=child.stderr,
                              elapsed_seconds=round(time.monotonic() - start, 6))
                if command['expected'] == 'EXPECTED_REJECT':
                    assert child.returncode != 0 and 'ram_interval_set_invalid_parameters__see_README' in child.stderr
                    record['status'] = 'EXPECTED_REJECT'
                else:
                    assert child.returncode == 0 and not child.stderr, (child.returncode, child.stderr)
                    if name in byname:
                        receipt['simulations'].append(parse_sim(child.stdout, byname[name], frozen['finish_notice_line']))
                    record['status'] = 'PASS'
            except subprocess.TimeoutExpired as error:
                def decoded(value):
                    return value.decode('utf-8', errors='replace') if isinstance(value, bytes) else (value or '')
                record.update(status='TIMEOUT', stdout=decoded(error.stdout), stderr=decoded(error.stderr),
                              elapsed_seconds=round(time.monotonic() - start, 6))
                receipt['timeout_occurred'] = True
            except Exception as error:
                record.update(status='FAIL', error=type(error).__name__ + ': ' + str(error))
            receipt['children'].append(record)
            receipt['not_run'].pop(0)
            print(name, record['status'], record.get('elapsed_seconds'), flush=True)
            if record['status'] in ('FAIL', 'TIMEOUT'):
                receipt['status'] = record['status']
                write('verification.json', receipt)
                archive(receipt, temporary)
                return
            write('verification.json', receipt)
        try:
            assert sources() == frozen['source_sha256']
            receipt['profiles'] = aggregate(plan, receipt['simulations'])
            receipt['totals'] = {key: sum(x[key] for x in receipt['profiles']) for key in (
                'completed', 'resets', 'queued', 'accepts', 'retired', 'valids', 'reads', 'writes', 'rows', 'source_holds', 'output_holds')}
            assert receipt['totals']['completed'] == 19642 and receipt['totals']['retired'] == 24616
            assert receipt['totals']['resets'] == 258 and receipt['totals']['queued'] == 19025
            assert receipt['totals']['accepts'] == 19894 and receipt['totals']['valids'] == 19708
            receipt['status'] = 'UNIT_SIM_PASS'
        except Exception as error:
            receipt['status'] = 'FAIL'
            receipt['final_error'] = type(error).__name__ + ': ' + str(error)
            write('verification.json', receipt)
            archive(receipt, temporary)
            return
        write('verification.json', receipt)
    audit()


def audit():
    plan, frozen, receipt = read('TEST_PLAN.json'), read('SOURCE_FREEZE.json'), read('verification.json')
    matrix_audit(plan)
    assert sources() == frozen['source_sha256'] == receipt['source_sha256']
    assert receipt['plan_sha256'] == PLAN_SHA and receipt['source_freeze_sha256'] == digest(ROOT / 'SOURCE_FREEZE.json')
    assert receipt['status'] == 'UNIT_SIM_PASS' and not receipt['timeout_occurred'] and not receipt['not_run']
    assert len(receipt['children']) == 268 and [x['name'] for x in receipt['children']] == plan['children']
    assert all(x['status'] == x['expected'] and x['timeout_seconds'] == 20 and x['elapsed_seconds'] < 20 for x in receipt['children'])
    assert aggregate(plan, receipt['simulations']) == receipt['profiles']
    print('OFFLINE_AUDIT_PASS 268 children; 6 numeric profiles; immutable source closure')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--seal', action='store_true')
    parser.add_argument('--run', action='store_true')
    parser.add_argument('--audit', action='store_true')
    args = parser.parse_args()
    assert sum((args.seal, args.run, args.audit)) == 1
    if args.seal:
        seal()
    elif args.run:
        run()
    else:
        audit()
