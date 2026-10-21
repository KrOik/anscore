"""Read-only source/resource audit of the TIFF/CSI incremental checkpoint."""
import argparse
import hashlib
import json
import re
import tempfile
from pathlib import Path

from tooling import PACKAGE, write_json


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(value, message):
    if not value:
        raise RuntimeError(message)


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


GROUPS = (
    ('tiff_encoder', 'freeze_hashes.json', ('evidence.json', 'protocol_evidence.json',
     'parameter_evidence.json', 'synthesis.json')),
    ('tiff_decoder', 'source_freeze.json', ('evidence.json', 'errors_evidence.json',
     'protocol_evidence.json', 'numeric_evidence.json', 'synthesis.json')),
    ('csi2_packet_tx', 'FINAL_SOURCE_SHA256.json', ('main_evidence.json',
     'protocol_evidence.json', 'synthesis.json')),
)


def audit(folder):
    frozen = {}
    reports = {}
    profiles = []
    for name, freeze_name, report_names in GROUPS:
        base = PACKAGE/'image'/name
        freeze = read(base/freeze_name)
        require(freeze, name+': empty source freeze')
        for relative, digest in freeze.items():
            path = (base/relative).resolve()
            require(path.is_relative_to(base.resolve()), 'freeze path escapes owner')
            require(sha(path) == digest, 'owner freeze mismatch: '+str(path))
            frozen[str(path)] = digest
        reports[str(base/freeze_name)] = sha(base/freeze_name)
        rtl_digest = sha(base/(name+'.sv'))
        for report_name in report_names:
            path = base/report_name
            report = read(path)
            require(report.get('status') == 'PASS', 'report did not pass: '+str(path))
            bound = report.get('rtl_sha256', report.get('source_sha256'))
            if bound is None:
                bound = report.get('sources', {}).get(name+'.sv')
            require(bound == rtl_digest, 'report source binding mismatch: '+str(path))
            reports[str(path)] = sha(path)
        synth = read(base/'synthesis.json')
        for row in synth['profiles']:
            log_name = ('synthesis_0.log' if name == 'csi2_packet_tx' else
                        'synthesis_'+str(row['width'])+'x'+str(row['height'])+'.log')
            log = base/log_name
            text = log.read_text(encoding='utf-8')
            require('Found and reported 0 problems.' in text, 'missing synthesis check')
            marker = '=== '+name+' ==='
            require(marker in text, 'missing module statistics')
            cells = {k: int(v) for v, k in re.findall(
                r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$', text[text.rfind(marker):], re.M)}
            require(cells == row['cells'], name+': log/report cells mismatch')
            lut = sum(v for k, v in cells.items() if k.startswith(('LUT', 'ALU', 'MUX')))
            lut += 4*cells.get('RAM16SDP4', 0)
            dsp = sum(v for k, v in cells.items() if 'MULT' in k or 'DSP' in k)
            bram = 2*sum(v for k, v in cells.items() if k in (
                'DPB', 'DPX9B', 'SDPB', 'SDPX9B', 'SP', 'SPX9', 'ROM', 'ROMX9'))
            require(lut == row.get('lut_class', row.get('lut_class_including_lutram')),
                    name+': LUT accounting mismatch')
            require(dsp == row['dsp'] and bram == row.get('bram9', row.get('conservative_bram9_units')),
                    name+': DSP/BRAM accounting mismatch')
            require(lut <= 15000 and dsp <= 4 and bram <= 46, 'isolated budget exceeded')
            if 'report_sha256' in row:
                require(row['report_sha256'] == sha(log), 'synthesis log binding mismatch')
            reports[str(log)] = sha(log)
            profiles.append(dict(group=name, width=row.get('width'), height=row.get('height'),
                                 lut_class=lut, dsp=dsp, conservative_bram9_units=bram))
    write_json(folder/'resource_audit.json', dict(status='PASS', isolated_profiles=profiles,
               owner_frozen_inputs=frozen, source_bound_reports=reports,
               scope='Isolated synthesis and offline regressions; no combined P&R or board claim'))
    return frozen


def finalize(folder, frozen):
    peer = PACKAGE/'image/tiff_decoder/peer_review_new_codecs.json'
    review = read(peer)
    require(review['status'] == 'PASS' and not review['findings'], 'peer findings')
    for row in review['cores']:
        for name, digest in row['evidence'].items():
            require(sha(PACKAGE/'image'/row['core']/name) == digest, 'peer evidence '+name)
    write_json(folder/'peer_review.json', dict(status='PASS', external_review=str(peer),
        external_review_sha256=sha(peer), findings=[],
        decoder_review='Encoder agent reviewed synchronous RAM, II/MM parsing, strip ranges, CE/stalls, 10 frozen inputs and five bound reports: PASS',
        integration_review='Root inspected actual RTL connections, independent pixel/byte/ECC/CRC oracles and independent external TIFF readers'))
    prefixes = {'tiff_codec_chain_', 'csi2_tx_rx_', 'tiff_decoder_refs_'}
    for group, _, _ in GROUPS:
        for path in (PACKAGE/'image'/group).glob('*.py'):
            prefixes.update(re.findall(r'''prefix=['"]([^'"]+)''', path.read_text()))
    residual = [str(p) for p in Path(tempfile.gettempdir()).iterdir()
                if any(p.name.startswith(n) for n in prefixes)]
    require(not residual, 'task temporary products remain: '+str(residual))
    for group, _, _ in GROUPS:
        require(not any(p.suffix in ('.vvp', '.fs', '.tif', '.tiff')
                        for p in (PACKAGE/'image'/group).rglob('*')), 'generated binary in source')
    write_json(folder/'cleanup_check.json', dict(status='PASS',
        temp_prefixes_checked=sorted(prefixes), residual=[],
        policy='Baseline artifacts and small evidence retained; task binaries and images absent'))
    tested = read(folder/'tested_input_sha256.json')
    for name, digest in {**tested, **frozen}.items():
        require(sha(Path(name)) == digest, 'source changed: '+name)
    for name in ('checkpoint_audit.json', 'ancestry_check.json'):
        require(read(folder/name)['status'] == 'PASS', name+' did not pass')
    results = read(folder/'results.json')
    require(all(e['status'] == 'PASS' for e in results['results']+results['integrations']),
            'regression failure')
    require(results['input_stability']['status'] == 'PASS' and
            results['source_bundle_compile']['status'] == 'PASS', 'compile or stability failure')
    seals = {name: sha(folder/name) for name in ('results.json', 'tested_input_sha256.json',
        'checkpoint_audit.json', 'ancestry_check.json', 'resource_audit.json',
        'peer_review.json', 'cleanup_check.json')}
    extra = [Path(__file__).resolve(), PACKAGE/'IMAGE_EXTENSIONS.md']
    write_json(folder/'final_readonly_check.json', dict(status='PASS',
        tracked_inputs_checked=len(tested), owner_frozen_inputs_checked=len(frozen),
        sealed_reports=seals, additional_input_sha256={str(p): sha(p) for p in extra},
        board_tested=False))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--finalize', action='store_true')
    args = parser.parse_args()
    folder = args.checkpoint.resolve()
    frozen = audit(folder)
    if args.finalize:
        finalize(folder, frozen)
    print('RESOURCE_AND_SOURCE_AUDIT_PASS')
