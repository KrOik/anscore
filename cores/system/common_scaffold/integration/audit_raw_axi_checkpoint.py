"""Read-only RAW14 / AXI checkpoint audit; fixed-format profiles are intentional."""
import argparse
import re
import tempfile
from pathlib import Path
from tooling import PACKAGE, write_json, execute
from audit_common_peripheral_checkpoint import sha, read, require


GROUPS = {
    'image/raw14_codec': ('synthesis.json', {'raw14_pack': 1, 'raw14_unpack': 1},
        ('evidence.json', 'protocol_evidence.json', 'roundtrip_evidence.json',
         'parameter_evidence.json', 'control_evidence.json')),
    'stream_bus/axi_multi_crossbar': ('synthesis_evidence.json', {'axi_multi_crossbar': 2},
        ('protocol_evidence.json',)),
}


def resources(cells):
    dsp_cell = lambda k: 'MULT' in k or 'DSP' in k or k in {'ALU54D', 'PADD9', 'PADD18'}
    lut = sum(v for k, v in cells.items() if k.startswith(('LUT', 'ALU', 'MUX')) and not dsp_cell(k))
    lut += 4*cells.get('RAM16SDP4', 0)
    dsp = sum(v for k, v in cells.items() if dsp_cell(k))
    bram = 2*sum(v for k, v in cells.items() if k in
                 {'SP', 'SPX9', 'DPB', 'DPX9B', 'SDPB', 'SDPX9B', 'ROM', 'ROMX9'})
    return lut, dsp, bram


def synthesize_axi(folder):
    rtl = PACKAGE/'stream_bus/axi_multi_crossbar/axi_multi_crossbar.sv'
    for name, m, t, w, i in [('default', 2, 2, 32, 4), ('maximum', 4, 4, 64, 8)]:
        log = folder/('axi_full_synthesis_'+name+'.log')
        require(not log.exists(), 'independent synthesis log already exists')
        with tempfile.TemporaryDirectory(prefix='raw_axi_audit_') as td:
            script = Path(td)/'run.ys'
            script.write_text(f'read_verilog -sv {rtl.as_posix()}\nchparam -set MASTERS {m} -set TARGETS {t} -set DATA_WIDTH {w} -set ID_WIDTH {i} axi_multi_crossbar\nsynth_gowin -top axi_multi_crossbar -nodsp\ncheck -assert\nstat\n', encoding='utf-8')
            execute(['yosys', '-s', script], Path(td), log, timeout=600)


def audit(folder):
    frozen, reports, profiles, peers = {}, {}, [], {}
    for group, (synth_name, expected, evidence) in GROUPS.items():
        base = PACKAGE/group
        freeze = read(base/'source_freeze.json')
        rtl = {n: h for n, h in freeze.items() if n.endswith(('.v', '.sv'))}
        require(rtl, 'no RTL inputs')
        for name, digest in freeze.items():
            path = (base/name).resolve()
            require(path.is_relative_to(base.resolve()) and sha(path) == digest, 'freeze mismatch: '+name)
            frozen[str(path)] = digest
        reports[str(base/'source_freeze.json')] = sha(base/'source_freeze.json')
        for name in (*evidence, synth_name):
            path = base/name
            obj = read(path)
            if group.startswith('image/'):
                require(obj['status'] == 'PASS' and obj['sources'] == rtl, 'RAW14 evidence binding: '+name)
            else:
                require(obj['rtl_sha256'] == rtl['axi_multi_crossbar.sv'], 'AXI evidence source binding')
                rows = obj.get('results', obj.get('profiles', []))
                require(rows and all(r['status'] == 'PASS' for r in rows), 'AXI profile failure')
            reports[str(path)] = sha(path)
        synth = read(base/synth_name)
        rows = synth.get('profiles', synth.get('results'))
        counts = {}
        for row in rows:
            module = row.get('module', 'axi_multi_crossbar')
            counts[module] = counts.get(module, 0)+1
            log = base/('synthesis_'+(row['profile'] if 'profile' in row else module)+'.log')
            if group.startswith('stream_bus/'):
                # Owner retained only the final stat table. Independently retain a
                # full check -assert log rather than infer a check result from it.
                reports[str(log)] = sha(log)
                log = folder/('axi_full_synthesis_'+row['profile']+'.log')
            text = log.read_text(encoding='utf-8')
            marker = '=== '+module+' ==='
            require(marker in text and 'Found and reported 0 problems.' in text, 'synthesis check missing')
            cells = {k: int(v) for v, k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$', text[text.rfind(marker):], re.M)}
            require(cells == row['cells'], 'synthesis cell table mismatch')
            if 'report_sha256' in row:
                require(sha(log) == row['report_sha256'], 'synthesis log hash mismatch')
            lut, dsp, bram = resources(cells)
            require((lut, dsp) == (row['lut_class'], row['dsp']), 'resource mismatch')
            require(bram == row.get('bram9', 0), 'BRAM mismatch')
            require(lut <= 15000 and dsp <= 4 and bram <= 46, 'isolated budget exceeded')
            reports[str(log)] = sha(log)
            profiles.append(dict(group=group, module=module, lut_class=lut, dsp=dsp,
                                 bram9=bram, log_sha256=sha(log)))
        require(counts == expected, 'unexpected profile/module coverage')
    for name, group in (
        ('integration/peer_review_raw14.json', 'image/raw14_codec'),
        ('stream_bus/axi_crossbar_peer/peer_review_axi_crossbar.json', 'stream_bus/axi_multi_crossbar')):
        path = PACKAGE/name
        obj = read(path)
        require(obj['status'] == 'PASS' and not obj['findings'], 'peer findings remain')
        require(obj['source_freeze_sha256'] == sha(PACKAGE/group/'source_freeze.json'), 'peer freeze mismatch')
        for n, h in obj.get('peer_input_sha256', {}).items():
            require(sha(path.parent/n) == h, 'peer input changed')
        for n, h in obj.get('independent_evidence', {}).items():
            require(sha(PACKAGE/n) == h, 'independent evidence changed')
        for n, h in obj.get('evidence_sha256', {}).items():
            require(sha(path.parent/n) == h, 'peer evidence changed')
        peers[str(path)] = sha(path)
    peer_base = PACKAGE/'stream_bus/axi_crossbar_peer'
    peer_run = read(peer_base/'five_channel_evidence.json')
    require(peer_run['status'] == 'PASS' and len(peer_run['profiles']) == 11 and
            all('PASS independent AXI five-channel' in r['output'] for r in peer_run['profiles']), 'AXI independent profiles failed')
    require(peer_run['source_freeze_sha256'] == sha(PACKAGE/'stream_bus/axi_multi_crossbar/source_freeze.json'), 'AXI peer run freeze')
    for n, h in peer_run['peer_input_sha256'].items():
        require(sha(peer_base/n) == h, 'AXI independent test input changed')
    reports[str(peer_base/'five_channel_evidence.json')] = sha(peer_base/'five_channel_evidence.json')
    for group in GROUPS:
        path = PACKAGE/group/'final_validation.json'
        obj = read(path)
        require(obj['status'] == 'PASS' and obj['source_freeze_sha256'] == sha(path.parent/'source_freeze.json'), 'owner metadata freeze')
        root = path.parent if group.startswith('image/') else path.parent.parent
        for n, h in obj.get('evidence', obj.get('reports', {})).items():
            require(sha(root/n) == h, 'owner final report binding changed')
        reports[str(path)] = sha(path)
    write_json(folder/'resource_audit.json', dict(status='PASS', owner_frozen_inputs=frozen,
        source_bound_reports=reports, isolated_profiles=profiles,
        scope='Two fixed RAW14 formats and AXI default/max isolated synthesis; no route or board claim'))
    write_json(folder/'peer_review.json', dict(status='PASS', review_files_sha256=peers, findings=[]))
    return frozen, reports


def finalize(folder, frozen, reports):
    # Development may continue concurrently in unrelated directories. Check only this batch.
    groups = (*GROUPS, 'stream_bus/axi_crossbar_peer')
    prefixes = {'raw_axi_audit_'}
    for group in groups:
        base = PACKAGE/group
        require(not any(p.suffix in {'.pyc', '.vvp', '.fs', '.bin'} for p in base.rglob('*')), 'task binary/cache remains')
        for script in base.glob('*.py'):
            prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''', script.read_text(encoding='utf-8')))
    root_script = PACKAGE/'integration/test_raw14_bit_basis.py'
    prefixes.update(re.findall(r'''prefix\s*=\s*['"]([^'"]+)''', root_script.read_text(encoding='utf-8')))
    remaining = [str(p) for p in Path(tempfile.gettempdir()).iterdir() if any(p.name.startswith(n) for n in prefixes)]
    require(not remaining, 'batch temporary products remain')
    write_json(folder/'cleanup_check.json', dict(status='PASS', checked_temp_prefixes=sorted(prefixes), remaining=[],
        scope='This batch only; inherited cleanup exceptions remain recorded in baseline134'))
    for name, digest in {**read(folder/'tested_input_sha256.json'), **frozen, **reports}.items():
        require(sha(Path(name)) == digest, 'final input changed: '+name)
    for name in ('checkpoint_audit.json', 'ancestry_check.json'):
        require(read(folder/name)['status'] == 'PASS', 'checkpoint audit failed')
    result = read(folder/'results.json')
    require(all(e['status'] == 'PASS' for e in result['results']+result['integrations']), 'regression failed')
    require(result['source_bundle_compile']['status'] == result['input_stability']['status'] == 'PASS', 'bundle/stability failed')
    names = ('results.json', 'tested_input_sha256.json', 'checkpoint_audit.json', 'ancestry_check.json',
             'resource_audit.json', 'peer_review.json', 'cleanup_check.json')
    write_json(folder/'final_readonly_check.json', dict(status='PASS', board_tested=False,
        tracked_inputs_checked=len(read(folder/'tested_input_sha256.json')),
        owner_frozen_inputs_checked=len(frozen), sealed_reports={n: sha(folder/n) for n in names},
        additional_input_sha256={str(p): sha(p) for p in (Path(__file__).resolve(), PACKAGE/'IMAGE_EXTENSIONS.md')},
        inherited_cleanup_exceptions='Baseline134 retains two precise policy-blocked cleanup exceptions; no new batch leftovers'))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('checkpoint', type=Path)
    parser.add_argument('--finalize', action='store_true')
    parser.add_argument('--synthesize', action='store_true')
    args = parser.parse_args()
    if args.synthesize:
        synthesize_axi(args.checkpoint.resolve())
    frozen, reports = audit(args.checkpoint.resolve())
    if args.finalize:
        finalize(args.checkpoint.resolve(), frozen, reports)
    print('RAW_AXI_AUDIT_PASS', len(frozen))
