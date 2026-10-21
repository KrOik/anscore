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


GROUPS = ('image/tmds_codec', 'peripherals/ps2_host', 'peripherals/lcd8080')

def audit(folder):
    groups = tuple((g, 'source_freeze.json') for g in GROUPS)
    frozen = {}
    reports = {}
    profiles = []
    for group, freeze_name in groups:
        base = PACKAGE/group
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
            module = row.get('module', row.get('top', Path(group).name))
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
    peer_targets = (
        ('image/tmds_codec/peer_review_ps2.json', 'peripherals/ps2_host'),
        ('peripherals/ps2_host/peer_review_lcd8080.json', 'peripherals/lcd8080'),
        ('peripherals/lcd8080/peer_review_tmds.json', 'image/tmds_codec'))
    peers = [PACKAGE/p for p, _ in peer_targets]
    for (name, target), path in zip(peer_targets, peers):
        report = read(path)
        require(report['status'] == 'PASS', 'peer review not PASS: '+name)
        require(report.get('source_freeze_sha256') == sha(PACKAGE/target/'source_freeze.json'),
                'peer source freeze binding: '+name)
    write_json(folder/'peer_review.json', dict(status='PASS',
               review_files_sha256={str(p): sha(p) for p in peers}, findings=[],
               scope='Independent read-only code, oracle, freeze and resource review; no board claim'))
    prefixes = {'raster_tmds_rgb_', 'video_timing_'}
    groups = GROUPS
    for group in groups:
        for path in (PACKAGE/group).glob('*.py'):
            prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''', path.read_text()))
    remaining = [str(p) for p in Path(tempfile.gettempdir()).iterdir()
                 if any(p.name.startswith(n) for n in prefixes)]
    known_blocked = Path('C:/Users/29668/AppData/Local/Temp/video_timing_rqk_g4l1')
    unexpected = [n for n in remaining if Path(n).resolve() != known_blocked.resolve()]
    require(not unexpected, 'unaccounted task temporary products remain: '+str(unexpected))
    if remaining:
        require(sum(p.stat().st_size for p in known_blocked.rglob('*') if p.is_file()) == 44509,
                'blocked cleanup directory changed')
    for group in groups:
        require(not any(p.suffix in ('.vvp', '.fs', '.bin')
                        for p in (PACKAGE/group).rglob('*')), 'binary remains in source')
    write_json(folder/'cleanup_check.json', dict(status='BLOCKED_POLICY' if remaining else 'PASS',
               checked_temp_prefixes=sorted(prefixes), remaining=remaining,
               reason='Automatic tool policy rejected precise removal: blocked by policy' if remaining else None,
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
    write_json(folder/'final_readonly_check.json', dict(status='PASS_WITH_CLEANUP_EXCEPTION' if remaining else 'PASS',
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
    print('DISPLAY_PERIPHERAL_RESOURCE_AUDIT_PASS', len(frozen))
