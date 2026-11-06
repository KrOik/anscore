"""SPDX-License-Identifier: Apache-2.0. One reviewed finite attempt, no retry."""
from pathlib import Path
import datetime, hashlib, json, os, re, signal, subprocess, sys, time, traceback

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BIN = REPO/'tools/oss-cad-suite/oss-cad-suite/bin'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def execute(check, argv, env, report):
    start = time.monotonic()
    out = err = b''
    record = dict(name=check['name'], argv=argv, cwd=str(ROOT), cleanup=[])
    options = {'creationflags': subprocess.CREATE_NO_WINDOW} if os.name == 'nt' else {'start_new_session': True}
    try:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **options)
    except OSError as exc:
        record.update(status='NOT_RUN', error=repr(exc))
    else:
        try:
            out, err = child.communicate(timeout=20)
            record.update(status='PASS' if child.returncode == 0 else 'FAIL', returncode=child.returncode)
        except subprocess.TimeoutExpired as exc:
            record.update(status='TIMEOUT')
            out, err = exc.stdout or b'', exc.stderr or b''
            if os.name == 'nt':
                kill = [str(Path(os.environ.get('SystemRoot', r'C:\Windows'))/'System32/taskkill.exe'), '/PID', str(child.pid), '/T', '/F']
                try:
                    killed = subprocess.run(kill, capture_output=True, timeout=5, creationflags=subprocess.CREATE_NO_WINDOW)
                    record['cleanup'].append(dict(argv=kill, returncode=killed.returncode,
                        stdout=killed.stdout.decode(errors='replace'), stderr=killed.stderr.decode(errors='replace')))
                except (OSError, subprocess.TimeoutExpired) as cleanup_exc:
                    record['cleanup'].append(dict(error=repr(cleanup_exc)))
            else:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError as cleanup_exc:
                    record['cleanup'].append(dict(error=repr(cleanup_exc)))
            try:
                if child.poll() is None:
                    child.kill()
                out, err = child.communicate(timeout=2)
            except (OSError, subprocess.TimeoutExpired) as cleanup_exc:
                record['cleanup'].append(dict(drain_error=repr(cleanup_exc)))
            record['returncode'] = child.poll()
    marker = check.get('marker')
    if record['status'] == 'PASS' and marker:
        matches = [line for line in out.decode(errors='replace').splitlines() if line.startswith(marker)]
        if len(matches) != 1 or (check['name'].startswith('sim') and b'$finish' not in out):
            record['status'] = 'FAIL_COMPLETION'
        else:
            record['observed'] = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)', matches[0])}
            if any(record['observed'].get(k) != v for k, v in check.get('expected_counters', {}).items()):
                record['status'] = 'FAIL_COVERAGE'
    for stream, data in [('stdout', out), ('stderr', err)]:
        (report/(check['name']+'.'+stream+'.txt')).write_bytes(data)
        record[stream+'_sha256'] = hashlib.sha256(data).hexdigest()
    record.update(seconds=round(time.monotonic()-start, 4), timeout_seconds=20,
                  tree_cleanup_seconds=5, drain_seconds=2, cleanup_budget_seconds=7, marker=marker)
    return record


def main():
    if sys.argv[1:] != ['--execute-approved-plan']:
        raise SystemExit('Root source/plan review and explicit execution authorization required')
    report_root = ROOT/'reports'
    if report_root.exists() and any(report_root.iterdir()):
        raise SystemExit('Existing attempt evidence; no automatic retry')
    plan_path, seal_path = ROOT/'PRECHECK_PLAN.json', ROOT/'PRECHECK_SEAL.json'
    plan, seal = json.loads(plan_path.read_bytes()), json.loads(seal_path.read_bytes())
    assert plan['baseline'] == '31a83135a22f845d85840524986895217567625c'
    assert set(seal['sha256']) == set(plan['sources'])-{'PRECHECK_SEAL.json'}
    assert all(sha(ROOT/p) == h for p, h in seal['sha256'].items())
    assert plan['tools'] == {p: sha(Path(p)) for p in plan['tools']}
    assert plan['preparation_tool']['sha256'] == sha(Path(plan['preparation_tool']['path']))
    assert Path(sys.executable).resolve() == Path(plan['preparation_tool']['path']).resolve()
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report = report_root/stamp
    report.mkdir(parents=True, exist_ok=False)
    build = ROOT/'.build'/stamp
    build.mkdir(parents=True, exist_ok=False)
    archives = {p: ('reports/'+stamp+'/sources/'+p.replace('../', 'parent/')+
                   ('.executed.txt' if p == '.gitattributes' else '')) for p in plan['sources']}
    result = dict(schema='anscore-b41-phase-allan-variance-finite-v1', baseline=plan['baseline'],
        utc=stamp, status='INCOMPLETE', plan_sha256=sha(plan_path), seal_sha256=sha(seal_path),
        source_sha256={p: sha(ROOT/p) for p in plan['sources']}, archived_sources=archives,
        tools=plan['tools'], preparation_tools={plan['preparation_tool']['path']: plan['preparation_tool']['sha256']},
        checks=[], preparations=[], profiles=[], artifacts=[], preparation_attempts=0, preparation_completed_calls=0,
        oracle_imports=0, archive_complete=False, preparation_complete=False, suite_complete=False,
        automatic_retry=False, expected_checks=[c['name'] for c in plan['checks']],
        synthesis='NOT_RUN', pnr='NOT_RUN', sta='NOT_RUN', board='NOT_RUN', hardware='HW_UNVERIFIED')

    def persist():
        temporary = report/'results.json.tmp'
        with temporary.open('w', encoding='utf8', newline='\n') as stream:
            json.dump(result, stream, indent=2)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(report/'results.json')

    def unchanged():
        assert all(sha(ROOT/p) == h for p, h in result['source_sha256'].items())
        assert all(sha(ROOT/archives[p]) == h for p, h in result['source_sha256'].items())
        assert all(sha(Path(p)) == h for p, h in result['tools'].items())
        assert all(sha(Path(p)) == h for p, h in result['preparation_tools'].items())
        for profile in result['profiles']:
            assert sha(report/profile['vector']) == profile['vector_sha256']
            assert sha(report/profile['preparation']) == profile['preparation_sha256']

    persist()
    try:
        for source, archived in archives.items():
            target = ROOT/archived
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT/source).read_bytes())
        (report/'plan.json').write_bytes(plan_path.read_bytes())
        result['archive_complete'] = True
        persist()
        env = dict(os.environ)
        env['PATH'] = str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH', '')
        env['PYTHONDONTWRITEBYTECODE'] = '1'
        for i, profile in enumerate(plan['profiles']):
            unchanged()
            result['preparation_attempts'] += 1
            result['active_preparation'] = i
            persist()
            check = dict(name='prepare%d' % i, marker='PREPARED phase_allan_variance ', expected_counters={'profile': i})
            argv = [plan['preparation_tool']['path'], '-B', 'reference_model.py', '--prepare-reviewed-profile', str(i), str(report)]
            record = execute(check, argv, env, report)
            result['preparations'].append(record)
            result['active_preparation'] = None
            if record['status'] != 'PASS':
                result['status'] = record['status']
                persist()
                return 1
            prepared = json.loads((report/('preparation%d.json' % i)).read_bytes())
            result['profiles'].append(dict(**profile, vector='vectors%d.txt' % i,
                vector_sha256=sha(report/('vectors%d.txt' % i)), preparation='preparation%d.json' % i,
                preparation_sha256=sha(report/('preparation%d.json' % i)), **prepared))
            result['preparation_completed_calls'] += 1
            persist()
            print(check['name'], record['status'], flush=True)
        result['preparation_complete'] = True
        persist()
        for check in plan['checks']:
            unchanged()
            argv = [x.replace('<stamp>', stamp) for x in check['argv']]
            current = dict(check)
            if check['name'].startswith('sim'):
                current['expected_counters'] = result['profiles'][check['profile']]['expected_counters']
            result['active_child'] = check['name']
            persist()
            record = execute(current, argv, env, report)
            result['checks'].append(record)
            result['active_child'] = None
            if check.get('artifact'):
                artifact = Path(check['artifact'].replace('<stamp>', stamp))
                if artifact.is_file():
                    result['artifacts'].append(dict(path=artifact.relative_to(ROOT).as_posix(),
                        sha256=sha(artifact), bytes=artifact.stat().st_size))
            persist()
            print(check['name'], record['status'], flush=True)
            if record['status'] != 'PASS':
                result['status'] = record['status']
                return 1
        result.update(status='PASS', suite_complete=True)
        return 0
    except Exception:
        result.update(status='RUNNER_FAILED', exception=traceback.format_exc())
        raise
    finally:
        result['sources_unchanged'] = all(sha(ROOT/p) == h for p, h in result['source_sha256'].items())
        result['archive_unchanged'] = result['archive_complete'] and all(sha(ROOT/archives[p]) == h for p, h in result['source_sha256'].items())
        result['vectors_unchanged'] = all(sha(report/x['vector']) == x['vector_sha256'] and
            sha(report/x['preparation']) == x['preparation_sha256'] for x in result['profiles'])
        result['tools_unchanged'] = all(sha(Path(p)) == h for p, h in {**result['tools'], **result['preparation_tools']}.items())
        result['check_sequence_matches'] = [c['name'] for c in result['checks']] == result['expected_checks']
        if not all(result[k] for k in ['sources_unchanged', 'archive_unchanged', 'vectors_unchanged', 'tools_unchanged']):
            result['status'] = 'SOURCE_CHANGED'
        if result['status'] == 'PASS' and not (result['suite_complete'] and result['preparation_complete'] and result['check_sequence_matches']):
            result['status'] = 'INCOMPLETE'
        persist()
        print('Evidence:', report.relative_to(ROOT), flush=True)


if __name__ == '__main__':
    sys.exit(main())
