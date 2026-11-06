"""SPDX-License-Identifier: Apache-2.0. B37 explicit two-child TB repair only.

Imports only the original runner's bounded process helper and hash function.
No prepare/oracle function is called; the already archived vectors are copied.
"""
from pathlib import Path
import datetime, difflib, json, os, re, sys, traceback
from run_tests import execute, sha

ROOT = Path(__file__).resolve().parent
BIN = ROOT.parents[2] / 'tools/oss-cad-suite/oss-cad-suite/bin'
PLAN = ROOT / 'REPAIR01_PLAN.json'


def main():
    if sys.argv[1:] != ['--execute-approved-repair01-plan']:
        raise SystemExit('Root review and --execute-approved-repair01-plan required')
    report_root = ROOT / 'repairs/repair01/reports'
    if report_root.exists() and any(report_root.iterdir()):
        raise SystemExit('Existing repair report entry: no automatic retry')
    plan = json.loads(PLAN.read_text())
    expected = ['repair01_compile_example', 'repair01_sim_example']
    if plan['expected_checks'] != expected or plan['numerical_preparation_calls'] != 0:
        raise SystemExit('Plan is not the bounded two-child, zero-preparation repair')
    sources = [entry['current_path'] for entry in plan['source_mappings']]
    if len(sources) != 13 or len(set(sources)) != 13:
        raise SystemExit('Unexpected executable input closure')
    for entry in plan['source_mappings']:
        if entry['current_sha256'] is not None and sha(ROOT / entry['current_path']) != entry['current_sha256']:
            raise SystemExit('Current source does not match reviewed plan: ' + entry['current_path'])

    def old_evidence_audit():
        return [dict(path=entry['path'], expected_sha256=entry['sha256'],
                     actual_sha256=sha(ROOT / entry['path']),
                     unchanged=sha(ROOT / entry['path']) == entry['sha256'])
                for entry in plan['immutable_first_attempt_evidence']]

    audit_before = old_evidence_audit()
    if not all(entry['unchanged'] for entry in audit_before):
        raise SystemExit('First attempt evidence changed; no repair child launched')
    original = ROOT / plan['tb_change']['old_archive']
    current = ROOT / plan['tb_change']['current_path']
    diff = ''.join(difflib.unified_diff(original.read_text().splitlines(True),
        current.read_text().splitlines(True), fromfile='first_attempt_tb', tofile='repair01_tb'))
    if diff != plan['tb_change']['unified_diff']:
        raise SystemExit('TB diff is not the reviewed limited change')
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report = report_root / stamp
    report.mkdir(parents=True, exist_ok=False)
    build = ROOT / '.build/repair01' / stamp
    build.mkdir(parents=True, exist_ok=False)
    result = dict(schema='anscore-b37-repeated-half-sync-repair01-finite-v1', utc=stamp,
        baseline=plan['baseline'], status='INCOMPLETE', checks=[], expected_checks=expected,
        source_sha256={p: sha(ROOT / p) for p in sources}, archive_complete=False,
        first_attempt=plan['first_attempt'], old_evidence_before=audit_before,
        numerical_preparation_calls=0, vectors_copied=False, suite_complete=False,
        automatic_retry=False, active_child=None, phase='SOURCE_ARCHIVE',
        hardware='HW_UNVERIFIED', synthesis='NOT_RUN', pnr='NOT_RUN', sta='NOT_RUN', board='NOT_RUN',
        rerun_guard='refuse_any_existing_repair_report_entry')

    def persist():
        temporary = report / 'results.json.tmp'
        with temporary.open('w', encoding='utf-8', newline='\n') as handle:
            json.dump(result, handle, indent=2)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(report / 'results.json')

    persist()
    stopped = False

    def run(name, argv, marker=None):
        nonlocal stopped
        result.update(phase='HDL_CHILD', active_child=name)
        persist()
        rec = execute(name, argv, ROOT, env, report, marker)
        result['checks'].append(rec)
        result['active_child'] = None
        stopped = rec['status'] != 'PASS'
        if stopped:
            result['status'] = rec['status']
        persist()
        print(name, rec['status'], flush=True)
        return not stopped

    try:
        for entry in plan['source_mappings']:
            target = report / entry['repair_archive_relative']
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / entry['current_path']).read_bytes())
        result['archive_complete'] = True
        persist()
        vector_spec = plan['vector_reuse']
        vector = report / 'vectors3.txt'
        vector.write_bytes((ROOT / vector_spec['first_attempt_path']).read_bytes())
        if sha(vector) != vector_spec['sha256']:
            raise RuntimeError('Exact archived vector copy mismatch')
        result.update(vectors_copied=True, vectors_sha256=sha(vector))
        persist()
        iv, vvp = BIN / 'iverilog.exe', BIN / 'vvp.exe'
        result['tools'] = {str(p): sha(p) for p in [iv, vvp] if p.is_file()}
        env = dict(os.environ)
        env['PATH'] = str(BIN) + os.pathsep + str(BIN.parent / 'lib') + os.pathsep + env.get('PATH', '')
        image = build / 'repair01_example.vvp'
        params = ['-Ptb_repeated_half_sync.%s=%d' % (k, v) for k, v in
                  zip(('D', 'L', 'M', 'T', 'EX'), (12, 16, 1024, 8, 1))]
        if not run(expected[0], [iv, '-g2012', '-Wall', '-s', 'tb_repeated_half_sync',
            *params, '-o', image, '-f', 'example/files.f', 'sim/tb_repeated_half_sync.sv']):
            return 1
        result['artifact'] = dict(path=image.relative_to(ROOT).as_posix(), sha256=sha(image), bytes=image.stat().st_size)
        persist()
        marker = b'PASS repeated_half_sync D=12 L=16 M=1024 T=8 EX=1 '
        if not run(expected[1], [vvp, image, '+vectors=' + vector.as_posix()], marker):
            return 1
        line = next(line for line in (report / (expected[1] + '.stdout.txt')).read_text().splitlines()
                    if line.startswith(marker.decode()))
        result['observed'] = {key: int(value) for key, value in re.findall(r'(\w+)=(\d+)', line)}
        result.update(suite_complete=True, status='PASS')
        return 0
    except Exception:
        result.update(status='REPAIR_RUNNER_FAILED', exception=traceback.format_exc())
        raise
    finally:
        unchanged = all(sha(ROOT / p) == digest for p, digest in result['source_sha256'].items())
        archived = all(sha(report / entry['repair_archive_relative']) == result['source_sha256'][entry['current_path']]
                       for entry in plan['source_mappings']) if result['archive_complete'] else False
        vector_unchanged = result['vectors_copied'] and sha(report / 'vectors3.txt') == plan['vector_reuse']['sha256']
        audit_after = old_evidence_audit()
        old_unchanged = all(entry['unchanged'] for entry in audit_after)
        final_expected = json.loads(PLAN.read_text())['expected_checks']
        archived_expected = json.loads((report / 'sources/REPAIR01_PLAN.json').read_text())['expected_checks'] if archived else []
        sequence_matches = [check['name'] for check in result['checks']] == expected == final_expected == archived_expected
        result.update(sources_unchanged=unchanged, archive_unchanged=archived, vectors_unchanged=vector_unchanged,
            old_evidence_after=audit_after, first_attempt_evidence_unchanged=old_unchanged,
            expected_checks_from_final_plan=final_expected, expected_checks_from_archived_plan=archived_expected,
            check_sequence_matches=sequence_matches)
        if not (unchanged and archived and vector_unchanged and old_unchanged):
            result['status'] = 'SOURCE_OR_EVIDENCE_CHANGED'
        elif stopped:
            result['status'] = result['checks'][-1]['status']
        elif result['status'] == 'PASS' and not (result['suite_complete'] and sequence_matches):
            result['status'] = 'INCOMPLETE'
        result['maturity'] = ['LINT_PASS', 'UNIT_SIM_PASS', 'INTEGRATION_CANDIDATE', 'HW_UNVERIFIED'] if result['status'] == 'PASS' else ['RTL_CANDIDATE', 'HW_UNVERIFIED']
        result['phase'] = 'COMPLETE' if result['status'] == 'PASS' else 'STOPPED'
        persist()
        print('Repair evidence:', report.relative_to(ROOT), flush=True)
        if not (unchanged and archived and vector_unchanged and old_unchanged):
            raise RuntimeError('Executed input or immutable first-attempt evidence changed')


if __name__ == '__main__':
    sys.exit(main())
