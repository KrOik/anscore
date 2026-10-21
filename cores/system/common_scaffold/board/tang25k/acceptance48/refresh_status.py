"""Rebuild the 48-entry acceptance ledger from retained case/build/board evidence."""
import datetime
import hashlib
import json
from pathlib import Path

HERE=Path(__file__).resolve().parent
PACKAGE=HERE.parents[2]


def read(path):
    return json.loads(path.read_text(encoding='utf-8'))


def main():
    root=PACKAGE.parents[1]
    production={}
    for line in (PACKAGE/'rtl_functional_sources.f').read_text(encoding='utf-8').splitlines():
        if line.strip() and not line.startswith('#'):
            source=root/line.strip()
            production.setdefault(source.name,[]).append(source)
    entries={x['name']:dict(module=x['name'],status='NOT_PREPARED',cases=[])
             for x in read(PACKAGE/'signal_video/manifest.json')['modules']}
    for parent in (HERE/'cases',HERE/'rtl_dsp',HERE/'window_frame_optimized',
                   HERE/'scalar_dehaze_optimized',HERE/'clahe_optimized',HERE/'geo_optimized',
                   HERE/'geo_mapping_optimized',HERE/'nlm_optimized'):
        for case_file in sorted(parent.rglob('case.json')):
            case=read(case_file);module=case.get('public_module')
            if module not in entries:continue
            path=case_file.parent
            freeze=(read(path/'build_status.json').get('source_sha256',{})
                    if (path/'build_status.json').is_file() else {})
            stable=bool(freeze) and all((path/name).is_file() and hashlib.sha256(
                (path/name).read_bytes()).hexdigest()==digest for name,digest in freeze.items())
            public=PACKAGE/'signal_video/rtl'/f'{module}.v'
            staged=path/'source'/f'{module}.v'
            current=public.is_file() and staged.is_file() and public.read_bytes()==staged.read_bytes()
            candidate_changes=[]
            for source_name in case.get('sources',[]):
                source=path/source_name
                matches=production.get(source.name,[])
                if matches and not any(p.is_file() and p.read_bytes()==source.read_bytes() for p in matches):
                    candidate_changes.append(source.name)
            record=dict(path=str(path.relative_to(HERE)),simulation=case.get('simulation'),
                        commands=case.get('commands'),outputs=case.get('outputs'),
                        builds=[],board=[],frozen_inputs_unchanged=stable,current_public_rtl_matches=current,
                        candidate_changes_pending_integration=candidate_changes)
            stage='SIMULATION_PASS' if stable and case.get('simulation')=='PASS' else 'PREPARED'
            for build_file in sorted(path.glob('build_*_summary.json')):
                build=read(build_file);gates=build.get('gates',{})
                ready=all(gates.get(k) is True for k in
                          ('route_process','route_complete','timing_50mhz','lut_15k','dsp_4'))
                record['builds'].append(dict(path=str(build_file.relative_to(HERE)),
                    setup_resource_pass=ready,fmax_mhz=build.get('fmax_mhz'),
                    util=build.get('util'),hold_status=build.get('hold_evidence_status')))
                if ready:stage='READY_FOR_FUNCTIONAL_BOARD'
            for board_file in sorted(path.glob('functional_board_*.json')):
                board=read(board_file)
                passed=stable and current and board.get('status')=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN' and len(board.get('runs',[]))>=3 and all(
                    r.get('status')=='PASS' and r.get('programmer_returncode')==0 and
                    r.get('uart_hex')==r.get('expected_hex') for r in board.get('runs',[]))
                record['board'].append(dict(path=str(board_file.relative_to(HERE)),status=board.get('status'),
                    repetitions=len(board.get('runs',[])),timing_signoff=board.get('timing_signoff')))
                if passed:stage='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
            priority=['NOT_PREPARED','PREPARED','SIMULATION_PASS','READY_FOR_FUNCTIONAL_BOARD',
                      'FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN']
            if priority.index(stage)>priority.index(entries[module]['status']):entries[module]['status']=stage
            record['status']=stage;entries[module]['cases'].append(record)
    counts={state:sum(e['status']==state for e in entries.values()) for state in sorted({e['status'] for e in entries.values()})}
    for entry in entries.values():
        entry['current_production_sources_match_board_candidate']=any(
            c['status']=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN' and
            not c['candidate_changes_pending_integration'] for c in entry['cases'])
    production_bound=sum(e['current_production_sources_match_board_candidate'] for e in entries.values())
    report=dict(date=datetime.datetime.now().astimezone().isoformat(),counts=counts,
                current_production_sources_match_board_candidate_count=production_bound,
                scope='bounded functional board tests; no hold timing signoff or delivery acceptance',entries=list(entries.values()))
    (HERE/'acceptance_status.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    text=['# 48-entry current acceptance ledger','',report['scope'],'',str(counts),'',
          f'Current production source files matching a board-tested candidate: {production_bound}/48.',
          'This compares every listed source, including unused dependencies; it is not timing or full-mode signoff.','',
          '| Public entry | Current best evidence | Current production sources match | Candidate changes pending integration |','|---|---|---|---|']
    for name,entry in entries.items():
        selected=[c for c in entry['cases'] if c['status']==entry['status']]
        # Prefer evidence matching production over an older successful candidate.
        # Every individual case remains available in the JSON ledger.
        best=min(selected,key=lambda c:len(c['candidate_changes_pending_integration'])) if selected else None
        pending=best['candidate_changes_pending_integration'] if best else []
        bound='YES' if entry['current_production_sources_match_board_candidate'] else 'NO'
        text.append(f'| {name} | {entry["status"]} | {bound} | {", ".join(pending) or "—"} |')
    (HERE/'ACCEPTANCE_STATUS.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
    print(json.dumps(counts))


if __name__=='__main__':main()
