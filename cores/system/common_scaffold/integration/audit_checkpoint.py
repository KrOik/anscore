"""Audit a completed extension regression against current frozen inputs."""
import argparse
import hashlib
import json
from pathlib import Path

from tooling import ROOT, PACKAGE, write_json
from test_image_extensions import CASES, INTEGRATIONS


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def audit(folder):
    result = read(folder/'results.json')
    cases, integrations = result['results'], result['integrations']
    assert cases and len({c['name'] for c in cases}) == len(cases), 'case coverage'
    assert len({c['name'] for c in integrations}) == len(integrations), 'integration coverage'
    assert {(c['name'], c['source']) for c in cases} == {(n, s) for n, _, s in CASES}, 'current case registry differs'
    assert {c['name'] for c in integrations} == {n for n, _, _ in INTEGRATIONS}, 'current integration registry differs'
    assert all(c['status'] == 'PASS' for c in cases+integrations), 'failed case'
    assert result['source_bundle_compile']['status'] == 'PASS', 'bundle'
    assert result['input_stability']['status'] == 'PASS', 'unstable inputs'
    tested = read(folder/'tested_input_sha256.json')
    from test_image_extensions import collect_inputs
    assert tested == collect_inputs(), 'current complete input closure differs'
    assert len(tested) == result['input_stability']['tracked_file_count'], 'input count'
    assert all(sha(Path(n)) == h for n, h in tested.items()), 'current input differs'
    baseline = read(PACKAGE/'board/tang25k/acceptance48/FINAL_PRODUCTION_SOURCE_SHA256.json')['files']
    assert len(baseline) == 202, 'baseline count'
    assert all(sha(ROOT/n) == h for n, h in baseline.items()), 'production changed'
    paths = [ROOT/line.strip() for line in (PACKAGE/'rtl_extension_sources.f').read_text(encoding='utf-8').splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    assert len(paths) == len(set(paths)), 'duplicate RTL source'
    assert all(str(p.resolve()) in tested for p in paths), 'untracked RTL'
    assert all(sha(PACKAGE/c['source']) == c['rtl_sha256'] for c in cases), 'case RTL hash'
    write_json(folder/'integrated_source_sha256.json', {str(p.relative_to(ROOT)):sha(p) for p in paths})
    write_json(folder/'production_baseline_check.json', {'status':'PASS','files_checked':len(baseline),'all_unchanged':True})
    report = dict(status='PASS', projects=len(cases), integrations=len(integrations),
                  source_files=len(paths), stable_inputs=len(tested), production_baseline=len(baseline),
                  original_results_sha256=sha(folder/'results.json'),
                  tested_input_record_sha256=sha(folder/'tested_input_sha256.json'),
                  all_current_tested_inputs_match=True, board_tested=False)
    write_json(folder/'checkpoint_audit.json', report)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    audit(parser.parse_args().folder.resolve())
