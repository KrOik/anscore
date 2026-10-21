"""Independent recursive provenance audit; does not run RTL tests or touch board.

Usage: python -B .../audit_extension_ancestry.py HEAD_EVIDENCE_FOLDER
       python -B .../audit_extension_ancestry.py --self-test

Only ancestry_check.json is created (exclusive create; existing reports are never
replaced). This auxiliary checker is deliberately not a functional test input.
No historical runner is imported or executed: registries are read with ast.
"""
import argparse
import ast
import copy
import datetime
import hashlib
import json
import re
import tempfile
from pathlib import Path

ROOT = next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir())
PACKAGE = Path(__file__).resolve().parents[1]
HEX = re.compile(r'^[0-9a-f]{64}$')
CODE_SUFFIXES = {'.py', '.v', '.sv', '.vh', '.hex', '.mem'}


class AuditError(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise AuditError(message)


def raw_sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def no_duplicate_keys(pairs):
    out = {}
    for key, value in pairs:
        require(key not in out, 'duplicate JSON key: ' + key)
        out[key] = value
    return out


def read_json(path):
    return json.loads(Path(path).read_text(encoding='utf-8'), object_pairs_hook=no_duplicate_keys)


def registries(path):
    tree = ast.parse(Path(path).read_text(encoding='utf-8'))
    literal = {}
    for node in tree.body:
        if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name):
            key = node.targets[0].id
            if key in ('CASES', 'INTEGRATIONS', 'INTEGRATION_INPUTS'):
                require(key not in literal, 'duplicate registry assignment: ' + key)
                literal[key] = ast.literal_eval(node.value)
    require(set(literal) == {'CASES', 'INTEGRATIONS', 'INTEGRATION_INPUTS'}, 'missing literal registry/input list')
    for key in ('CASES', 'INTEGRATIONS'):
        require(isinstance(literal[key], (tuple, list)), 'registry is not a list: ' + key)
        for row in literal[key]:
            require(isinstance(row, (tuple, list)) and len(row) == 3, 'bad registry row: ' + key)
            require(isinstance(row[0], str) and re.fullmatch(r'[A-Za-z0-9_\-]+', row[0]), 'unsafe test name')
            require(isinstance(row[1], str), 'non-string script path')
            if key == 'CASES':
                require(isinstance(row[2], str), 'non-string primary source')
            else:
                require(isinstance(row[2], (list, tuple)) and all(isinstance(x, str) for x in row[2]), 'bad integration args')
        require(len({r[0] for r in literal[key]}) == len(literal[key]), 'duplicate registry name: ' + key)
    require(not ({r[0] for r in literal['CASES']} & {r[0] for r in literal['INTEGRATIONS']}), 'case/integration log name collision')
    require(isinstance(literal['INTEGRATION_INPUTS'], (list, tuple)) and all(isinstance(p, str) for p in literal['INTEGRATION_INPUTS']), 'bad explicit integration inputs')
    rest = copy.deepcopy(tree)
    rest.body = [n for n in rest.body if not (
        isinstance(n, ast.Assign) and len(n.targets) == 1 and isinstance(n.targets[0], ast.Name)
        and n.targets[0].id in ('CASES', 'INTEGRATIONS'))]
    return literal, ast.dump(rest, include_attributes=False)


def source_lines(path):
    return [s.strip() for s in Path(path).read_text(encoding='utf-8').splitlines()
            if s.strip() and not s.lstrip().startswith('#')]


class Checker:
    def __init__(self, root=ROOT, package=PACKAGE):
        self.root, self.package = Path(root).resolve(), Path(package).resolve()
        self.runner = (self.package/'integration/test_image_extensions.py').resolve()
        self.source_list = (self.package/'rtl_extension_sources.f').resolve()
        self.allowed = {self.runner, self.source_list}
        self.observed = {}
        self.visited = set()
        self.layers = []

    def inside(self, parent, name):
        require(isinstance(name, str) and name, 'empty/non-string path')
        p = (parent/name).resolve()
        require(p.is_relative_to(self.root), 'path escapes repository: ' + name)
        return p

    def sha(self, path):
        path = Path(path).resolve()
        require(path.is_file(), 'missing file: ' + str(path))
        digest = raw_sha(path)
        require(path not in self.observed or self.observed[path] == digest, 'file changed during audit: ' + str(path))
        self.observed[path] = digest
        return digest

    def json(self, path):
        self.sha(path)
        return read_json(path)

    def need_input(self, table, path, what):
        require(Path(path).resolve() in table, 'untracked ' + what + ': ' + str(path))

    def inputs(self, folder, result):
        raw = self.json(folder/'tested_input_sha256.json')
        require(isinstance(raw, dict) and raw, 'empty/non-map tested input table')
        table = {}
        for name, digest in raw.items():
            require(isinstance(digest, str) and HEX.fullmatch(digest), 'invalid input digest: ' + name)
            require(Path(name).is_absolute(), 'tested input path is not absolute: ' + name)
            p = self.inside(self.root, name)
            require(p not in table, 'duplicate normalized input path: ' + name)
            table[p] = digest
            if p not in self.allowed:
                require(self.sha(p) == digest, 'non-registry historical input changed: ' + str(p))
        gate = result.get('input_stability', {})
        require(gate.get('status') == 'PASS' and gate.get('changed_files') == [], 'input stability failed')
        require(gate.get('tracked_file_count') == len(table), 'tracked input count differs')
        require(gate.get('sha256_record') == 'tested_input_sha256.json', 'unexpected input record')
        self.need_input(table, self.runner, 'registry runner')
        self.need_input(table, self.source_list, 'source list')
        require(self.sha(folder/'runner_snapshot.py') == table[self.runner], 'runner snapshot/table binding')
        require(self.sha(folder/'source_list_snapshot.f') == table[self.source_list], 'source snapshot/table binding')
        return table

    def layer(self, folder):
        folder = Path(folder).resolve()
        require(folder.is_relative_to(self.root), 'evidence folder outside repository')
        require(folder not in self.visited, 'ancestry cycle: ' + str(folder))
        self.visited.add(folder)
        result = self.json(folder/'results.json')
        audit = self.json(folder/'checkpoint_audit.json')
        require(audit.get('status') == 'PASS', 'checkpoint audit did not PASS: ' + str(folder))
        require(audit.get('original_results_sha256') == self.sha(folder/'results.json'), 'checkpoint/results seal differs: ' + str(folder))
        require(audit.get('tested_input_record_sha256') == self.sha(folder/'tested_input_sha256.json'), 'checkpoint/input-table seal differs: ' + str(folder))
        require(audit.get('production_baseline') == 202, 'checkpoint lacks 202-file production baseline')
        require(audit.get('board_tested') is False, 'unexpected board acceptance claim')
        require(result.get('source_bundle_compile', {}).get('status') == 'PASS', 'source bundle failed')
        table = self.inputs(folder, result)
        bindings, body = registries(folder/'runner_snapshot.py')
        paths = [self.inside(self.root, s) for s in source_lines(folder/'source_list_snapshot.f')]
        require(len(paths) == len(set(paths)), 'duplicate source-list entry')
        require(len({self.inside(self.package, r[2]) for r in bindings['CASES']}) == len(bindings['CASES']), 'duplicate primary source')
        for path in paths:
            self.need_input(table, path, 'bundle source')
        for _, script, source in bindings['CASES']:
            primary = self.inside(self.package, source)
            require(primary in paths, 'primary source missing from bundle: ' + source)
            closure = [self.inside(self.package, script), primary]
            closure += [p.resolve() for p in primary.parent.rglob('*') if p.is_file() and p.suffix in CODE_SUFFIXES]
            for path in closure:
                self.need_input(table, path, 'case/helper closure')
        for _, script, _ in bindings['INTEGRATIONS']:
            self.need_input(table, self.inside(self.package, script), 'integration script')
        for name in bindings['INTEGRATION_INPUTS']:
            self.need_input(table, self.inside(self.package, name), 'explicit integration input')
        entries = {}
        for registry_key, result_key in [('CASES', 'results'), ('INTEGRATIONS', 'integrations')]:
            rows = result.get(result_key)
            require(isinstance(rows, list), 'missing result list')
            require(all(isinstance(e, dict) and e.get('status') == 'PASS' for e in rows), 'failed/malformed historical result')
            require([e.get('name') for e in rows] == [r[0] for r in bindings[registry_key]], 'historical registry/result coverage/order: ' + result_key)
            require(len({e['name'] for e in rows}) == len(rows), 'duplicate historical result name')
            entries[result_key] = {e['name']: e for e in rows}
            if registry_key == 'CASES':
                for row, entry in zip(bindings[registry_key], rows):
                    require(entry.get('source') == row[2], 'case/result source binding differs')
                    require(entry.get('board_tested') is False, 'case falsely claims board tested')
                    require(entry.get('rtl_sha256') == table[self.inside(self.package, row[2])], 'case RTL/table hash differs')
        for key, expected in [('projects', len(bindings['CASES'])), ('integrations', len(bindings['INTEGRATIONS'])), ('source_files', len(paths)), ('stable_inputs', len(table))]:
            require(audit.get(key) == expected, 'checkpoint count differs: ' + key)
        mode = result.get('execution_mode')
        incremental = mode == 'verified_incremental'
        summary = dict(folder=str(folder.relative_to(self.root)), execution_mode=mode or 'full_regression',
                       projects=len(bindings['CASES']), integrations=len(bindings['INTEGRATIONS']),
                       source_files=len(paths), tracked_inputs=len(table),
                       results_sha256=self.sha(folder/'results.json'), audit_sha256=self.sha(folder/'checkpoint_audit.json'),
                       tested_inputs_sha256=self.sha(folder/'tested_input_sha256.json'))
        self.layers.append(summary)
        if incremental:
            require(audit.get('execution_mode') == 'verified_incremental', 'incremental audit mode differs')
            require(result.get('reuse_proof') == 'reuse_proof.json', 'unexpected reuse proof file')
            proof = self.json(folder/'reuse_proof.json')
            require(audit.get('reuse_proof_sha256') == self.sha(folder/'reuse_proof.json'), 'checkpoint/proof seal differs')
            baseline_name = proof.get('baseline')
            require(isinstance(baseline_name, str) and not Path(baseline_name).is_absolute(), 'baseline path must be relative')
            baseline = self.inside(self.root, baseline_name)
            require(baseline not in self.visited, 'ancestry cycle: ' + str(baseline))
            for key, name in [('baseline_results_sha256', 'results.json'), ('baseline_audit_sha256', 'checkpoint_audit.json'), ('baseline_inputs_sha256', 'tested_input_sha256.json')]:
                require(proof.get(key) == self.sha(baseline/name), 'baseline provenance differs: ' + name)
            require(proof.get('registry_behavior_unchanged') is True and proof.get('source_list_append_only') is True, 'proof does not assert additive reuse')
            old = self.layer(baseline)
            require(body == old['body'], 'AST behavior changed beyond literal CASES/INTEGRATIONS')
            require(set(old['table']).issubset(table), 'old tracked closure removed')
            require(all(p in self.allowed or table[p] == h for p, h in old['table'].items()), 'ancestor input table changed')
            require(proof.get('unchanged_baseline_inputs') == len(old['table'])-2, 'proof unchanged-input count differs')
            require(paths[:len(old['paths'])] == old['paths'], 'source list is not append-only')
            logs = audit.get('fresh_logs_sha256')
            require(isinstance(logs, dict) and logs, 'missing sealed fresh logs')
            require(set(logs) == {p.name for p in folder.glob('*.log')}, 'fresh-log inventory differs')
            for name, digest in logs.items():
                require(Path(name).name == name and name.endswith('.log'), 'unsafe fresh-log path')
                require(self.sha(folder/name) == digest, 'fresh-log hash differs: ' + name)
            require('bundle_compile.log' in logs, 'bundle compile log is not sealed')
            new_primary = set()
            for registry_key, result_key in [('CASES', 'results'), ('INTEGRATIONS', 'integrations')]:
                before = {r[0]: r for r in old['bindings'][registry_key]}
                after = {r[0]: r for r in bindings[registry_key]}
                require(all(after.get(n) == r for n, r in before.items()), 'existing registry binding changed')
                require([r for r in bindings[registry_key] if r[0] in before] == list(old['bindings'][registry_key]), 'historical registry order changed')
                fresh = 0
                for name, entry in entries[result_key].items():
                    if name in before:
                        require(entry == dict(old['entries'][result_key][name], reused_from=baseline_name), 'inherited entry differs: ' + name)
                    else:
                        require('reused_from' not in entry, 'fresh entry incorrectly reused: ' + name)
                        require(name+'.log' in logs, 'fresh test log not sealed: ' + name)
                        fresh += 1
                        if registry_key == 'CASES':
                            new_primary.add(self.inside(self.package, after[name][2]))
                require(audit.get('fresh_cases' if registry_key == 'CASES' else 'fresh_integrations') == fresh, 'fresh count differs')
                summary['fresh_cases' if registry_key == 'CASES' else 'fresh_integrations'] = fresh
            require(new_primary, 'incremental layer adds no cases')
            require(set(paths[len(old['paths']):]) == new_primary, 'appended source set differs from new primary cases')
            summary['reuse_proof_sha256'] = self.sha(folder/'reuse_proof.json')
            summary['sealed_fresh_logs'] = len(logs)
        else:
            require(mode in (None, 'full', 'full_regression'), 'unsupported execution mode')
            require(audit.get('all_current_tested_inputs_match') is True, 'terminal full baseline lacks complete-input audit')
            require(not (folder/'reuse_proof.json').exists(), 'full baseline unexpectedly contains reuse proof')
            require(all('reused_from' not in e for group in entries.values() for e in group.values()), 'terminal full baseline contains reused results')
        return dict(body=body, bindings=bindings, table=table, paths=paths, entries=entries)

    def audit(self, head):
        source_hash = self.sha(Path(__file__).resolve())
        self.layer(head)
        manifest = self.package/'board/tang25k/acceptance48/FINAL_PRODUCTION_SOURCE_SHA256.json'
        production = self.json(manifest).get('files')
        require(isinstance(production, dict) and len(production) == 202, 'production baseline is not 202 files')
        normalized = set()
        for name, digest in production.items():
            path = self.inside(self.root, name)
            require(path not in normalized, 'duplicate production path')
            normalized.add(path)
            require(self.sha(path) == digest, 'production baseline changed: ' + name)
        for path, digest in self.observed.items():
            require(raw_sha(path) == digest, 'file changed before audit finished: ' + str(path))
        return dict(status='PASS', scope='Independent recursive provenance/hash audit only; no RTL simulation, synthesis, or board test rerun.',
                    generated_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                    checker_source=str(Path(__file__).resolve()), checker_source_sha256=source_hash,
                    head=str(Path(head).resolve().relative_to(self.root)), layers_checked=len(self.layers),
                    incremental_layers=sum(x['execution_mode']=='verified_incremental' for x in self.layers),
                    ancestry=self.layers, observed_files=len(self.observed), production_baseline_files_checked=202,
                    production_manifest_sha256=self.observed[manifest.resolve()], board_tested=False, rtl_tests_rerun=False)


def self_test():
    """Small synthetic three-layer chain. Never modifies formal evidence."""
    with tempfile.TemporaryDirectory(prefix='extension_ancestry_selftest_') as d:
        root = Path(d).resolve(); package = root/'pkg'; (package/'integration').mkdir(parents=True)
        runner = package/'integration/test_image_extensions.py'; source_list = package/'rtl_extension_sources.f'
        prod = package/'board/tang25k/acceptance48/FINAL_PRODUCTION_SOURCE_SHA256.json'; prod.parent.mkdir(parents=True)
        files = {}
        for i in range(202):
            p=root/'production'/str(i);p.parent.mkdir(exist_ok=True);p.write_text(str(i));files[str(p.relative_to(root))]=raw_sha(p)
        prod.write_text(json.dumps(dict(files=files)))
        def write(p, value):
            p.parent.mkdir(parents=True, exist_ok=True);p.write_text(json.dumps(value,indent=2))
        cases=[]; old_entries=[]; folders=[]
        for i in range(3):
            name='case'+str(i);folder=root/('layer'+str(i));folder.mkdir();folders.append(folder)
            script=package/'image'/name/'test.py';script.parent.mkdir(parents=True);script.write_text('pass\n')
            rtl=script.parent/'core.sv';rtl.write_text('module core'+str(i)+';endmodule\n')
            cases.append((name,str(script.relative_to(package)),str(rtl.relative_to(package))))
            runner.write_text('CASES='+repr(cases)+'\nINTEGRATIONS=[]\nINTEGRATION_INPUTS=()\n')
            source_list.write_text(''.join(str((package/s).relative_to(root)).replace('\\','/')+'\n' for _,_,s in cases))
            (folder/'runner_snapshot.py').write_bytes(runner.read_bytes());(folder/'source_list_snapshot.f').write_bytes(source_list.read_bytes())
            table={str(p.resolve()):raw_sha(p) for p in [runner,source_list]+[package/x for _,s,r in cases for x in (s,r)]}
            write(folder/'tested_input_sha256.json',table)
            entry=dict(name=name,source=cases[-1][2],status='PASS',board_tested=False,rtl_sha256=raw_sha(rtl))
            entries=([dict(e,reused_from=str(folders[i-1].relative_to(root))) for e in old_entries] if i else [])+[entry]
            result=dict(results=entries,integrations=[],source_bundle_compile=dict(status='PASS'),input_stability=dict(status='PASS',changed_files=[],tracked_file_count=len(table),sha256_record='tested_input_sha256.json'))
            audit=dict(status='PASS',projects=len(cases),integrations=0,source_files=len(cases),stable_inputs=len(table),production_baseline=202,board_tested=False)
            if i:
                result.update(execution_mode='verified_incremental',reuse_proof='reuse_proof.json');baseline=folders[i-1]
                proof=dict(baseline=str(baseline.relative_to(root)),baseline_results_sha256=raw_sha(baseline/'results.json'),baseline_audit_sha256=raw_sha(baseline/'checkpoint_audit.json'),baseline_inputs_sha256=raw_sha(baseline/'tested_input_sha256.json'),unchanged_baseline_inputs=len(read_json(baseline/'tested_input_sha256.json'))-2,registry_behavior_unchanged=True,source_list_append_only=True)
                write(folder/'reuse_proof.json',proof);(folder/(name+'.log')).write_text('PASS\n');(folder/'bundle_compile.log').write_text('PASS\n')
                audit.update(execution_mode='verified_incremental',reuse_proof_sha256=raw_sha(folder/'reuse_proof.json'),fresh_cases=1,fresh_integrations=0,fresh_logs_sha256={p.name:raw_sha(p) for p in folder.glob('*.log')})
            else:audit['all_current_tested_inputs_match']=True
            write(folder/'results.json',result);audit.update(original_results_sha256=raw_sha(folder/'results.json'),tested_input_record_sha256=raw_sha(folder/'tested_input_sha256.json'));write(folder/'checkpoint_audit.json',audit);old_entries=entries
        def check():return Checker(root,package).audit(folders[-1])
        require(check()['layers_checked']==3,'valid mock chain failed')
        passed=['valid_three_layer_chain']
        def rejected(label, mutate):
            backups={p:p.read_bytes() for p in root.rglob('*') if p.is_file()}
            mutate()
            try:check()
            except (AuditError, OSError, ValueError, KeyError):passed.append(label)
            else:raise AuditError('self-test unexpectedly accepted '+label)
            finally:
                for p,b in backups.items():p.write_bytes(b)
        head=folders[-1]
        def edit_json(path, callback):
            v=read_json(path);callback(v);write(path,v)
        rejected('proof_tamper',lambda:edit_json(head/'reuse_proof.json',lambda v:v.update(baseline_results_sha256='0'*64)))
        rejected('ancestor_result_tamper',lambda:edit_json(folders[0]/'results.json',lambda v:v['results'][0].update(extra='tamper')))
        def cycle():
            edit_json(head/'reuse_proof.json',lambda v:v.update(baseline=str(head.relative_to(root))))
            edit_json(head/'checkpoint_audit.json',lambda v:v.update(reuse_proof_sha256=raw_sha(head/'reuse_proof.json')))
        rejected('cycle_rejected',cycle)
        rejected('fresh_log_tamper',lambda:(head/'case2.log').write_text('changed\n'))
        rejected('ancestor_input_changed',lambda:(package/'image/case0/test.py').write_text('changed\n'))
        def wrong_inherited():
            edit_json(head/'results.json',lambda v:v['results'][0].update(reused_from='wrong-layer'))
            edit_json(head/'checkpoint_audit.json',lambda v:v.update(original_results_sha256=raw_sha(head/'results.json')))
        rejected('resealed_wrong_inherited_entry',wrong_inherited)
        require(check()['status']=='PASS','fixture restoration failed')
        return dict(status='PASS',checks=passed,temporary_fixtures_cleaned=True,rtl_tests_rerun=False,board_tested=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('head',nargs='?',type=Path)
    parser.add_argument('--self-test',action='store_true')
    args=parser.parse_args()
    if args.self_test:
        require(args.head is None,'--self-test does not accept a formal evidence folder')
        print(json.dumps(self_test(),indent=2));return 0
    require(args.head is not None,'head evidence folder is required')
    head=args.head.resolve();out=head/'ancestry_check.json'
    require(head.is_dir(),'head evidence folder does not exist')
    require(not out.exists(),'ancestry_check.json already exists; no existing report is overwritten')
    try:
        report=Checker().audit(head);code=0
    except (AuditError,OSError,ValueError,KeyError,TypeError,SyntaxError) as error:
        report=dict(status='FAIL',scope='Independent provenance audit only; no RTL or board rerun.',head=str(head),error=str(error),checker_source=str(Path(__file__).resolve()),checker_source_sha256=raw_sha(__file__),board_tested=False,rtl_tests_rerun=False);code=1
    with out.open('x',encoding='utf-8') as f:json.dump(report,f,indent=2);f.write('\n')
    print(json.dumps(report,indent=2));return code


if __name__=='__main__':
    raise SystemExit(main())
