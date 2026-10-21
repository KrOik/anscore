"""Run additive extension cases, reusing only an audited unchanged test closure.

The baseline must contain runner_snapshot.py and source_list_snapshot.f whose
hashes match its tested inputs. Only literal CASES/INTEGRATIONS additions and
appended primary RTL paths are permitted; changed helpers require a full run.
"""
import argparse
import ast
import copy
import hashlib
import json
import sys
from pathlib import Path

import test_image_extensions as registry
from tooling import ROOT, PACKAGE, evidence_dir, execute, write_json


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def registry_tree(path):
    tree = ast.parse(path.read_text(encoding='utf-8'))
    bindings = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            name = node.targets[0].id
            if name in ('CASES', 'INTEGRATIONS'):
                bindings[name] = ast.literal_eval(node.value)
    require(set(bindings) == {'CASES', 'INTEGRATIONS'}, 'missing literal registries')
    rest = copy.deepcopy(tree)
    rest.body = [n for n in rest.body if not (
        isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
        and n.targets[0].id in bindings)]
    return bindings, ast.dump(rest, include_attributes=False)


def paths_from_list(path):
    return [line.strip() for line in path.read_text(encoding='utf-8').splitlines()
            if line.strip() and not line.lstrip().startswith('#')]


def require_import_matches_disk(bindings, runner):
    require(registry.CASES == bindings['CASES'] and registry.INTEGRATIONS == bindings['INTEGRATIONS'],
            'imported test registries differ from disk literals')
    tree = ast.parse(runner.read_text(encoding='utf-8'))
    explicit_inputs = [ast.literal_eval(node.value) for node in tree.body
                       if isinstance(node, ast.Assign) and len(node.targets) == 1
                       and isinstance(node.targets[0], ast.Name)
                       and node.targets[0].id == 'INTEGRATION_INPUTS']
    require(explicit_inputs == [registry.INTEGRATION_INPUTS], 'imported integration inputs differ from disk')


def tracked_inputs(source_list):
    tracked = [source_list, Path(registry.__file__).resolve(), Path(__file__).resolve(),
               PACKAGE/'integration/tooling.py', PACKAGE/'integration/audit_checkpoint.py',
               PACKAGE/'integration/test_extension_batch_guards.py']
    tracked += [ROOT/n for n in paths_from_list(source_list)]
    for _, script, source in registry.CASES:
        tracked += [PACKAGE/script, PACKAGE/source]
        tracked += [p for p in (PACKAGE/source).parent.rglob('*')
                    if p.is_file() and p.suffix in ('.py', '.v', '.sv', '.vh', '.hex', '.mem')]
    tracked += [PACKAGE/script for _, script, _ in registry.INTEGRATIONS]
    tracked += [PACKAGE/n for n in registry.INTEGRATION_INPUTS]
    return registry.snapshot_files(tracked)


def run(baseline):
    baseline = baseline.resolve()
    baseline_seals = {n: sha(baseline/n) for n in
                      ('results.json', 'checkpoint_audit.json', 'tested_input_sha256.json')}
    previous = read(baseline/'results.json')
    audit = read(baseline/'checkpoint_audit.json')
    require(audit['status'] == 'PASS' and audit['original_results_sha256'] == sha(baseline/'results.json'), 'baseline audit binding')
    require(audit.get('tested_input_record_sha256') == baseline_seals['tested_input_sha256.json'], 'baseline input record is not sealed by audit')
    require(previous['input_stability']['status'] == 'PASS' and previous['source_bundle_compile']['status'] == 'PASS', 'baseline gates')
    require(all(e['status'] == 'PASS' for e in previous['results']+previous['integrations']), 'baseline failures')
    old_inputs = read(baseline/'tested_input_sha256.json')
    require(len(old_inputs) == previous['input_stability']['tracked_file_count'], 'baseline input count')
    source_list = PACKAGE/'rtl_extension_sources.f'
    runner = Path(registry.__file__).resolve()
    require(sha(baseline/'runner_snapshot.py') == old_inputs[str(runner)], 'runner snapshot binding')
    require(sha(baseline/'source_list_snapshot.f') == old_inputs[str(source_list.resolve())], 'source list snapshot binding')
    old, old_body = registry_tree(baseline/'runner_snapshot.py')
    current, current_body = registry_tree(runner)
    require_import_matches_disk(current, runner)
    require(old_body == current_body, 'runner behavior changed: full regression required')
    for key in old:
        before = {row[0]: row for row in old[key]}
        after = {row[0]: row for row in current[key]}
        require(len(before) == len(old[key]) and len(after) == len(current[key]), 'duplicate registry name')
        require(all(after.get(n) == row for n, row in before.items()), 'existing test binding changed')
    require({(e['name'], e['source']) for e in previous['results']} == {(n, s) for n, _, s in old['CASES']}, 'baseline case coverage')
    require({e['name'] for e in previous['integrations']} == {n for n, _, _ in old['INTEGRATIONS']}, 'baseline integration coverage')
    require(all(len({e['name'] for e in previous[key]}) == len(previous[key])
                for key in ('results','integrations')), 'duplicate baseline result')
    require(len({s for _,_,s in current['CASES']}) == len(current['CASES']), 'duplicate primary source')
    for _, script, source in old['CASES']:
        closure = [PACKAGE/script, PACKAGE/source]
        closure += [p for p in (PACKAGE/source).parent.rglob('*')
                    if p.is_file() and p.suffix in ('.py', '.v', '.sv', '.vh', '.hex', '.mem')]
        require(all(str(p.resolve()) in old_inputs for p in closure), 'baseline case closure incomplete')
    require(all(str((PACKAGE/script).resolve()) in old_inputs for _, script, _ in old['INTEGRATIONS']), 'baseline integration closure incomplete')
    allowed = {str(runner), str(source_list.resolve())}
    require(all(n in allowed or sha(Path(n)) == h for n, h in old_inputs.items()), 'old tested input changed: full regression required')
    old_sources = paths_from_list(baseline/'source_list_snapshot.f')
    current_sources = paths_from_list(source_list)
    require(current_sources[:len(old_sources)] == old_sources and len(set(current_sources)) == len(current_sources), 'source list must append only')
    new_cases = [row for row in current['CASES'] if row[0] not in {r[0] for r in old['CASES']}]
    new_integrations = [row for row in current['INTEGRATIONS'] if row[0] not in {r[0] for r in old['INTEGRATIONS']}]
    require(new_cases, 'no new cases')
    require(set(current_sources[len(old_sources):]) == {str((PACKAGE/s).relative_to(ROOT)).replace('\\', '/') for _, _, s in new_cases}, 'new RTL paths differ from primary new cases')
    folder = evidence_dir('image_extensions_incremental')
    snapshot = tracked_inputs(source_list)
    require(set(old_inputs).issubset(snapshot), 'old tracked closure was removed')
    require(all(n in allowed or snapshot.get(n) == h for n, h in old_inputs.items()),
            'old input changed between preflight and snapshot')
    write_json(folder/'tested_input_sha256.json', snapshot)
    provenance = dict(baseline=str(baseline.relative_to(ROOT)), baseline_results_sha256=sha(baseline/'results.json'),
                      baseline_audit_sha256=sha(baseline/'checkpoint_audit.json'),
                      baseline_inputs_sha256=sha(baseline/'tested_input_sha256.json'),
                      unchanged_baseline_inputs=len(old_inputs)-len(allowed),
                      registry_behavior_unchanged=True, source_list_append_only=True)
    write_json(folder/'reuse_proof.json', provenance)
    results = {e['name']: dict(e, reused_from=provenance['baseline']) for e in previous['results']}
    integrations = {e['name']: dict(e, reused_from=provenance['baseline']) for e in previous['integrations']}
    for name, script, source in new_cases:
        item = dict(name=name, source=source, board_tested=False, status='PASS')
        try:
            execute([sys.executable, '-B', PACKAGE/script], ROOT, folder/f'{name}.log', timeout=600)
            item['rtl_sha256'] = sha(PACKAGE/source)
        except Exception as error:
            item.update(status='FAIL', error=str(error))
        results[name] = item
        print(name, item['status'], flush=True)
    for name, script, args in new_integrations:
        item = dict(name=name, status='PASS')
        try:
            execute([sys.executable, '-B', PACKAGE/script, *args], ROOT, folder/f'{name}.log', timeout=600)
        except Exception as error:
            item.update(status='FAIL', error=str(error))
        integrations[name] = item
        print(name, item['status'], flush=True)
    bundle = dict(status='PASS')
    try:
        execute(['iverilog', '-g2012', '-tnull', '-f', source_list], ROOT, folder/'bundle_compile.log', timeout=120)
    except Exception as error:
        bundle.update(status='FAIL', error=str(error))
    final_snapshot = tracked_inputs(source_list)
    changed = sorted(n for n in set(snapshot) | set(final_snapshot)
                     if snapshot.get(n) != final_snapshot.get(n))
    baseline_changed = [n for n, h in baseline_seals.items() if sha(baseline/n) != h]
    changed += ['baseline/' + n for n in baseline_changed]
    result = dict(scope='local functional simulation; additive tests with hash-verified baseline reuse',
                  execution_mode='verified_incremental', reuse_proof='reuse_proof.json',
                  results=[results[n] for n, _, _ in registry.CASES],
                  integrations=[integrations[n] for n, _, _ in registry.INTEGRATIONS],
                  source_bundle_compile=bundle,
                  input_stability=dict(status='FAIL' if changed else 'PASS', changed_files=changed,
                                       tracked_file_count=len(snapshot), sha256_record='tested_input_sha256.json'))
    write_json(folder/'results.json', result)
    (folder/'runner_snapshot.py').write_bytes(runner.read_bytes())
    (folder/'source_list_snapshot.f').write_bytes(source_list.read_bytes())
    passed = not changed and bundle['status'] == 'PASS' and all(
        e['status'] == 'PASS' for e in result['results']+result['integrations'])
    if passed:
        audit_incremental(folder)
    print(folder, flush=True)
    return int(not passed)


def audit_incremental(folder):
    """Seal the complete current closure, baseline identity, and actual new runs."""
    result = read(folder/'results.json')
    require(result.get('execution_mode') == 'verified_incremental', 'not an incremental result')
    tested = read(folder/'tested_input_sha256.json')
    source_list = PACKAGE/'rtl_extension_sources.f'
    runner = Path(registry.__file__).resolve()
    require(sha(folder/'runner_snapshot.py') == tested[str(runner)] and
            sha(folder/'source_list_snapshot.f') == tested[str(source_list.resolve())], 'current snapshots differ')
    require(tested == tracked_inputs(source_list), 'complete current input closure differs')
    require(len(tested) == result['input_stability']['tracked_file_count'], 'input count differs')
    require(result['input_stability']['status'] == 'PASS' and result['source_bundle_compile']['status'] == 'PASS', 'result gates')
    require(all(e['status'] == 'PASS' for e in result['results']+result['integrations']), 'failed tests')
    require([(e['name'],e['source']) for e in result['results']] == [(n,s) for n,_,s in registry.CASES], 'case coverage/order')
    require([e['name'] for e in result['integrations']] == [n for n,_,_ in registry.INTEGRATIONS], 'integration coverage/order')
    require(all(sha(PACKAGE/e['source']) == e['rtl_sha256'] for e in result['results']), 'case RTL changed')
    proof = read(folder/'reuse_proof.json')
    base = ROOT/proof['baseline']
    for key, name in [('baseline_results_sha256','results.json'), ('baseline_audit_sha256','checkpoint_audit.json'),
                      ('baseline_inputs_sha256','tested_input_sha256.json')]:
        require(sha(base/name) == proof[key], 'baseline provenance changed: '+name)
    base_result = read(base/'results.json')
    base_audit = read(base/'checkpoint_audit.json')
    base_inputs = read(base/'tested_input_sha256.json')
    require(base_audit['status'] == 'PASS' and base_audit['original_results_sha256'] == sha(base/'results.json')
            and base_audit.get('tested_input_record_sha256') == sha(base/'tested_input_sha256.json'), 'baseline seals differ')
    runner = Path(registry.__file__).resolve()
    allowed = {str(runner), str(source_list.resolve())}
    require(all(n in allowed or tested.get(n) == h for n,h in base_inputs.items()), 'reused input changed')
    require(sha(base/'runner_snapshot.py') == base_inputs[str(runner)] and
            sha(base/'source_list_snapshot.f') == base_inputs[str(source_list.resolve())], 'baseline snapshots differ')
    before, old_body = registry_tree(base/'runner_snapshot.py')
    after, new_body = registry_tree(runner)
    require_import_matches_disk(after, runner)
    require(old_body == new_body, 'runner behavior differs')
    require(len({s for _,_,s in after['CASES']}) == len(after['CASES']), 'duplicate primary source')
    for key, result_key in [('CASES','results'), ('INTEGRATIONS','integrations')]:
        old_bindings = {row[0]:row for row in before[key]}
        current_bindings = {row[0]:row for row in after[key]}
        require(len(old_bindings) == len(before[key]) and len(current_bindings) == len(after[key]), 'duplicate registry name')
        require(len({e['name'] for e in result[result_key]}) == len(result[result_key]) and
                len({e['name'] for e in base_result[result_key]}) == len(base_result[result_key]), 'duplicate result name')
        require(all(current_bindings.get(n) == row for n,row in old_bindings.items()), 'existing binding differs')
        old_entries = {e['name']:e for e in base_result[result_key]}
        require(set(old_entries) == set(old_bindings), 'baseline result coverage differs')
        for entry in result[result_key]:
            if entry['name'] in old_entries:
                require(entry == dict(old_entries[entry['name']], reused_from=proof['baseline']), 'reused result differs')
            else:
                require('reused_from' not in entry, 'new test incorrectly reused')
                require((folder/(entry['name']+'.log')).is_file(), 'missing freshly executed test log')
    for _, script, source in before['CASES']:
        closure = [PACKAGE/script, PACKAGE/source]
        closure += [p for p in (PACKAGE/source).parent.rglob('*')
                    if p.is_file() and p.suffix in ('.py','.v','.sv','.vh','.hex','.mem')]
        require(all(str(p.resolve()) in base_inputs for p in closure), 'reused case acquired untested helper')
    old_sources = paths_from_list(base/'source_list_snapshot.f')
    current_sources = paths_from_list(source_list)
    require(current_sources[:len(old_sources)] == old_sources and len(set(current_sources)) == len(current_sources), 'source list differs')
    new_sources = {str((PACKAGE/s).relative_to(ROOT)).replace('\\','/') for n,_,s in after['CASES']
                   if n not in {row[0] for row in before['CASES']}}
    require(set(current_sources[len(old_sources):]) == new_sources, 'new source bindings differ')
    baseline = read(PACKAGE/'board/tang25k/acceptance48/FINAL_PRODUCTION_SOURCE_SHA256.json')['files']
    require(len(baseline) == 202 and all(sha(ROOT/n) == h for n,h in baseline.items()), 'production baseline changed')
    paths = [ROOT/n for n in paths_from_list(source_list)]
    write_json(folder/'integrated_source_sha256.json', {str(p.relative_to(ROOT)):sha(p) for p in paths})
    write_json(folder/'production_baseline_check.json', dict(status='PASS', files_checked=202, all_unchanged=True))
    report = dict(status='PASS', execution_mode='verified_incremental', projects=len(registry.CASES),
                  integrations=len(registry.INTEGRATIONS), source_files=len(paths), stable_inputs=len(tested),
                  production_baseline=202, original_results_sha256=sha(folder/'results.json'),
                  tested_input_record_sha256=sha(folder/'tested_input_sha256.json'),
                  reuse_proof_sha256=sha(folder/'reuse_proof.json'),
                  fresh_cases=sum('reused_from' not in e for e in result['results']),
                  fresh_integrations=sum('reused_from' not in e for e in result['integrations']), board_tested=False)
    report['fresh_logs_sha256'] = {p.name:sha(p) for p in folder.glob('*.log')}
    write_json(folder/'checkpoint_audit.json', report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    parser.add_argument('--audit-only', action='store_true', help='Audit an already completed incremental folder')
    args = parser.parse_args()
    if args.audit_only:
        print(json.dumps(audit_incremental(args.baseline.resolve()), indent=2))
    else:
        raise SystemExit(run(args.baseline))
