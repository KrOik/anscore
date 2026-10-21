"""Audit frozen video I/O sources and recompute isolated cell budgets from logs."""
import argparse
import hashlib
import json
import re
import tempfile
from pathlib import Path
from tooling import PACKAGE, write_json


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def audit(folder):
    groups = (('bt656_tx', 'FINAL_SOURCE_SHA256.json'),
              ('axi_video_bridge', 'source_freeze.json'), ('dvp_rx', 'source_freeze.json'))
    frozen = {}
    reports = {}
    profiles = []
    for group, freeze_name in groups:
        base = PACKAGE/'image'/group
        freeze = read(base/freeze_name)
        sources = {n: h for n, h in freeze.items() if n.endswith(('.sv', '.v'))}
        require(sources, group+': no RTL freeze')
        for name, digest in freeze.items():
            path = (base/name).resolve()
            require(path.is_relative_to(base.resolve()), 'freeze escapes owner')
            require(sha(path) == digest, 'freeze mismatch: '+str(path))
            frozen[str(path)] = digest
        reports[str(base/freeze_name)] = sha(base/freeze_name)
        evidence = [p for p in base.glob('*.json') if p.name.endswith('evidence.json')
                    or p.name == 'synthesis.json']
        require(len(evidence) >= 4, 'missing evidence: '+group)
        for path in evidence:
            report = read(path)
            require(report.get('status') == 'PASS', 'non-PASS report: '+str(path))
            bound = report.get('sources')
            if bound is not None:
                require(all(bound.get(n) == h for n, h in sources.items()), 'source bindings: '+str(path))
            else:
                require(len(sources) == 1 and report.get('source_sha256', report.get('rtl_sha256'))
                        == next(iter(sources.values())), 'source binding: '+str(path))
            reports[str(path)] = sha(path)
        synth = read(base/'synthesis.json')
        for row in synth['profiles']:
            module = row.get('module', row.get('top', group))
            marker = '=== '+module+' ==='
            matches = []
            for log in base.glob('synthesis*.log'):
                text = log.read_text(encoding='utf-8')
                if marker not in text or 'Found and reported 0 problems.' not in text:
                    continue
                cells = {k: int(v) for v, k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',
                         text[text.rfind(marker):], re.M)}
                if cells != row['cells']:
                    continue
                if row.get('report_sha256') and sha(log) != row['report_sha256']:
                    continue
                matches.append(log)
            require(matches, group+': no matching final log cell table')
            cells = row['cells']
            lut = sum(v for k, v in cells.items() if k.startswith(('LUT', 'ALU', 'MUX')))
            lut += 4*cells.get('RAM16SDP4', 0)
            dsp = sum(v for k, v in cells.items() if 'MULT' in k or 'DSP' in k)
            bram = 2*sum(v for k, v in cells.items() if k in
                        ('SP', 'SPX9', 'DPB', 'DPX9B', 'SDPB', 'SDPX9B', 'ROM', 'ROMX9'))
            require(lut == row.get('lut_class', row.get('lut_class_including_lutram')) and
                    dsp == row['dsp'] and bram == row.get('bram9', row.get('conservative_bram9_units')),
                    group+': resource total mismatch')
            require(lut <= 15000 and dsp <= 4 and bram <= 46, 'isolated resource budget exceeded')
            for log in matches:
                reports[str(log)] = sha(log)
            profiles.append(dict(group=group, module=module, lut_class=lut, dsp=dsp,
                                 conservative_bram9_units=bram,
                                 profile={k: v for k, v in row.items() if k not in ('cells',)}))
    write_json(folder/'resource_audit.json', dict(status='PASS', isolated_profiles=profiles,
               owner_frozen_inputs=frozen, source_bound_reports=reports,
               scope='Isolated synthesis only; no combined-device fit, route, electrical or board claim'))
    return frozen


def finalize(folder, frozen):
    peers = [PACKAGE/'image/axi_video_bridge/peer_review_bt656.json',
             PACKAGE/'image/bt656_tx/peer_review.json']
    for path in peers:
        require(read(path)['status'] == 'PASS', 'peer review not PASS: '+str(path))
    require(read(peers[0])['rtl_sha256'] == sha(PACKAGE/'image/bt656_tx/bt656_tx.sv'),
            'BT.656 peer source mismatch')
    bridge_review = read(peers[1])['axi_video_bridge']
    require(bridge_review['source_freeze_sha256'] == sha(PACKAGE/'image/axi_video_bridge/source_freeze.json'),
            'AXI bridge peer source mismatch')
    dvp_review = read(peers[1]).get('dvp_rx', {})
    require(dvp_review.get('status') == 'PASS', 'DVP peer review pending')
    require(dvp_review.get('rtl_sha256', dvp_review.get('sources', {}).get('dvp_rx.sv')) ==
            sha(PACKAGE/'image/dvp_rx/dvp_rx.sv'), 'DVP peer source mismatch')
    write_json(folder/'peer_review.json', dict(status='PASS',
               review_files_sha256={str(p): sha(p) for p in peers}, findings=[],
               scope='Independent read-only code, oracle, freeze and resource review; no board claim'))
    prefixes = {'bt656_tx_rx_yuv_', 'dvp_axi_video_'}
    groups = ('bt656_tx', 'axi_video_bridge', 'dvp_rx')
    for group in groups:
        for path in (PACKAGE/'image'/group).glob('*.py'):
            prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''', path.read_text()))
    remaining = [str(p) for p in Path(tempfile.gettempdir()).iterdir()
                 if any(p.name.startswith(n) for n in prefixes)]
    require(not remaining, 'task temporary products remain: '+str(remaining))
    for group in groups:
        require(not any(p.suffix in ('.vvp', '.fs', '.bin')
                        for p in (PACKAGE/'image'/group).rglob('*')), 'binary remains in source')
    write_json(folder/'cleanup_check.json', dict(status='PASS',
               checked_temp_prefixes=sorted(prefixes), remaining=[],
               policy='Preserve baseline artifacts and small logs; no task-generated temporary binaries remain'))
    tracked = read(folder/'tested_input_sha256.json')
    resource = read(folder/'resource_audit.json')
    for name, digest in {**tracked, **frozen, **resource['source_bound_reports']}.items():
        require(sha(Path(name)) == digest, 'final source/report changed: '+name)
    for name in ('checkpoint_audit.json', 'ancestry_check.json'):
        require(read(folder/name)['status'] == 'PASS', 'audit not PASS: '+name)
    result = read(folder/'results.json')
    require(all(e['status'] == 'PASS' for e in result['results']+result['integrations']), 'regression failure')
    require(result['source_bundle_compile']['status'] == 'PASS' and
            result['input_stability']['status'] == 'PASS', 'compile/stability failure')
    seals = {n: sha(folder/n) for n in ('results.json', 'tested_input_sha256.json',
             'checkpoint_audit.json', 'ancestry_check.json', 'resource_audit.json',
             'peer_review.json', 'cleanup_check.json')}
    extras = [Path(__file__).resolve(), PACKAGE/'IMAGE_EXTENSIONS.md']
    write_json(folder/'final_readonly_check.json', dict(status='PASS',
               tracked_inputs_checked=len(tracked), owner_frozen_inputs_checked=len(frozen),
               sealed_reports=seals, additional_input_sha256={str(p): sha(p) for p in extras},
               board_tested=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--finalize', action='store_true')
    args = parser.parse_args()
    frozen = audit(args.checkpoint.resolve())
    if args.finalize:
        finalize(args.checkpoint.resolve(), frozen)
    print('VIDEO_IO_RESOURCE_AUDIT_PASS', len(frozen))
