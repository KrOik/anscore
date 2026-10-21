"""Adversarial control fixtures, not substitutes for RTL execution."""
import contextlib
import io
import json
import shutil
import tempfile
from pathlib import Path
from unittest.mock import patch

import test_extension_batch as batch


def check(baseline):
    checks = []
    real_snapshot = batch.tracked_inputs
    old = batch.read(baseline/'tested_input_sha256.json')
    victim = next(n for n in old if n.endswith('tooling.py'))
    with tempfile.TemporaryDirectory(prefix='extension_guard_', dir=batch.PACKAGE/'integration') as tmp:
        tmp = Path(tmp)
        for mode in ('unsealed_table', 'snapshot_race', 'imported_registry_mismatch',
                     'imported_integration_inputs_mismatch', 'added_input', 'removed_input',
                     'modified_input', 'baseline_record_race', 'stable_control'):
            base = tmp/mode/'baseline'
            base.mkdir(parents=True)
            for name in ('results.json', 'checkpoint_audit.json', 'tested_input_sha256.json',
                         'runner_snapshot.py', 'source_list_snapshot.f'):
                shutil.copyfile(baseline/name, base/name)
            calls = [0]
            executed = [False]
            audited = [False]
            def snapshots(source_list):
                calls[0] += 1
                current = real_snapshot(source_list)
                if mode == 'snapshot_race':
                    current[victim] = '0'*64
                if calls[0] == 2:
                    if mode == 'added_input':
                        current[str(tmp/'new_helper.py')] = '1'*64
                    elif mode == 'removed_input':
                        del current[victim]
                    elif mode == 'modified_input':
                        current[victim] = '2'*64
                return current
            def execute(*args, **kwargs):
                if mode == 'baseline_record_race' and not executed[0]:
                    table = base/'tested_input_sha256.json'
                    table.write_bytes(table.read_bytes()+b'\n')
                executed[0] = True
            def audit(folder):
                audited[0] = True
            if mode == 'unsealed_table':
                table = batch.read(base/'tested_input_sha256.json')
                table[victim] = '3'*64
                batch.write_json(base/'tested_input_sha256.json', table)
            folder = tmp/mode/'output'
            folder.mkdir()
            with contextlib.redirect_stdout(io.StringIO()), \
                 patch.object(batch.registry, 'CASES', batch.registry.CASES[:-1] if mode == 'imported_registry_mismatch' else batch.registry.CASES), \
                 patch.object(batch.registry, 'INTEGRATION_INPUTS', () if mode == 'imported_integration_inputs_mismatch' else batch.registry.INTEGRATION_INPUTS), \
                 patch.object(batch, 'evidence_dir', return_value=folder), \
                 patch.object(batch, 'tracked_inputs', side_effect=snapshots), \
                 patch.object(batch, 'execute', side_effect=execute), \
                 patch.object(batch, 'audit_incremental', side_effect=audit):
                try:
                    rc = batch.run(base)
                except RuntimeError as error:
                    assert mode in ('unsealed_table', 'snapshot_race', 'imported_registry_mismatch', 'imported_integration_inputs_mismatch'), (mode, str(error))
                    assert not executed[0] and not audited[0]
                    expected = {'unsealed_table':'not sealed', 'snapshot_race':'between preflight and snapshot',
                                'imported_registry_mismatch':'registries differ from disk',
                                'imported_integration_inputs_mismatch':'integration inputs differ from disk'}[mode]
                    assert expected in str(error), (mode, str(error))
                else:
                    assert mode not in ('unsealed_table', 'snapshot_race', 'imported_registry_mismatch', 'imported_integration_inputs_mismatch'), mode
                    result = batch.read(folder/'results.json')
                    if mode == 'stable_control':
                        assert rc == 0 and audited[0] and result['input_stability']['status'] == 'PASS'
                    else:
                        assert rc == 1 and not audited[0] and result['input_stability']['status'] == 'FAIL'
                        assert result['input_stability']['changed_files'], mode
            checks.append(mode)
    return dict(status='PASS', scope='mocked guard logic only; no RTL tests or reused evidence generated', checks=checks)


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('baseline', type=Path)
    args = parser.parse_args()
    print(json.dumps(check(args.baseline.resolve()), indent=2))
